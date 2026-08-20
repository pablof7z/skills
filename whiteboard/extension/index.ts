// Whiteboard pi extension (block document model only).
//
// Owns the whiteboard viewer lifecycle, natively wakes the agent on new human
// comments/chat as a whiteboard-attributed message (custom-rendered, not a user
// message), shows an unread badge in the pi footer, dispatches `/wb` to the wb
// CLI, and registers one `whiteboard` tool so the LLM mutates the doc directly.
// The portable skill stays harness-agnostic; this is the pi-specific accelerator.
//
// Verified against docs/extensions.md:
//  - no background resources from the factory; defer to session_start, tear down
//    on session_shutdown (kill the spawned viewer only on "quit", so it survives
//    /new, /resume, /reload).
//  - pi.sendMessage({customType, content, display}, {triggerTurn, deliverAs})
//    wakes the agent with a message rendered by registerMessageRenderer.
//  - ctx.ui.setStatus(key, text) for the footer (guard ctx.hasUI).
//  - pi.registerTool / pi.registerCommand.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawn, execFile } from "node:child_process";
import {
  listSessions, loadDoc, isActionable, chatActionable, sessionUnread,
} from "./scan.mjs";
import { registerWhiteboardTools, setCurrentSession, getCurrentSession } from "./tool.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VIEWER_DIR = path.join(__dirname, "..", "viewer");
const SERVER = path.join(VIEWER_DIR, "server.mjs");
const CLI = path.join(__dirname, "..", "cli", "main.mjs");
const ROOT = path.join(os.homedir(), "whiteboard");
const PORT = Number(process.env.WHITEBOARD_PORT || "4318");
const VIEWER_URL = `http://127.0.0.1:${PORT}`;
const myProject = process.env.WHITEBOARD_PROJECT || path.basename(process.cwd());

// pi-tui is only resolvable inside pi's runtime. Resolve lazily so the module
// loads under bare-node tests; the renderer falls back to WhiteboardLine there.
// NOTE: a static `import { Text } from "@earendil-works/pi-tui"` would be aliased
// to pi's bundled copy by jiti at load time, but it would break these out-of-tree
// bare-node tests (no pi-tui in node_modules). createRequire / dynamic import()
// bypass jiti's aliases, so they only resolve when the extension has its own
// node_modules with pi-tui installed (the documented out-of-tree setup).
const require_ = createRequire(import.meta.url);
let TextC: any = null;
try { TextC = require_("@earendil-works/pi-tui").Text; } catch {}

