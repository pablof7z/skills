#!/usr/bin/env node
// Whiteboard session viewer server.
//
// Serves a localhost web UI that renders a session's deliverable.md and lets a
// human add W3C Web Annotation comments anchored to spans of the document at a
// specific version. Comments are stored as JSON files in the session directory;
// the server watches the filesystem and pushes live updates to the browser via
// SSE. The companion agent watches the same comments/ directory (see
// wait-for-comment.mjs) and writes reply annotation files, which also appear
// live.
//
// Usage: node server.mjs <session-dir> [--port 4318] [--open]

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const VIEWER_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_PORT = 4318;

function parseArgs(argv) {
  const args = argv.slice(2);
  const positional = [];
  let port = DEFAULT_PORT;
  let open = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--port") { port = Number(args[++i]); }
    else if (a.startsWith("--port=")) { port = Number(a.slice(7)); }
    else if (a === "--open") { open = true; }
    else if (a === "--help" || a === "-h") {
      console.log("Usage: server.mjs <session-dir> [--port 4318] [--open]");
      process.exit(0);
    } else positional.push(a);
  }
  const sessionDir = positional[0];
  if (!sessionDir) {
    console.error("Error: session directory is required.");
    console.error("Usage: server.mjs <session-dir> [--port 4318] [--open]");
    process.exit(2);
  }
  return { sessionDir: path.resolve(sessionDir), port, open };
}

const DELIVERABLE = "deliverable.md";
const NOTES = "notes.md";
const MANIFEST = "manifest.json";
const COMMENTS_DIR = "comments";
const VERSIONS_DIR = "versions";

function sha12(text) {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex").slice(0, 12);
}

function readJsonSafe(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); }
  catch { return fallback; }
}

function ensureDirs(sessionDir) {
  fs.mkdirSync(path.join(sessionDir, COMMENTS_DIR), { recursive: true });
  fs.mkdirSync(path.join(sessionDir, VERSIONS_DIR), { recursive: true });
}

function snapshotVersion(sessionDir, content) {
  const v = sha12(content);
  const p = path.join(sessionDir, VERSIONS_DIR, `${v}.md`);
  if (!fs.existsSync(p)) fs.writeFileSync(p, content, "utf8");
  return v;
}

function readDeliverable(sessionDir) {
  const p = path.join(sessionDir, DELIVERABLE);
  const content = fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "";
  return { content, version: sha12(content) };
}

function readNotes(sessionDir) {
  const p = path.join(sessionDir, NOTES);
  return fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "";
}

function readManifest(sessionDir) {
  return readJsonSafe(path.join(sessionDir, MANIFEST), {
    name: path.basename(sessionDir),
    status: "exploring",
    project: "",
    createdAt: new Date().toISOString(),
  });
}

function readComments(sessionDir) {
  const dir = path.join(sessionDir, COMMENTS_DIR);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => {
      try { return JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")); }
      catch { return null; }
    })
    .filter(Boolean);
}

function uuid() {
  return crypto.randomUUID();
}

function nowIso() {
  return new Date().toISOString();
}

function commentFileName(anno) {
  const ts = new Date(anno.created).getTime();
  const rand = anno.id.split("-").pop().slice(0, 6);
  return `${ts}-${rand}.json`;
}

function writeComment(sessionDir, anno) {
  const dir = path.join(sessionDir, COMMENTS_DIR);
  fs.mkdirSync(dir, { recursive: true });
  const file = commentFileName(anno);
  fs.writeFileSync(path.join(dir, file), JSON.stringify(anno, null, 2) + "\n", "utf8");
  return file;
}

// ---- HTTP helpers ----

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  });
  res.end(body);
}

function sendText(res, code, text, type = "text/plain; charset=utf-8") {
  res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store" });
  res.end(text);
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

function serveStatic(res, relPath) {
  const p = path.join(VIEWER_DIR, relPath);
  if (!p.startsWith(VIEWER_DIR)) return sendText(res, 403, "forbidden");
  if (!fs.existsSync(p) || fs.statSync(p).isDirectory()) return sendText(res, 404, "not found");
  const mime = MIME[path.extname(p)] || "application/octet-stream";
  res.writeHead(200, { "Content-Type": mime, "Cache-Control": "no-store" });
  fs.createReadStream(p).pipe(res);
}

// ---- SSE ----

const sseClients = new Set();

function sseAttach(res) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-store, no-transform",
    Connection: "keep-alive",
    "Access-Control-Allow-Origin": "*",
  });
  res.write(": hello\n\n");
  sseClients.add(res);
  const keep = setInterval(() => { try { res.write(": ping\n\n"); } catch {} }, 15000);
  res.on("close", () => { clearInterval(keep); sseClients.delete(res); });
}

