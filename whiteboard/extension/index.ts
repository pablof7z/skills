// Whiteboard pi extension (block-model aware).
//
// Owns the whiteboard viewer lifecycle, natively wakes the agent on new human
// comments/chat, shows an unread badge in the pi footer, and dispatches `/wb`
// to the `wb` CLI. Supports the new block document model (document.json) while
// keeping the legacy comments/ scan path for sessions that still use
// deliverable.md. Portable skill stays harness-agnostic; this is the pi-specific
// accelerator.
//
// Verified against docs/extensions.md:
//  - no background resources from the factory; defer to session_start, tear down
//    on session_shutdown (kill the spawned viewer only on "quit", so it survives
//    /new, /resume, /reload).
//  - pi.sendUserMessage(text, { deliverAs: "followUp" }) wakes the agent.
//  - ctx.ui.setStatus(key, text) for the footer (guard ctx.hasUI).
//  - pi.registerCommand for /wb.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawn, execFile } from "node:child_process";
import {
  listSessions, loadDoc, isActionable, legacyActionable, sessionUnread,
} from "./scan.mjs";
import { applyWbSession } from "./resolve.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VIEWER_DIR = path.join(__dirname, "..", "viewer");
const SERVER = path.join(VIEWER_DIR, "server.mjs");
const CLI = path.join(__dirname, "..", "cli", "main.mjs");
const ROOT = path.join(os.homedir(), "whiteboard");
const PORT = Number(process.env.WHITEBOARD_PORT || "4318");
const VIEWER_URL = `http://127.0.0.1:${PORT}`;
// Only wake this pi session for whiteboard sessions in its own project. The
// whiteboard `project` (first path segment under ~/whiteboard) corresponds to
// the repo/dir the pi session is working in. Override with WHITEBOARD_PROJECT.
const myProject = process.env.WHITEBOARD_PROJECT || path.basename(process.cwd());

const nowIso = () => new Date().toISOString();
const excerpt = (t: string, n = 120) => t.slice(0, n).replace(/\s+/g, " ").trim();

async function isViewerUp() {
  try { const r = await fetch(`${VIEWER_URL}/api/sessions`); return r.ok; } catch { return false; }
}