// Minimal leaf TUI component used when the real pi-tui Text class is unavailable.
// pi-tui's layout treats any object with a `render(width) -> string[]` method as a
// valid leaf; returning a bare `{ toString }` object (the old fallback) made
// Container.render throw `child.render is not a function` and crashed pi on the
// next render tick. This component renders the colored "[whiteboard] " prefix
// (ANSI only appears there) and word-wraps the plain content tail to width.
const ANSI = /\x1b\[[0-9;]*m/g;
const PREFIX_RE = /^((?:\x1b\[[0-9;]*m)*\[whiteboard\] (?:\x1b\[[0-9;]*m)*)/;
class WhiteboardLine {
  body: string;
  pad: number;
  constructor(body: string, pad = 0) { this.body = body; this.pad = pad; }
  invalidate() {}
  render(width: number) {
    const w = Math.max(1, Math.floor(width) - this.pad);
    const m = this.body.match(PREFIX_RE);
    const prefix = m ? m[1] : "";
    const prefixVis = prefix.replace(ANSI, "").length;
    const rest = this.body.slice(prefix.length);
    const words = rest.split(/\s+/).filter(Boolean);
    const out: string[] = [];
    let cur = prefix;            // current line text
    let curVis = prefixVis;      // visible width of cur
    let indentVis = prefixVis;   // visible width of the current line's lead-in
    for (const word of words) {
      const add = curVis > indentVis ? " " + word : word;
      if (curVis + add.length > w && curVis > indentVis) {
        out.push(cur);
        cur = "  " + word;
        curVis = 2 + word.length;
        indentVis = 2;
      } else {
        cur += add;
        curVis += add.length;
      }
    }
    if (cur || out.length === 0) out.push(cur);
    return this.pad > 0 ? out.map((l) => " ".repeat(this.pad) + l) : out;
  }
}

async function isViewerUp() {
  try { const r = await fetch(`${VIEWER_URL}/api/sessions`); return r.ok; } catch { return false; }
}

function tokenize(s: string): string[] {
  const out: string[] = [];
  let cur = "", quote = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) {
      if (ch === quote) quote = "";
      else if (ch === "\\" && i + 1 < s.length) cur += s[++i];
      else cur += ch;
    } else if (ch === '"' || ch === "'") quote = ch;
    else if (/\s/.test(ch)) { if (cur) { out.push(cur); cur = ""; } }
    else cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}

// Owner-scoped WB_SESSION resolution (inlined so it survives /reload's
// transitive-module caching). Only sessions whose manifest.owner === this pi
// session id are candidates; no global current file, no mtime fallback (both
// would let concurrent agents pin to each other's sessions).
function resolveOwnedSession(project: string, root: string, ownerId: string | null) {
  if (!ownerId) return null;
  const base = path.join(root, project);
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(base, { withFileTypes: true }); } catch { return null; }
  const owned: { slug: string; mtime: number }[] = [];
  for (const e of entries) {
    if (!e.isDirectory() || !/^\d{4}-\d{2}-.+/.test(e.name)) continue;
    const dir = path.join(base, e.name);
    try {
      const man = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
      if (man.owner === ownerId) owned.push({ slug: e.name, mtime: fs.statSync(dir).mtimeMs });
    } catch {}
  }
  if (owned.length === 0) return null;
  owned.sort((a, b) => b.mtime - a.mtime);
  return { project, slug: owned[0].slug };
}

export default function (pi: ExtensionAPI) {
  let watcher: ReturnType<typeof fs.watch> | null = null;
  let debounce: ReturnType<typeof setTimeout> | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let mySessionId: string | null = null;
  let toolsRegistered = false;
  // Resolve typebox (jiti alias under pi; null under bare-node tests) and register
  // the 10 whiteboard tools. toolsReady is awaited in session_start so the active
  // set is applied AFTER the tools exist (setActiveTools ignores unknown names).
  const toolsReady = import("typebox")
    .then((m: any) => m?.Type).catch(() => null)
    .then((Type: any) => { if (Type && !toolsRegistered) { registerWhiteboardTools(pi as any, Type); toolsRegistered = true; } });
  const handled = new Set<string>();
  const seenComments = new Map<string, Set<string>>();

  function mine(s: any): boolean {
    if (!mySessionId) return s.project === myProject;
    return s.owner === mySessionId;
  }

  async function ensureViewer() {
    if (await isViewerUp()) return;
    const child = spawn("node", [SERVER, ROOT, "--port", String(PORT)], { stdio: "ignore", detached: true });
    child.unref();
    for (let i = 0; i < 25; i++) { if (await isViewerUp()) return; await new Promise((r) => setTimeout(r, 200)); }
  }

  // The active session for THIS pi session: the tool-tracked current session
  // (set by wb_new/wb_use) wins; else the most-recently-modified session we own
  // (manifest.owner === mySessionId). If neither, the footer shows nothing —
  // a project-wide fallback would pin this agent to another agent's session,
  // since sessions share a project key (basename(cwd)). Tool resolution stays
  // separate (currentSession only); this is footer/info display.
  function activeSession(): string | null {
    const t = getCurrentSession();
    if (t) return t;
    const owned = resolveOwnedSession(myProject, ROOT, mySessionId);
    if (owned) return `${owned.project}/${owned.slug}`;
    // No tool-tracked and no owned session: show nothing. A project-wide
    // newest-session fallback here would pin this agent to another agent's
    // session (sessions share a project key = basename(cwd)); ownership is
    // the only correct scoping for the footer.
    return null;
  }

  function updateStatus(ctx: any) {
    try {
      const sess = activeSession();
      let unread = 0;
      try { for (const s of listSessions(ROOT)) if (s.project === myProject && mine(s)) unread += sessionUnread(s); } catch {}
      // Show the active whiteboard session in the footer, with unread count when
      // any. No hasUI guard: setStatus is a safe no-op in non-UI modes (per docs),
      // and guarding on ctx.hasUI skipped the set when hasUI was undefined in the
      // TUI. When this agent has no session, clear the footer entirely rather
      // than advertising "(no session)".
      if (sess) ctx?.ui?.setStatus?.("whiteboard", `📓 ${sess}${unread ? ` · ${unread} unread` : ""}`);
      else ctx?.ui?.setStatus?.("whiteboard", undefined);
    } catch {}
  }

  function baseline() {
    for (const s of listSessions(ROOT)) {
      if (s.project !== myProject || !mine(s)) continue;
      const doc = loadDoc(s.dir);
      const where = `${s.project}/${s.slug}`;
      seenComments.set(where, new Set((doc?.annotations || []).map((c: any) => c.id)));
      for (const c of doc?.annotations || []) if (isActionable(c)) handled.add(`annotation:${c.id}`);
      for (const it of chatActionable(s.dir)) handled.add(`chat:${it.id}`);
    }
  }

  // Wake the agent with a whiteboard-attributed message (custom-rendered, not a
  // user message) that triggers a turn.
  function wake(content: string) {
    try { pi.sendMessage({ customType: "whiteboard", content, display: true }, { triggerTurn: true, deliverAs: "followUp" }); }
    catch (e) { console.error("whiteboard wake failed:", e); }
  }

  function poke(ctx: any) {
    try {
      for (const s of listSessions(ROOT)) {
        if (s.project !== myProject || !mine(s)) continue;
        const where = `${s.project}/${s.slug}`;
        const doc = loadDoc(s.dir);
        if (doc) {
          const seen = seenComments.get(where) || new Set<string>();
          for (const c of doc.annotations || []) {
            if (!isActionable(c) || seen.has(c.id)) continue;
            seen.add(c.id); handled.add(`annotation:${c.id}`);
            const anchorPart = c.selector?.exact ? `> ${c.selector.exact}\n\n` : "";
            wake(`Annotation (${c.kind}) on block "${c.block}" in ${where} (id ${c.id}):\n${anchorPart}User's message:\n${c.body || ""}`);
          }
          seenComments.set(where, seen);
        }
        for (const it of chatActionable(s.dir)) {
          const key = `chat:${it.id}`;
          if (handled.has(key)) continue;
          handled.add(key);
          wake(`New chat in ${where}:\n${it.text || ""}\n\nReply by writing an agent chat message into that session's chat/ dir so it appears in the viewer.`);
        }
      }
      updateStatus(ctx);
    } catch (e) { console.error("whiteboard poke failed:", e); }
  }

  function startWatcher(ctx: any) {
    try { watcher?.close(); } catch {}
    watcher = null;
    if (debounce) { clearTimeout(debounce); debounce = null; }
    try { watcher = fs.watch(ROOT, { recursive: true }, () => {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(() => poke(ctx), 400);
    }); } catch (e) { console.error("whiteboard watch failed:", e); }
  }

  pi.registerMessageRenderer("whiteboard", (message: any, options: any, theme: any) => {
    const pad = options?.outputPad ?? 0;
    const body = theme?.fg ? theme.fg("accent", "[whiteboard] ") + String(message.content || "") : `[whiteboard] ${message.content || ""}`;
    // Prefer the real Text component when pi-tui is resolvable; otherwise render
    // via the self-contained WhiteboardLine. Never return a non-component.
    if (TextC) { try { return new TextC(body, pad, 0); } catch {} }
    return new WhiteboardLine(body, pad);
  });

  pi.on("session_start", async (_event, ctx) => {
    await ensureViewer();
    try { mySessionId = ctx?.sessionManager?.getSessionId?.() || null; } catch { mySessionId = null; }
    if (mySessionId) process.env.WB_OWNER = mySessionId;
    const cur = resolveOwnedSession(myProject, ROOT, mySessionId);
    // Tools must be registered before setActiveTools (unknown names are ignored).
    await toolsReady;
    try {
      if ((pi as any).getActiveTools && (pi as any).setActiveTools) {
        const DOC = new Set(["wb_use", "wb_read", "wb_note", "wb_change_start", "wb_change_block", "wb_change_finish", "wb_apply", "wb_attach", "wb_tag"]);
        let active: string[] = (pi as any).getActiveTools().filter((n: string) => !DOC.has(n));
        active = [...new Set([...active, "wb_new", "wb_list"])];   // fresh agent: only the two loaders
        if (cur) active = [...new Set([...active, ...DOC])];         // owning agent: unlock everything (smooth wake)
        (pi as any).setActiveTools(active);
      }
    } catch {}
    if (cur) {
      process.env.WB_SESSION = `${cur.project}/${cur.slug}`;
      setCurrentSession(`${cur.project}/${cur.slug}`);
      if (ctx?.hasUI) ctx.ui.notify(`whiteboard session: ${cur.project}/${cur.slug}`, "info");
    }
    baseline();
    startWatcher(ctx);
    updateStatus(ctx);
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = setInterval(() => { ensureViewer().catch(() => {}); }, 10000);
    if (ctx?.hasUI) ctx.ui.notify(`whiteboard: ${VIEWER_URL}`, "info");
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (debounce) { clearTimeout(debounce); debounce = null; }
    if (heartbeat) { clearInterval(heartbeat); heartbeat = null; }
    try { watcher?.close(); } catch {}
    watcher = null;
    try { if (ctx?.hasUI) ctx.ui.setStatus("whiteboard", undefined); } catch {}
  });

  pi.registerCommand("wb", {
    description: "Whiteboard: `/wb` shows status; `/wb <args…>` runs the wb CLI",
    handler: async (args: string, ctx: any) => {
      const argv = (args || "").trim();
      if (!argv) {
        await ensureViewer();
        const sess = activeSession() || "(none)";
        ctx.ui.notify(`whiteboard\n  session: ${sess}\n  viewer:   ${VIEWER_URL}/`, "info");
        return;
      }
      const parts = tokenize(argv);
      execFile(process.execPath, [CLI, ...parts], { cwd: process.cwd(), maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
        const out = [stdout, stderr].filter(Boolean).join("\n").trim();
        if (out) ctx.ui.notify(out, err ? "error" : "info");
        else if (err) ctx.ui.notify(`wb: ${err.message}`, "error");
      });
    },
  });
}