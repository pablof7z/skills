// Whiteboard pi extension (minimal v1).
//
// Owns the whiteboard viewer lifecycle, natively wakes the agent on new human
// comments/chat, and shows an unread badge in the pi footer. Portable skill
// stays harness-agnostic; this is the pi-specific accelerator.
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
import { spawn, exec } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VIEWER_DIR = path.join(__dirname, "..", "viewer");
const SERVER = path.join(VIEWER_DIR, "server.mjs");
const ROOT = path.join(os.homedir(), "whiteboard");
const PORT = Number(process.env.WHITEBOARD_PORT || "4318");
const VIEWER_URL = `http://127.0.0.1:${PORT}`;
// Only wake this pi session for whiteboard sessions in its own project. The
// whiteboard `project` (first path segment under ~/whiteboard) corresponds to
// the repo/dir the pi session is working in. Override with WHITEBOARD_PROJECT.
const myProject = process.env.WHITEBOARD_PROJECT || path.basename(process.cwd());

const isSessionDir = (n: string) => /^\d{4}-\d{2}-.+/.test(n);
const nowIso = () => new Date().toISOString();

function readJson(p: string, fallback: any) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fallback; }
}
function readComments(dir: string) {
  const d = path.join(dir, "comments");
  if (!fs.existsSync(d)) return [];
  return fs.readdirSync(d).filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(d, f), "utf8")); } catch { return null; } }).filter(Boolean);
}
function readChat(dir: string) {
  const d = path.join(dir, "chat");
  if (!fs.existsSync(d)) return [];
  return fs.readdirSync(d).filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(d, f), "utf8")); } catch { return null; } }).filter(Boolean);
}
function readSeen(dir: string) { return readJson(path.join(dir, ".seen.json"), { lastSeenAt: null as string | null }); }
function computeUnread(annos: any[], lastSeenAt: string | null) {
  return annos.filter((a) => {
    if (String(a?.creator?.name || "").toLowerCase() === "user") return false;
    return !lastSeenAt || (a.created || "") > lastSeenAt;
  }).length;
}
function listSessions() {
  const out: any[] = [];
  if (!fs.existsSync(ROOT)) return out;
  for (const project of fs.readdirSync(ROOT)) {
    const pd = path.join(ROOT, project);
    if (!fs.statSync(pd).isDirectory()) continue;
    for (const name of fs.readdirSync(pd)) {
      if (!isSessionDir(name)) continue;
      const dir = path.join(pd, name);
      if (!fs.statSync(dir).isDirectory()) continue;
      const annos = readComments(dir);
      const seen = readSeen(dir);
      out.push({ project, slug: name, dir, unread: computeUnread(annos, seen.lastSeenAt) });
    }
  }
  return out;
}

// New actionable items the agent must respond to.
function scanActionable() {
  const items: { kind: "comment" | "chat"; id: string; project: string; slug: string; text: string }[] = [];
  for (const s of listSessions()) {
    if (s.project !== myProject) continue; // only wake for this session's project
    const annos = readComments(s.dir);
    const replied = new Set(annos.filter((a) => a.motivation === "replying" && a.target?.id).map((a) => a.target.id));
    for (const a of annos) {
      if (a.motivation !== "replying" && !(a.target && a.target.id) && String(a.creator?.name || "").toLowerCase() !== "agent" && !replied.has(a.id)) {
        items.push({ kind: "comment", id: a.id, project: s.project, slug: s.slug, text: a.body?.value || "" });
      }
    }
    const msgs = readChat(s.dir).sort((a: any, b: any) => (a.created || "").localeCompare(b.created || ""));
    for (let i = 0; i < msgs.length; i++) {
      const m = msgs[i];
      if (m.role !== "user") continue;
      const hasAgentAfter = msgs.slice(i + 1).some((x: any) => x.role === "agent" && (x.created || "") >= (m.created || ""));
      if (!hasAgentAfter) items.push({ kind: "chat", id: m.id, project: s.project, slug: s.slug, text: m.text || "" });
    }
  }
  return items;
}

async function isViewerUp() {
  try { const r = await fetch(`${VIEWER_URL}/api/sessions`); return r.ok; } catch { return false; }
}

export default function (pi: ExtensionAPI) {
  let watcher: ReturnType<typeof fs.watch> | null = null;
  let debounce: ReturnType<typeof setTimeout> | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  const handled = new Set<string>();

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
    if (!ctx?.hasUI) return;
    let unread = 0;
    try { unread = listSessions().reduce((n, s) => n + (s.unread || 0), 0); } catch {}
    ctx.ui.setStatus("whiteboard", unread > 0 ? `📓 ${unread} unread` : "📓 whiteboard");
  }

  function poke(ctx: any) {
    const items = scanActionable();
    for (const it of items) {
      const key = `${it.kind}:${it.id}`;
      if (handled.has(key)) continue;
      handled.add(key);
      const where = `${it.project}/${it.slug}`;
      const body = it.text.slice(0, 240).replace(/\s+/g, " ").trim();
      const replyIn = it.kind === "comment" ? "comments/ (write a reply annotation)" : "chat/ (write an agent chat message)";
      const msg = `[whiteboard] New ${it.kind} in ${where}:\n"${body}"\n\nRead it and reply in that session's ${replyIn} dir so it appears in the viewer.`;
      try { pi.sendUserMessage(msg, { deliverAs: "followUp" }); } catch (e) { console.error("whiteboard wake failed:", e); }
    }
    updateStatus(ctx);
  }

  function startWatcher(ctx: any) {
    try {
      watcher = fs.watch(ROOT, { recursive: true }, () => {
        if (debounce) clearTimeout(debounce);
        debounce = setTimeout(() => poke(ctx), 400);
      });
    } catch (e) { console.error("whiteboard watch failed:", e); }
  }

  pi.on("session_start", async (_event, ctx) => {
    await ensureViewer();
    // Baseline existing actionable items so only NEW ones wake the agent.
    for (const it of scanActionable()) handled.add(`${it.kind}:${it.id}`);
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
    if (ctx?.hasUI) ctx.ui.setStatus("whiteboard", undefined);
    // Viewer is a persistent daemon: kept across /new, /resume, /reload, and
    // even after pi quits. Stop it manually with: pkill -f viewer/server.mjs
  });

  pi.registerCommand("wb", {
    description: "Open the whiteboard viewer in the browser",
    handler: async (_args, ctx) => {
      await ensureViewer();
      exec(`open "${VIEWER_URL}/"`);
      ctx.ui.notify(`whiteboard: ${VIEWER_URL}`, "info");
    },
  });
}