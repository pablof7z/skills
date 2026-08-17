#!/usr/bin/env node
// Whiteboard viewer server (root-based).
//
// Serves an explorer + per-session viewer for all whiteboard sessions under a
// root directory (default ~/whiteboard). The explorer lists projects/sessions
// with unread badges; each session view renders deliverable.md and supports
// W3C Web Annotation comments. The server watches the filesystem and pushes
// live updates to the browser via SSE.
//
// Usage: node server.mjs [<root-dir>] [--port 4318] [--open]

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import * as S from "./lib/session.mjs";

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
  res.on("close", () => { clearInterval(keep); explorerClients.delete(res); for (const set of sessionClients.values()) set.delete(res); });
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

// ---- per-session request handler ----
async function handleSession(req, res, root, project, slug, rest) {
  const dir = sessionDir(root, project, slug);
  if (!dir) return sendJson(res, 404, { error: "session not found" });
  S.ensureDirs(dir);
  const key = `${project}/${slug}`;
  const m = req.method;

  if (rest === "session" && m === "GET") {
    const man = S.readManifest(dir);
    const d = S.readDeliverable(dir);
    return sendJson(res, 200, { ...man, project, slug, sessionDir: dir, deliverableVersion: d.version });
  }
  if (rest === "deliverable" && m === "GET") {
    const d = S.readDeliverable(dir);
    S.snapshotVersion(dir, d.content);
    return sendJson(res, 200, d);
  }
  if (rest === "notes" && m === "GET") return sendJson(res, 200, { content: S.readNotes(dir) });
  if (rest === "comments" && m === "GET") return sendJson(res, 200, { annotations: S.readComments(dir) });
  if (rest === "events" && m === "GET") { sseStart(res); sessionClientsFor(key).add(res); return; }
  if (rest === "comments" && m === "POST") {
    const data = await readBody(req).catch(() => null);
    if (!data) return sendJson(res, 400, { error: "bad json" });
    const creator = data.creator || "user";
    const anno = {
      "@context": "http://www.w3.org/ns/anno.jsonld",
      type: "Annotation",
      id: `urn:uuid:${S.uuid()}`,
      motivation: data.motivation || "commenting",
      created: S.nowIso(),
      creator: { type: "Person", name: creator },
      body: { type: "TextualBody", value: String(data.text ?? "").slice(0, 8000), format: "text/markdown", language: "en" },
    };
    if (data.replyTo) {
      anno.motivation = "replying";
      anno.target = { id: data.replyTo, type: "Annotation" };
      anno.body.inReplyTo = data.replyTo;
    } else {
      anno.target = { source: S.DELIVERABLE, version: data.version || S.readDeliverable(dir).version, selector: Array.isArray(data.selector) ? data.selector : [] };
    }
    S.writeComment(dir, anno);
    return sendJson(res, 201, anno);
  }
  if (rest === "seen" && m === "POST") {
    S.writeSeen(dir, S.nowIso());
    broadcast(explorerClients, "sessions", {});
    return sendJson(res, 200, { lastSeenAt: S.readSeen(dir).lastSeenAt });
  }
  if (rest === "manifest" && m === "PATCH") {
    const data = await readBody(req).catch(() => null);
    if (!data) return sendJson(res, 400, { error: "bad json" });
    const next = { ...S.readManifest(dir), ...data };
    fs.writeFileSync(path.join(dir, S.MANIFEST), JSON.stringify(next, null, 2) + "\n", "utf8");
    broadcast(explorerClients, "sessions", {});
    return sendJson(res, 200, next);
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
          const key = `${segs[0]}/${segs[1]}`;
          broadcast(sessionClientsFor(key), "refresh", {});
          return;
        }
      }
      for (const set of sessionClients.values()) broadcast(set, "refresh", {});
    });
  } catch (e) { console.error("watch root failed:", e.message); }

  const server = http.createServer(async (req, res) => {
    try {
      const u = new URL(req.url, `http://localhost:${port}`);
      const p = decodeURIComponent(u.pathname);
      if (req.method === "OPTIONS") return sendJson(res, 204, {});

      // Static assets
      if (p === "/" || p === "/index.html") return serveStatic(res, "index.html");
      if (p === "/main.mjs") return serveStatic(res, "main.mjs");
      if (p === "/viewer.mjs") return serveStatic(res, "viewer.mjs");
      if (p === "/explorer.mjs") return serveStatic(res, "explorer.mjs");
      if (p === "/styles.css") return serveStatic(res, "styles.css");
      if (p.startsWith("/vendor/")) return serveStatic(res, p.slice(1));

      // API
      if (p === "/api/sessions" && req.method === "GET") return sendJson(res, 200, { sessions: S.listSessions(root) });
      if (p === "/api/events" && req.method === "GET") { sseStart(res); explorerClients.add(res); return; }

      const sess = p.match(/^\/api\/session\/([^/]+)\/([^/]+)\/([^/]+)$/);
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