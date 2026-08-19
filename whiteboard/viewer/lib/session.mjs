// Session read/write helpers shared by the whiteboard viewer server (node).
// A session is a directory under the whiteboard root matching /^\d{4}-\d{2}-/;
// its parent directory is the project slug. The document is the block model
// (changes/<rev>.json fold, via cli/doc.mjs); unread counts come from
// actionable comments + chat (cli/scan.mjs).

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { readChanges } from "../../cli/doc.mjs";
import { actionableItems } from "../../cli/scan.mjs";

export const NOTES = "notes.md";
export const MANIFEST = "manifest.json";
export const CHAT_DIR = "chat";
export const VIEWED_FILE = ".viewed.json";

export function isSessionDir(name) {
  return /^\d{4}-\d{2}-.+/.test(name);
}

export function ensureDirs(sessionDir) {
  fs.mkdirSync(path.join(sessionDir, CHAT_DIR), { recursive: true });
}

export function readJsonSafe(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); }
  catch { return fallback; }
}

export function readNotes(sessionDir) {
  const p = path.join(sessionDir, NOTES);
  return fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "";
}

export function readManifest(sessionDir) {
  return readJsonSafe(path.join(sessionDir, MANIFEST), {
    name: path.basename(sessionDir),
    status: "exploring",
    project: path.basename(path.dirname(sessionDir)),
    createdAt: new Date().toISOString(),
  });
}

// ---- chat (file-queue; the agent writes reply files directly, viewer renders) ----

export function readChat(sessionDir) {
  const dir = path.join(sessionDir, CHAT_DIR);
  if (!fs.existsSync(dir)) return [];
  const out = fs.readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")); } catch { return null; } })
    .filter(Boolean);
  out.sort((a, b) => (a.created || "").localeCompare(b.created || ""));
  return out;
}

export function writeChatMessage(sessionDir, msg) {
  const dir = path.join(sessionDir, CHAT_DIR);
  fs.mkdirSync(dir, { recursive: true });
  const ts = new Date(msg.created).getTime() || Date.now();
  const rand = msg.id.split("-").pop().slice(0, 6);
  fs.writeFileSync(path.join(dir, `${ts}-${rand}.json`), JSON.stringify(msg, null, 2) + "\n", "utf8");
}

// viewedVersion: the rev the human last actively reviewed (the diff "Done"
// button posts the current rev). Used by the block viewer to show what changed
// since the last review.
export function readViewed(sessionDir) {
  return readJsonSafe(path.join(sessionDir, VIEWED_FILE), { version: null, at: null });
}

export function writeViewed(sessionDir, version) {
  fs.writeFileSync(
    path.join(sessionDir, VIEWED_FILE),
    JSON.stringify({ version, at: nowIso() }, null, 2) + "\n",
    "utf8",
  );
}

export function uuid() { return crypto.randomUUID(); }
export function nowIso() { return new Date().toISOString(); }

// Walk the root for projects -> sessions and return a summary list. Unread =
// actionable user comments + unanswered user chat. commentCount = top-level
// block-doc comments. lastActivity = newest of manifest createdAt, latest
// change, latest chat message.
export function listSessions(root) {
  const out = [];
  if (!fs.existsSync(root)) return out;
  for (const project of fs.readdirSync(root)) {
    const projDir = path.join(root, project);
    if (!fs.statSync(projDir).isDirectory()) continue;
    for (const name of fs.readdirSync(projDir)) {
      if (!isSessionDir(name)) continue;
      const dir = path.join(projDir, name);
      if (!fs.statSync(dir).isDirectory()) continue;
      const m = readManifest(dir);
      const changes = readChanges(dir);
      const latestChangeAt = changes.reduce((acc, c) => ((c.at || "") > acc ? c.at : acc), "");
      const chat = readChat(dir);
      const latestChatAt = chat.reduce((acc, c) => ((c.created || "") > acc ? c.created : acc), "");
      const lastActivity = [m.createdAt || "", latestChangeAt, latestChatAt].sort().pop() || "";
      const docComments = changes.length ? countComments(dir) : 0;
      out.push({
        project,
        slug: name,
        dir,
        name: m.name || name,
        status: m.status || "exploring",
        createdAt: m.createdAt || "",
        lastActivity,
        unread: actionableItems(dir).length,
        commentCount: docComments,
      });
    }
  }
  out.sort((a, b) => (b.lastActivity || "").localeCompare(a.lastActivity || ""));
  return out;
}

// Top-level block-doc comments (replies live inside c.replies, not as separate
// comments). Computed from the fold so it matches what the viewer renders.
import { loadDoc } from "../../cli/doc.mjs";
function countComments(dir) {
  const doc = loadDoc(dir);
  return doc ? (doc.comments || []).length : 0;
}