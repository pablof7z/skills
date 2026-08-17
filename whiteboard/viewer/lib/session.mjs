// Session read/write helpers shared by the whiteboard viewer server.
// A session is a directory under the whiteboard root that matches
// /^\d{4}-\d{2}-/ ; its parent directory is the project slug.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export const DELIVERABLE = "deliverable.md";
export const NOTES = "notes.md";
export const MANIFEST = "manifest.json";
export const COMMENTS_DIR = "comments";
export const VERSIONS_DIR = "versions";
export const SEEN_FILE = ".seen.json";

export function sha12(text) {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex").slice(0, 12);
}

export function isSessionDir(name) {
  return /^\d{4}-\d{2}-.+/.test(name);
}

export function ensureDirs(sessionDir) {
  fs.mkdirSync(path.join(sessionDir, COMMENTS_DIR), { recursive: true });
  fs.mkdirSync(path.join(sessionDir, VERSIONS_DIR), { recursive: true });
}

export function readJsonSafe(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); }
  catch { return fallback; }
}

export function snapshotVersion(sessionDir, content) {
  const v = sha12(content);
  const p = path.join(sessionDir, VERSIONS_DIR, `${v}.md`);
  if (!fs.existsSync(p)) fs.writeFileSync(p, content, "utf8");
  return v;
}

export function readDeliverable(sessionDir) {
  const p = path.join(sessionDir, DELIVERABLE);
  const content = fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "";
  return { content, version: sha12(content) };
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

export function readComments(sessionDir) {
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

export function readSeen(sessionDir) {
  return readJsonSafe(path.join(sessionDir, SEEN_FILE), { lastSeenAt: null });
}

export function writeSeen(sessionDir, lastSeenAt) {
  fs.writeFileSync(
    path.join(sessionDir, SEEN_FILE),
    JSON.stringify({ lastSeenAt }, null, 2) + "\n",
    "utf8",
  );
}

// Unread = annotations the human hasn't seen yet: created after lastSeenAt and
// not authored by the human (i.e. agent replies). If never seen, all non-human
// annotations count.
export function computeUnread(annotations, lastSeenAt) {
  return annotations.filter((a) => {
    const who = String((a.creator && a.creator.name) || "").toLowerCase();
    if (who === "user") return false;
    if (!lastSeenAt) return true;
    return (a.created || "") > lastSeenAt;
  }).length;
}

export function uuid() {
  return crypto.randomUUID();
}

export function nowIso() {
  return new Date().toISOString();
}

export function commentFileName(anno) {
  const ts = new Date(anno.created).getTime() || Date.now();
  const rand = anno.id.split("-").pop().slice(0, 6);
  return `${ts}-${rand}.json`;
}

export function writeComment(sessionDir, anno) {
  const dir = path.join(sessionDir, COMMENTS_DIR);
  fs.mkdirSync(dir, { recursive: true });
  const file = commentFileName(anno);
  fs.writeFileSync(path.join(dir, file), JSON.stringify(anno, null, 2) + "\n", "utf8");
  return file;
}

// Walk the root for projects -> sessions and return a summary list.
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
      const annos = readComments(dir);
      const seen = readSeen(dir);
      const latestAnno = annos.reduce((acc, a) => (a.created && a.created > acc ? a.created : acc), "");
      const lastActivity = [m.createdAt || "", latestAnno].sort().pop() || "";
      out.push({
        project,
        slug: name,
        dir,
        name: m.name || name,
        status: m.status || "exploring",
        createdAt: m.createdAt || "",
        lastSeenAt: seen.lastSeenAt,
        lastActivity,
        unread: computeUnread(annos, seen.lastSeenAt),
        commentCount: annos.filter((a) => a.motivation !== "replying").length,
      });
    }
  }
  out.sort((a, b) => (b.lastActivity || "").localeCompare(a.lastActivity || ""));
  return out;
}