function broadcast(event, data) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const c of sseClients) { try { c.write(payload); } catch {} }
}

// ---- main ----

function main() {
  const { sessionDir, port, open } = parseArgs(process.argv);
  ensureDirs(sessionDir);

  const state = { deliverable: readDeliverable(sessionDir), notes: readNotes(sessionDir) };
  snapshotVersion(sessionDir, state.deliverable.content);

  const refresh = () => {
    state.deliverable = readDeliverable(sessionDir);
    state.notes = readNotes(sessionDir);
    snapshotVersion(sessionDir, state.deliverable.content);
  };

  // Watch filesystem. fs.watch is platform-dependent; use recursive where supported.
  try {
    fs.watch(path.join(sessionDir, DELIVERABLE), () => {
      refresh();
      broadcast("deliverable", { version: state.deliverable.version });
    });
  } catch (e) { console.error("watch deliverable failed:", e.message); }
  try {
    fs.watch(path.join(sessionDir, NOTES), () => {
      state.notes = readNotes(sessionDir);
      broadcast("notes", {});
    });
  } catch (e) { console.error("watch notes failed:", e.message); }
  try {
    fs.watch(path.join(sessionDir, COMMENTS_DIR), { recursive: true }, () => {
      broadcast("comments", {});
    });
  } catch (e) { console.error("watch comments failed:", e.message); }

  const server = http.createServer(async (req, res) => {
    const u = new URL(req.url, `http://localhost:${port}`);
    const p = u.pathname;

    if (req.method === "OPTIONS") { sendJson(res, 204, {}); return; }

    // Static viewer assets
    if (p === "/" || p === "/index.html") return serveStatic(res, "index.html");
    if (p === "/app.mjs") return serveStatic(res, "app.mjs");
    if (p === "/styles.css") return serveStatic(res, "styles.css");
    if (p.startsWith("/vendor/")) return serveStatic(res, p.slice(1));

    // API
    if (p === "/api/session" && req.method === "GET") {
      const m = readManifest(sessionDir);
      return sendJson(res, 200, {
        ...m,
        sessionDir,
        deliverableVersion: state.deliverable.version,
        notesLength: state.notes.length,
      });
    }
    if (p === "/api/deliverable" && req.method === "GET") {
      return sendJson(res, 200, { content: state.deliverable.content, version: state.deliverable.version });
    }
    if (p === "/api/notes" && req.method === "GET") {
      return sendJson(res, 200, { content: state.notes });
    }
    if (p === "/api/comments" && req.method === "GET") {
      return sendJson(res, 200, { annotations: readComments(sessionDir) });
    }
    if (p === "/api/events" && req.method === "GET") {
      return sseAttach(res);
    }

    if (p === "/api/comments" && req.method === "POST") {
      let body = "";
      for await (const chunk of req) body += chunk;
      let data; try { data = JSON.parse(body); } catch { return sendJson(res, 400, { error: "bad json" }); }
      const creator = data.creator || "user";
      const anno = {
        "@context": "http://www.w3.org/ns/anno.jsonld",
        type: "Annotation",
        id: `urn:uuid:${uuid()}`,
        motivation: data.motivation || "commenting",
        created: nowIso(),
        creator: { type: "Person", name: creator },
        body: { type: "TextualBody", value: String(data.text ?? "").slice(0, 8000), format: "text/markdown", language: "en" },
      };
      if (data.replyTo) {
        anno.motivation = "replying";
        anno.target = { id: data.replyTo, type: "Annotation" };
        anno.body.inReplyTo = data.replyTo;
      } else {
        const version = data.version || state.deliverable.version;
        anno.target = {
          source: DELIVERABLE,
          version,
          selector: Array.isArray(data.selector) ? data.selector : [],
        };
      }
      writeComment(sessionDir, anno);
      // broadcast handled by fs watch; also confirm to caller
      return sendJson(res, 201, anno);
    }

    if (p === "/api/manifest" && req.method === "PATCH") {
      let body = "";
      for await (const chunk of req) body += chunk;
      let data; try { data = JSON.parse(body); } catch { return sendJson(res, 400, { error: "bad json" }); }
      const m = readManifest(sessionDir);
      const next = { ...m, ...data };
      fs.writeFileSync(path.join(sessionDir, MANIFEST), JSON.stringify(next, null, 2) + "\n", "utf8");
      return sendJson(res, 200, next);
    }

    return sendText(res, 404, "not found");
  });

  server.listen(port, "127.0.0.1", () => {
    const url = `http://127.0.0.1:${port}`;
    console.log(`whiteboard viewer: ${url}`);
    console.log(`session: ${sessionDir}`);
    if (open) {
      import("child_process").then(({ exec }) => {
        try { exec(`open "${url}"`); } catch {}
      });
    }
  });
}

main();