// Split `/wb <args…>` honoring single/double quotes so a quoted body like
// `wb comment goal "some text"` survives as one argv element.
function tokenize(s: string): string[] {
  const out: string[] = [];
  let cur = "", quote = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (quote) {
      if (ch === quote) quote = "";
      else if (ch === "\\" && i + 1 < s.length) cur += s[++i];
      else cur += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (/\s/.test(ch)) {
      if (cur) { out.push(cur); cur = ""; }
    } else cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}

export default function (pi: ExtensionAPI) {
  let watcher: ReturnType<typeof fs.watch> | null = null;
  let debounce: ReturnType<typeof setTimeout> | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  // Wake-dedupe: handled keys (`<kind>:<id>`) we've already woken for, and per
  // session the set of block-doc comment ids we've already seen (so only NEW
  // comments since the last rev wake the agent).
  const handled = new Set<string>();
  const seenComments = new Map<string, Set<string>>(); // sessionKey -> ids

  // The viewer is a persistent, self-healing daemon: spawn-if-down, detached so
  // it survives pi restarts/reloads, and never killed by the extension. A
  // heartbeat re-checks every 10s so a crashed/killed viewer respawns within a
  // session. Stop it manually with: pkill -f viewer/server.mjs
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
      try {
        for (const s of listSessions(ROOT)) if (s.project === myProject) unread += sessionUnread(s);
      } catch {}
      ctx.ui.setStatus("whiteboard", unread > 0 ? `📓 ${unread} unread` : "📓 whiteboard");
    } catch { /* ctx may be stale after session replacement/reload; skip silently */ }
  }

  // Baseline every actionable item so only NEW ones wake the agent. For block-doc
  // sessions, also record the set of existing comment ids (rev-based "new"
  // detection: document.json has no per-comment rev, so we diff ids).
  function baseline() {
    for (const s of listSessions(ROOT)) {
      if (s.project !== myProject) continue;
      if (s.blockDoc) {
        const doc = loadDoc(s.dir);
        const ids = new Set<string>((doc?.comments || []).map((c: any) => c.id));
        seenComments.set(`${s.project}/${s.slug}`, ids);
        for (const c of doc?.comments || []) if (isActionable(c)) handled.add(`blockcomment:${c.id}`);
      } else {
        for (const it of legacyActionable(s.dir)) handled.add(`${it.kind}:${it.id}`);
      }
    }
  }

  function poke(ctx: any) {
    try {
      for (const s of listSessions(ROOT)) {
        if (s.project !== myProject) continue; // only wake for this session's project
        const where = `${s.project}/${s.slug}`;
        if (s.blockDoc) {
          const doc = loadDoc(s.dir);
          if (!doc) continue;
          const seen = seenComments.get(where) || new Set<string>();
          for (const c of (doc.comments || [])) {
            if (!isActionable(c) || seen.has(c.id)) continue;
            seen.add(c.id);
            handled.add(`blockcomment:${c.id}`);
            const msg = `[whiteboard] New comment on block "${c.block}" in ${where}: "${excerpt(c.body)}". Reply with \`wb reply ${c.id} "<text>"\` then \`wb resolve ${c.id}\`.`;
            try { pi.sendUserMessage(msg, { deliverAs: "followUp" }); } catch (e) { console.error("whiteboard wake failed:", e); }
          }
          seenComments.set(where, seen);
        } else {
          for (const it of legacyActionable(s.dir)) {
            const key = `${it.kind}:${it.id}`;
            if (handled.has(key)) continue;
            handled.add(key);
            const replyIn = it.kind === "comment" ? "comments/ (write a reply annotation)" : "chat/ (write an agent chat message)";
            const msg = `[whiteboard] New ${it.kind} in ${where}:\n"${excerpt(it.text, 240)}"\n\nRead it and reply in that session's ${replyIn} dir so it appears in the viewer.`;
            try { pi.sendUserMessage(msg, { deliverAs: "followUp" }); } catch (e) { console.error("whiteboard wake failed:", e); }
          }
        }
      }
      updateStatus(ctx);
    } catch (e) { console.error("whiteboard poke failed:", e); }
  }

  function startWatcher(ctx: any) {
    // Close any prior watcher + pending debounce so a re-bind (session_start on
    // /new, /fork, /reload) never leaks a stale watcher firing poke with an old ctx.
    try { watcher?.close(); } catch {}
    watcher = null;
    if (debounce) { clearTimeout(debounce); debounce = null; }
    try {
      watcher = fs.watch(ROOT, { recursive: true }, () => {
        if (debounce) clearTimeout(debounce);
        debounce = setTimeout(() => poke(ctx), 400);
      });
    } catch (e) { console.error("whiteboard watch failed:", e); }
  }

  pi.on("session_start", async (_event, ctx) => {
    await ensureViewer();
    // Expose the current whiteboard session for myProject so `wb` resolves it.
    const cur = applyWbSession(myProject, ROOT);
    if (cur && ctx?.hasUI) ctx.ui.notify(`whiteboard session: ${cur.project}/${cur.slug}`, "info");
    // Baseline existing actionable items so only NEW ones wake the agent.
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
    // Viewer is a persistent daemon: kept across /new, /resume, /reload, and
    // even after pi quits. Stop it manually with: pkill -f viewer/server.mjs
  });

  pi.registerCommand("wb", {
    description: "Whiteboard: `/wb` shows status; `/wb <args…>` runs the wb CLI",
    handler: async (args: string, ctx: any) => {
      const argv = (args || "").trim();
      if (!argv) {
        await ensureViewer();
        const cur = process.env.WB_SESSION || "(none)";
        ctx.ui.notify(`whiteboard\n  session: ${cur}\n  viewer:   ${VIEWER_URL}/`, "info");
        return;
      }
      // Dispatch `/wb <args…>` to the wb CLI and print stdout/stderr to the user.
      const parts = tokenize(argv);
      execFile(process.execPath, [CLI, ...parts], { cwd: process.cwd(), maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
        const out = [stdout, stderr].filter(Boolean).join("\n").trim();
        if (out) ctx.ui.notify(out, err ? "error" : "info");
        else if (err) ctx.ui.notify(`wb: ${err.message}`, "error");
      });
    },
  });
}