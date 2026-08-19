#!/usr/bin/env node
// Whiteboard viewer server (root-based).
//
// Serves an explorer + per-session viewer for all whiteboard sessions under a
// root directory (default ~/whiteboard). The explorer lists projects/sessions
// with unread badges; each session view renders the block document and
// supports comments. The server watches the filesystem and pushes live updates
// to the browser via SSE.
//
// Usage: node server.mjs [<root-dir>] [--port 4318] [--open]

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import * as S from "./lib/session.mjs";
import * as B from "./lib/blockdoc.mjs";
import { execFileSync } from "node:child_process";

const VIEWER_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_PORT = 4318;
const DEFAULT_ROOT = path.join(os.homedir(), "whiteboard");

function parseArgs(argv) {
  const args = argv.slice(2);
  const positional = [];
  let port = DEFAULT_PORT, open = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--port") port = Number(args[++i]);
    else if (a.startsWith("--port=")) port = Number(a.slice(7));
    else if (a === "--open") open = true;
    else if (a === "--help" || a === "-h") {
      console.log("Usage: server.mjs [<root-dir>] [--port 4318] [--open]");
      process.exit(0);
    } else positional.push(a);
  }
  return { root: path.resolve(positional[0] || DEFAULT_ROOT), port, open };
}

function sessionDir(root, project, slug) {
  const dir = path.join(root, project, slug);
  if (!S.isSessionDir(slug)) return null;
  if (project.includes("..") || slug.includes("..")) return null;
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return null;
  return dir;
}

// ---- SSE clients ----
const explorerClients = new Set();
const reloadClients = new Set();
const sessionClients = new Map(); // key "project/slug" -> Set<res>
const sessionClientsFor = (key) => {
  if (!sessionClients.has(key)) sessionClients.set(key, new Set());
  return sessionClients.get(key);
};

function sseStart(res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-store, no-transform",
    Connection: "keep-alive",
    "Access-Control-Allow-Origin": "*",
  });
  res.write(": hello\n\n");
  const keep = setInterval(() => { try { res.write(": ping\n\n"); } catch {} }, 15000);
  res.on("close", () => { clearInterval(keep); explorerClients.delete(res); reloadClients.delete(res); for (const set of sessionClients.values()) set.delete(res); });
  return res;
}

function broadcast(set, event, data) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const c of set) { try { c.write(payload); } catch {} }
}

// ---- HTTP helpers ----
function sendJson(res, code, obj) {
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  });
  res.end(JSON.stringify(obj));
}

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8", ".svg": "image/svg+xml",
};

function serveStatic(res, relPath) {
  const p = path.join(VIEWER_DIR, relPath);
  if (!p.startsWith(VIEWER_DIR)) return sendJson(res, 403, { error: "forbidden" });
  if (!fs.existsSync(p) || fs.statSync(p).isDirectory()) return sendJson(res, 404, { error: "not found" });
  res.writeHead(200, { "Content-Type": MIME[path.extname(p)] || "application/octet-stream", "Cache-Control": "no-store" });
  fs.createReadStream(p).pipe(res);
}

async function readBody(req) {
  let body = "";
  for await (const chunk of req) body += chunk;
  return body ? JSON.parse(body) : {};
}

// Focus the iTerm2 pane that authored a change. itermSessionId is
// "<win>:<tab>:<pane>:<guid>" (ITERM_SESSION_ID); we match the session by its
// GUID via AppleScript. The GUID is validated to a UUID shape before it goes
// anywhere near osascript — never injected raw.
function jumpToITerm(itermSessionId) {
  const guid = String(itermSessionId || "").split(":").pop();
  if (!/^[0-9A-Fa-f-]{36}$/.test(guid)) return { status: "bad_id" };
  const script = `tell application "iTerm"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (id of s) is "${guid}" then
          select t
          set index of w to 1
          activate
          return "opened"
        end if
      end repeat
    end repeat
  end repeat
  return "not_found"
end tell`;
  try {
    const r = execFileSync("osascript", ["-e", script], { encoding: "utf8", timeout: 5000 }).trim();
    return { status: r === "opened" ? "opened" : "not_found" };
  } catch (e) {
    return { status: "failed", error: String(e && e.message || e).slice(0, 200) };
  }
}

