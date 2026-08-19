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
import { registerWhiteboardTool } from "./tool.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VIEWER_DIR = path.join(__dirname, "..", "viewer");
const SERVER = path.join(VIEWER_DIR, "server.mjs");
const CLI = path.join(__dirname, "..", "cli", "main.mjs");
const ROOT = path.join(os.homedir(), "whiteboard");
const PORT = Number(process.env.WHITEBOARD_PORT || "4318");
const VIEWER_URL = `http://127.0.0.1:${PORT}`;
const myProject = process.env.WHITEBOARD_PROJECT || path.basename(process.cwd());

const excerpt = (t: string, n = 120) => t.slice(0, n).replace(/\s+/g, " ").trim();

// pi-tui is only resolvable inside pi's runtime. Resolve lazily so the module
// loads under bare-node tests; the renderer is never called there.
const require_ = createRequire(import.meta.url);
let TextC: any = null;
try { TextC = require_("@earendil-works/pi-tui").Text; } catch {}

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

  function updateStatus(ctx: any) {
    try {
      if (!ctx?.hasUI) return;
      let unread = 0;
      try { for (const s of listSessions(ROOT)) if (s.project === myProject && mine(s)) unread += sessionUnread(s); } catch {}
      ctx.ui.setStatus("whiteboard", unread > 0 ? `📓 ${unread} unread` : "📓 whiteboard");
    } catch {}
  }

  function baseline() {
    for (const s of listSessions(ROOT)) {
      if (s.project !== myProject || !mine(s)) continue;
      const doc = loadDoc(s.dir);
      const where = `${s.project}/${s.slug}`;
      seenComments.set(where, new Set((doc?.comments || []).map((c: any) => c.id)));
      for (const c of doc?.comments || []) if (isActionable(c)) handled.add(`comment:${c.id}`);
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
          for (const c of doc.comments || []) {
            if (!isActionable(c) || seen.has(c.id)) continue;
            seen.add(c.id); handled.add(`comment:${c.id}`);
            wake(`New comment on block "${c.block}" in ${where}: "${excerpt(c.body)}" (id ${c.id}). Reply via the whiteboard tool: change sub "reply" threadId "${c.id}" text "…", then "resolve" threadId "${c.id}", then "send".`);
          }
          seenComments.set(where, seen);
        }
        for (const it of chatActionable(s.dir)) {
          const key = `chat:${it.id}`;
          if (handled.has(key)) continue;
          handled.add(key);
          wake(`New chat in ${where}:\n${excerpt(it.text, 240)}\n\nReply by writing an agent chat message into that session's chat/ dir so it appears in the viewer.`);
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
    const body = theme?.fg ? theme.fg("accent", "[whiteboard] ") + String(message.content || "") : `[whiteboard] ${message.content || ""}`;
    return TextC ? new TextC(body, options?.outputPad ?? 0, 0) : { toString: () => body };
  });

  registerWhiteboardTool(pi as any);

  pi.on("session_start", async (_event, ctx) => {
    await ensureViewer();
    try { mySessionId = ctx?.sessionManager?.getSessionId?.() || null; } catch { mySessionId = null; }
    if (mySessionId) process.env.WB_OWNER = mySessionId;
    const cur = resolveOwnedSession(myProject, ROOT, mySessionId);
    if (cur) {
      process.env.WB_SESSION = `${cur.project}/${cur.slug}`;
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
        ctx.ui.notify(`whiteboard\n  session: ${process.env.WB_SESSION || "(none)"}\n  viewer:   ${VIEWER_URL}/`, "info");
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