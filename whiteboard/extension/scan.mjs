// scan.mjs — session listing + actionable-item + unread helpers for both the
// new block-doc model (document.json) and the legacy model (deliverable.md +
// comments/ W3C annotations + chat/). Pure functions; the extension factory
// owns wake-dedupe state (handled set, seen comment ids, last-seen rev).
//
// Block-doc comment shape: { id, block, selector?, author, body, at, resolved,
// replies[] }. A comment is "actionable" (needs an agent reply) when
// author==="user", resolved===false, and no reply in replies[] has
// author==="agent".

import fs from "node:fs";
import path from "node:path";

export const isSessionDir = (n) => /^\d{4}-\d{2}-.+/.test(n);

function readJson(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fallback; }
}

// ---- block-doc model ----

export function docPath(dir) { return path.join(dir, "document.json"); }
export function isBlockDoc(dir) { return fs.existsSync(docPath(dir)); }

export function loadDoc(dir) {
  const doc = readJson(docPath(dir), null);
  if (!doc) return null;
  doc.blocks = doc.blocks || [];
  doc.comments = doc.comments || [];
  return doc;
}

export function isActionable(c) {
  if (!c || c.author !== "user") return false;
  if (c.resolved) return false;
  if (Array.isArray(c.replies) && c.replies.some((r) => r.author === "agent")) return false;
  return true;
}

export function actionableComments(doc) {
  return (doc.comments || []).filter(isActionable);
}

// ---- legacy model (deliverable.md + comments/ W3C annotations + chat/) ----

function readComments(dir) {
  const d = path.join(dir, "comments");
  if (!fs.existsSync(d)) return [];
  return fs.readdirSync(d).filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(d, f), "utf8")); } catch { return null; } }).filter(Boolean);
}
function readChat(dir) {
  const d = path.join(dir, "chat");
  if (!fs.existsSync(d)) return [];
  return fs.readdirSync(d).filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(d, f), "utf8")); } catch { return null; } }).filter(Boolean);
}
function readSeen(dir) { return readJson(path.join(dir, ".seen.json"), { lastSeenAt: null }); }
function readResolved(dir) { return readJson(path.join(dir, ".resolved.json"), {}); }
function computeUnread(annos, lastSeenAt) {
  return annos.filter((a) => {
    if (String(a?.creator?.name || "").toLowerCase() === "user") return false;
    return !lastSeenAt || (a.created || "") > lastSeenAt;
  }).length;
}

// Legacy actionable items: top-level human comment with no agent reply, or a
// human chat message with no agent chat reply after it.
export function legacyActionable(dir) {
  const items = [];
  const annos = readComments(dir);
  const resolved = readResolved(dir);
  const replied = new Set(annos.filter((a) => a.motivation === "replying" && a.target?.id).map((a) => a.target.id));
  for (const a of annos) {
    if (resolved[a.id]) continue;
    if (a.motivation !== "replying" && !(a.target && a.target.id) && String(a.creator?.name || "").toLowerCase() !== "agent" && !replied.has(a.id)) {
      items.push({ kind: "comment", id: a.id, block: null, text: a.body?.value || "" });
    }
  }
  const msgs = readChat(dir).sort((a, b) => (a.created || "").localeCompare(b.created || ""));
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    if (m.role !== "user") continue;
    const hasAgentAfter = msgs.slice(i + 1).some((x) => x.role === "agent" && (x.created || "") >= (m.created || ""));
    if (!hasAgentAfter) items.push({ kind: "chat", id: m.id, block: null, text: m.text || "" });
  }
  return items;
}

export function legacyUnread(dir) {
  const annos = readComments(dir);
  const seen = readSeen(dir);
  return computeUnread(annos, seen.lastSeenAt);
}

// ---- session listing (both models) ----

export function listSessions(root) {
  const out = [];
  if (!fs.existsSync(root)) return out;
  for (const project of fs.readdirSync(root)) {
    const pd = path.join(root, project);
    if (!fs.statSync(pd).isDirectory()) continue;
    for (const name of fs.readdirSync(pd)) {
      if (!isSessionDir(name)) continue;
      const dir = path.join(pd, name);
      if (!fs.statSync(dir).isDirectory()) continue;
      const blockDoc = isBlockDoc(dir);
      const manifest = readJson(path.join(dir, "manifest.json"), null);
      out.push({ project, slug: name, dir, blockDoc, owner: manifest?.owner || null });
    }
  }
  return out;
}

// Unread count for a single session (footer badge). For block-doc sessions,
// "unread" = actionable unresolved user comments. For legacy, the existing
// resolved/unread mechanism.
export function sessionUnread(s) {
  if (s.blockDoc) {
    const doc = loadDoc(s.dir);
    return doc ? actionableComments(doc).length : 0;
  }
  return legacyUnread(s.dir);
}