// ---- per-session request handler ----
async function handleSession(req, res, root, project, slug, rest) {
  const dir = sessionDir(root, project, slug);
  if (!dir) return sendJson(res, 404, { error: "session not found" });
  S.ensureDirs(dir);
  const key = `${project}/${slug}`;
  const m = req.method;

  if (rest === "session" && m === "GET") {
    const man = S.readManifest(dir);
    const viewed = S.readViewed(dir);
    const resolved = B.resolvedMap(dir);
    return sendJson(res, 200, { ...man, project, slug, sessionDir: dir, viewedVersion: viewed.version, resolved });
  }
  if (rest === "document" && m === "GET") {
    return sendJson(res, 200, B.getDocument(dir));
  }
  if (rest === "revisions" && m === "GET")
    return sendJson(res, 200, { revisions: B.listRevisions(dir) });
  if (rest.startsWith("revisions/") && m === "GET") {
    const r = Number(rest.slice("revisions/".length));
    const doc = B.getDocumentAt(dir, r);
    if (!doc) return sendJson(res, 404, { error: "revision not found" });
    return sendJson(res, 200, doc);
  }
  if (rest === "jump" && m === "POST") {
    const data = await readBody(req).catch(() => ({}));
    const rev = Number(data && data.rev);
    if (!rev) return sendJson(res, 400, { error: "rev required" });
    const ch = B.changeAt(dir, rev);
    if (!ch) return sendJson(res, 404, { error: "revision not found" });
    const iterm = ch.via && ch.via.itermSessionId;
    if (!iterm) return sendJson(res, 200, { status: "no_provenance" });
    return sendJson(res, 200, jumpToITerm(iterm));
  }
  if (rest === "notes" && m === "GET") return sendJson(res, 200, { content: S.readNotes(dir) });
  if (rest === "comments" && m === "GET") return sendJson(res, 200, B.getComments(dir));
  if (rest === "events" && m === "GET") { sseStart(res); sessionClientsFor(key).add(res); return; }
  if (rest === "comments" && m === "POST") {
    const data = await readBody(req).catch(() => null);
    if (!data) return sendJson(res, 400, { error: "bad json" });
    if (data.replyTo) {
      const r = B.postReply(dir, data.replyTo, data.text, data.creator || "user");
      return sendJson(res, 201, r);
    }
    if (!data.block) return sendJson(res, 400, { error: "block required" });
    const c = B.postComment(dir, { block: data.block, text: data.text, selector: data.selector, creator: data.creator || "user" });
    return sendJson(res, 201, c);
  }
  if (rest === "viewed" && m === "GET") {
    return sendJson(res, 200, S.readViewed(dir));
  }
  if (rest === "viewed" && m === "POST") {
    const data = await readBody(req).catch(() => ({}));
    const version = (data && data.version) || null;
    S.writeViewed(dir, version);
    return sendJson(res, 200, { version, at: S.nowIso() });
  }
  if (rest === "resolved" && m === "GET") return sendJson(res, 200, B.resolvedMap(dir));
  if (rest === "resolved" && m === "POST") {
    const data = await readBody(req).catch(() => ({}));
    const id = data && data.id;
    if (!id) return sendJson(res, 400, { error: "id required" });
    const map = B.resolve(dir, id, data.resolved, data.by || "user");
    return sendJson(res, 200, map);
  }
  if (rest === "manifest" && m === "PATCH") {
    const data = await readBody(req).catch(() => null);
    if (!data) return sendJson(res, 400, { error: "bad json" });
    const next = { ...S.readManifest(dir), ...data };
    fs.writeFileSync(path.join(dir, S.MANIFEST), JSON.stringify(next, null, 2) + "\n", "utf8");
    broadcast(explorerClients, "sessions", {});
    return sendJson(res, 200, next);
  }
  // Chat (file-queue; agent writes reply files directly, viewer renders live)
  if (rest === "chat" && m === "GET") return sendJson(res, 200, { messages: S.readChat(dir) });
  if (rest === "chat" && m === "POST") {
    const data = await readBody(req).catch(() => null);
    if (!data) return sendJson(res, 400, { error: "bad json" });
    const msg = {
      id: `urn:uuid:${S.uuid()}`,
      role: "user",
      text: String(data.text ?? "").slice(0, 8000),
      created: S.nowIso(),
    };
    S.writeChatMessage(dir, msg);
    return sendJson(res, 201, msg);
  }
  return sendJson(res, 404, { error: "not found" });
}

