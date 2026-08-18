// doc.mjs — block document as an append-only change log in changes/<rev>.json.
// The current document is the fold over all change files (sorted by rev); any
// past version is fold(changes up to rev N). Each change is one atomic file
// (link EXCL → no rev collision); past changes are never mutated. Comments are
// ops inside changes, so they persist across block edits (block-anchored, not
// change-anchored). Legacy state-based document.json auto-migrates to one
// baseline change on first load (lossless, one-time).
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { versionHash, validName, slugify } from "./store.mjs";

export const CHANGES = "changes";
const PAD = 6;
const newId = () => "c-" + crypto.randomBytes(3).toString("hex");
const nowIso = () => new Date().toISOString();
const padded = (rev) => String(rev).padStart(PAD, "0");

export function changesDir(dir) { return path.join(dir, CHANGES); }

// A session is a block-doc session when it has a changes/ dir (new model) or a
// legacy document.json (state model, auto-migrated on load).
export function isBlockDocDir(dir) {
  return fs.existsSync(changesDir(dir)) || fs.existsSync(path.join(dir, "document.json"));
}

export function readChanges(dir) {
  const d = changesDir(dir);
  if (!fs.existsSync(d)) return [];
  return fs.readdirSync(d)
    .filter((f) => f.endsWith(".json") && !f.startsWith(".tmp-"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(d, f), "utf8")); } catch { return null; } })
    .filter(Boolean)
    .sort((a, b) => (a.rev || 0) - (b.rev || 0));
}

// Append a change: allocates the next free rev atomically (link EXCL → no
// collision even with a concurrent writer). ops is a pre-validated array.
export function appendChange(dir, { id, title, by = "agent", summary = null, ops }) {
  const d = changesDir(dir);
  fs.mkdirSync(d, { recursive: true });
  const maxRev = readChanges(dir).reduce((m, c) => Math.max(m, c.rev || 0), 0);
  for (let rev = maxRev + 1; rev < maxRev + 1024; rev++) {
    const change = { rev, id: id || `rev-${rev}`, title: title || null, at: nowIso(), by, summary, ops };
    const target = path.join(d, `${padded(rev)}.json`);
    const tmp = path.join(d, `.tmp-${process.pid}-${rev}.json`);
    fs.writeFileSync(tmp, JSON.stringify(change, null, 2) + "\n");
    try { fs.linkSync(tmp, target); fs.unlinkSync(tmp); return change; }
    catch (e) { try { fs.unlinkSync(tmp); } catch {} if (e.code !== "EEXIST") throw e; }
  }
  throw new Error("could not allocate a change rev (too many collisions)");
}

function insertIndex(blocks, before, after) {
  if (before) { const i = blocks.findIndex((b) => b.name === before); return i === -1 ? blocks.length : i; }
  if (after) { const i = blocks.findIndex((b) => b.name === after); return i === -1 ? blocks.length : i + 1; }
  return blocks.length;
}

// Project a sorted change list to the current document state.
export function fold(changes) {
  const blocks = [];
  const comments = new Map(); // id -> comment (threaded)
  for (const ch of changes) {
    for (const e of ch.ops || []) {
      const at = e.at || ch.at;
      switch (e.op) {
        case "baseline":
          blocks.splice(0, blocks.length, ...(e.blocks || []).map((b) => ({ ...b })));
          for (const c of e.comments || []) comments.set(c.id, { ...c, replies: [...(c.replies || [])] });
          break;
        case "add": blocks.splice(insertIndex(blocks, e.before, e.after), 0, { name: e.name, md: e.md, ...(e.flags ? { flags: [...e.flags] } : {}) }); break;
        case "edit": { const b = blocks.find((x) => x.name === e.name); if (b) b.md = e.md; break; }
        case "move": { const i = blocks.findIndex((x) => x.name === e.name); if (i >= 0) { const [b] = blocks.splice(i, 1); blocks.splice(insertIndex(blocks, e.before, e.after), 0, b); } break; }
        case "rename": { const b = blocks.find((x) => x.name === e.from); if (b) b.name = e.to; for (const c of comments.values()) if (c.block === e.from) c.block = e.to; break; }
        case "remove": { const names = new Set(e.names || [e.name]); for (let i = blocks.length - 1; i >= 0; i--) if (names.has(blocks[i].name)) blocks.splice(i, 1); break; }
        case "flag": { const b = blocks.find((x) => x.name === e.name); if (b) { b.flags = b.flags || []; const on = e.on !== false; const has = b.flags.includes(e.flag); if (on && !has) b.flags.push(e.flag); if (!on && has) b.flags = b.flags.filter((f) => f !== e.flag); if (!b.flags.length) delete b.flags; } break; }
        case "comment": comments.set(e.id, { id: e.id, block: e.block, author: e.by || "agent", body: e.body, at, resolved: false, replies: [], ...(e.selector ? { selector: e.selector } : {}), ...(e.motivation ? { motivation: e.motivation } : {}) }); break;
        case "reply": { const c = comments.get(e.comment); if (c) c.replies.push({ id: e.id, author: e.by || "agent", body: e.body, at }); break; }
        case "resolve": { const c = comments.get(e.comment); if (c) c.resolved = e.unresolved ? false : true; break; }
        case "attention": comments.set(e.id, { id: e.id, block: e.block, author: e.by || "agent", body: e.body, at, resolved: false, replies: [], motivation: "highlighting" }); break;
      }
    }
  }
  const live = new Set(blocks.map((b) => b.name));
  const commentsArr = [...comments.values()].filter((c) => live.has(c.block))
    .sort((a, b) => (a.at || "").localeCompare(b.at || ""));
  const rev = changes.length ? changes[changes.length - 1].rev : 0;
  return { blocks, comments: commentsArr, rev, hash: versionHash(blocks), updatedAt: changes.length ? changes[changes.length - 1].at : null };
}