function main() {
  const { root, port, open } = parseArgs(process.argv);
  fs.mkdirSync(root, { recursive: true });

  // Watch the whole root recursively; broadcast to affected session + explorer.
  try {
    fs.watch(root, { recursive: true }, (_evt, filename) => {
      broadcast(explorerClients, "sessions", {});
      if (filename) {
        const segs = filename.split(path.sep);
        if (segs.length >= 2 && S.isSessionDir(segs[1])) {
          // Ignore viewer-internal writes that are not content changes:
          // Skip viewer-internal writes (the .viewed.json “Done” marker) so they
          // don't feedback-loop into endless refreshes.
          const leaf = segs[segs.length - 1];
          if (leaf === S.VIEWED_FILE) return;
          const key = `${segs[0]}/${segs[1]}`;
          broadcast(sessionClientsFor(key), "refresh", {});
          return;
        }
      }
      for (const set of sessionClients.values()) broadcast(set, "refresh", {});
    });
  } catch (e) { console.error("watch root failed:", e.message); }

  // Hot reload: when a viewer asset (module/css/html) changes on disk, push a
  // "reload" event to every connected page so the browser refreshes itself.
  let reloadTimer = null;
  try {
    fs.watch(VIEWER_DIR, { recursive: true }, (_evt, filename) => {
      if (!filename) return;
      if (/\.(mjs|js|css|html)$/.test(filename)) {
        if (reloadTimer) clearTimeout(reloadTimer);
        reloadTimer = setTimeout(() => broadcast(reloadClients, "reload", {}), 150);
      }
    });
  } catch (e) { console.error("watch viewer failed:", e.message); }

  const server = http.createServer(async (req, res) => {
    try {
      const u = new URL(req.url, `http://localhost:${port}`);
      const p = decodeURIComponent(u.pathname);
      if (req.method === "OPTIONS") return sendJson(res, 204, {});

      // Static assets: serve any existing file in the viewer dir (modules,
      // css, vendor libs) with the correct MIME so relative ES-module imports
      // like /docdiff.mjs resolve instead of hitting the SPA fallback.
      if (p === "/" || p === "/index.html") return serveStatic(res, "index.html");
      if (!p.startsWith("/api/")) {
        const rel = p.slice(1);
        const full = path.join(VIEWER_DIR, rel);
        if (full.startsWith(VIEWER_DIR) && fs.existsSync(full) && !fs.statSync(full).isDirectory()) {
          return serveStatic(res, rel);
        }
      }

      // API
      if (p === "/api/sessions" && req.method === "GET") return sendJson(res, 200, { sessions: S.listSessions(root) });
      if (p === "/api/events" && req.method === "GET") { sseStart(res); explorerClients.add(res); return; }
      if (p === "/api/reload" && req.method === "GET") { sseStart(res); reloadClients.add(res); return; }

      const sess = p.match(/^\/api\/session\/([^/]+)\/([^/]+)\/(.+)$/);
      if (sess) return await handleSession(req, res, root, sess[1], sess[2], sess[3]);

      // SPA fallback: serve index.html for non-API routes (e.g. /session/...)
      if (!p.startsWith("/api/")) return serveStatic(res, "index.html");
      return sendJson(res, 404, { error: "not found" });
    } catch (err) {
      console.error("request error:", err);
      if (!res.headersSent) sendJson(res, 500, { error: String(err && err.message || err) });
    }
  });

  server.listen(port, "127.0.0.1", () => {
    const url = `http://127.0.0.1:${port}`;
    console.log(`whiteboard viewer: ${url}  (root: ${root})`);
    if (open) { import("child_process").then(({ exec }) => { try { exec(`open "${url}"`); } catch {} }); }
  });
}

main();