// Referential validation against the current folded doc. Throws on the first
// bad op so a multi-op change aborts before anything is appended.
export function validateOps(doc, ops) {
  const blockNames = new Set(doc.blocks.map((b) => b.name));
  const commentIds = new Set(doc.comments.map((c) => c.id));
  for (const e of ops) {
    if (!e || typeof e !== "object") throw new Error("each op must be an object");
    switch (e.op) {
      case "add": validName(e.name); if (blockNames.has(e.name)) throw new Error(`block "${e.name}" already exists`); break;
      case "edit": case "move": case "flag": if (!blockNames.has(e.name)) throw new Error(`no block "${e.name}"`); break;
      case "rename": validName(e.to); if (!blockNames.has(e.from)) throw new Error(`no block "${e.from}"`); if (blockNames.has(e.to)) throw new Error(`block "${e.to}" already exists`); break;
      case "remove": for (const n of (e.names || [e.name])) if (!blockNames.has(n)) throw new Error(`no block "${n}"`); break;
      case "comment": case "attention": if (!blockNames.has(e.block)) throw new Error(`no block "${e.block}"`); break;
      case "reply": case "resolve": if (!commentIds.has(e.comment)) throw new Error(`no comment "${e.comment}"`); break;
      case "baseline": break;
      default: throw new Error(`unknown op "${e.op}"`);
    }
  }
}

// Migrate a legacy state-based document.json to one baseline change. No-op if
// the change log already has entries or there is no legacy file.
function migrateLegacy(dir) {
  const f = path.join(dir, "document.json");
  if (!fs.existsSync(f) || (fs.existsSync(changesDir(dir)) && readChanges(dir).length)) return;
  let doc;
  try { doc = JSON.parse(fs.readFileSync(f, "utf8")); } catch { return; }
  if (!doc || !Array.isArray(doc.blocks)) return;
  appendChange(dir, { id: "baseline", title: "Import existing document", by: "agent", ops: [{ op: "baseline", blocks: doc.blocks, comments: doc.comments || [] }] });
}

export function loadDoc(dir) {
  if (!isBlockDocDir(dir)) return null;
  migrateLegacy(dir);
  return fold(readChanges(dir));
}

// ---- op builders (used by the CLI and the viewer) ----
export function commentOp(block, body, { by = "agent", selector = null, id = newId() } = {}) {
  return { op: "comment", id, block, by, body: String(body), at: nowIso(), ...(selector ? { selector } : {}) };
}
export function replyOp(commentId, body, { by = "agent", id = newId() } = {}) {
  return { op: "reply", comment: commentId, id, by, body: String(body), at: nowIso() };
}
export function resolveOp(commentId, resolved = true) {
  return { op: "resolve", comment: commentId, ...(resolved ? {} : { unresolved: true }) };
}
export function attentionOp(block, body, { by = "agent", id = newId() } = {}) {
  return { op: "attention", id, block, by, body: String(body), at: nowIso() };
}

export function changeIdFor(title) { return slugify(title) || null; }

// Build a {exact, prefix, suffix} repair-hint selector from a block's markdown
// and an exact quote, the way the viewer highlights (±32 chars of context).
export function selectorFor(md, exact) {
  const i = String(md).indexOf(exact);
  if (i === -1) throw new Error(`quote not found in block: "${exact.slice(0, 40)}…"`);
  const prefix = i > 0 ? md.slice(Math.max(0, i - 32), i) : "";
  const suffix = md.slice(i + exact.length, i + exact.length + 32);
  return { exact, prefix, suffix };
}