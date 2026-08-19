// doc.mjs — block document as an append-only change log in changes/<rev>.json.
//
// The current document is the fold over all change files (sorted by rev). Each
// change is one atomic file (link EXCL → no rev collision); past changes are
// never mutated.
//
// Annotations are the one primitive for anything anchored to a spot in the doc.
// An annotation has a `kind` (see kinds.mjs: question/warning/objection/note are
// replyable threads; unverified/superseded/needs-attention/decided are short
// status tags), an anchor (block + selector span), an optional body, an
// author/at, a state (active|resolved|removed), and optional replies (threads).
// Color/rendering is by kind (viewer-side); there is no separate "attention"
// concept and no `motivation` field. The fold projects annotations to a single
// viewer-facing `annotations` list. Change files use the unified
// `attach`/`reply`/`resolve`/`detach`/`amend` ops.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { versionHash, validName, slugify, agentName, provenance } from "./store.mjs";
import { resolveKind, isTagKind } from "./kinds.mjs";

export const CHANGES = "changes";
const PAD = 6;
const newId = () => "c-" + crypto.randomBytes(3).toString("hex");
const nowIso = () => new Date().toISOString();
const padded = (rev) => String(rev).padStart(PAD, "0");

// The default file path for blocks with no explicit path. Existing sessions (blocks
// with no path) all live here, so they render as a single file — fully backward
// compatible. Block identity is (path, name); names are unique WITHIN a path, so
// each file can have its own `intro`/`examples`/… sections.
export const DEFAULT_PATH = "default.md";

export function changesDir(dir) { return path.join(dir, CHANGES); }
export function isBlockDocDir(dir) {
  return fs.existsSync(changesDir(dir));
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

// Append a change: allocates the next free rev atomically (link EXCL).
export function appendChange(dir, { id, title, by = agentName(), summary = null, ops, via }) {
  const d = changesDir(dir);
  fs.mkdirSync(d, { recursive: true });
  const maxRev = readChanges(dir).reduce((m, c) => Math.max(m, c.rev || 0), 0);
  for (let rev = maxRev + 1; rev < maxRev + 1024; rev++) {
    const change = { rev, id: id || `rev-${rev}`, title: title || null, at: nowIso(), by, summary, ops, via: via || provenance() };
    const target = path.join(d, `${padded(rev)}.json`);
    const tmp = path.join(d, `.tmp-${process.pid}-${rev}.json`);
    fs.writeFileSync(tmp, JSON.stringify(change, null, 2) + "\n");
    try { fs.linkSync(tmp, target); fs.unlinkSync(tmp); return change; }
    catch (e) { try { fs.unlinkSync(tmp); } catch {} if (e.code !== "EEXIST") throw e; }
  }
  throw new Error("could not allocate a change rev (too many collisions)");
}

function insertIndex(blocks, before, after, path) {
  const p = path || DEFAULT_PATH;
  if (before) { const i = blocks.findIndex((b) => b.name === before && b.path === p); if (i !== -1) return i; }
  if (after) { const i = blocks.findIndex((b) => b.name === after && b.path === p); if (i !== -1) return i + 1; }
  // no anchor (or anchor not found in this path): append after the last block of
  // this path, or at the global end if the path has no blocks yet.
  let last = -1;
  for (let i = blocks.length - 1; i >= 0; i--) if (blocks[i].path === p) { last = i; break; }
  return last === -1 ? blocks.length : last + 1;
}

function makeAtt(e, at) {
  return { id: e.id, kind: resolveKind(e.kind, e.motivation), block: e.block, path: e.path || DEFAULT_PATH, selector: e.selector || null,
    body: e.body ?? null, by: e.by || "agent",
    at, state: "active", replies: [] };
}

// Project a sorted change list to the current document state. Attachments are
// the source of truth; the projection derives doc.comments + block.flags in the
// shape the viewer expects. Attachments whose block is gone are hidden (no
// orphan surfacing — per design). Block rename reanchors attachments.
export function fold(changes) {
  const blocks = [];
  const att = new Map(); // id -> attachment
  for (const ch of changes) {
    for (const e of ch.ops || []) {
      const at = e.at || ch.at;
      switch (e.op) {
        case "baseline":
          blocks.splice(0, blocks.length, ...(e.blocks || []).map((b) => ({ name: b.name, md: b.md, path: b.path || DEFAULT_PATH, ...(b.flags ? { flags: [...b.flags] } : {}) })));
          for (const a of (e.attachments || [])) att.set(a.id, { ...a, replies: [...(a.replies || [])] });
          break;
        case "add": blocks.splice(insertIndex(blocks, e.before, e.after, e.path), 0, { name: e.name, md: e.md, path: e.path || DEFAULT_PATH, ...(e.flags ? { flags: [...e.flags] } : {}) }); break;
        case "edit": { const b = blocks.find((x) => x.name === e.name && x.path === (e.path || DEFAULT_PATH)); if (b) b.md = e.md; break; }
        case "move": { const p = e.path || DEFAULT_PATH; const i = blocks.findIndex((x) => x.name === e.name && x.path === p); if (i >= 0) { const [b] = blocks.splice(i, 1); blocks.splice(insertIndex(blocks, e.before, e.after, p), 0, b); } break; }
        case "rename": { const p = e.path || DEFAULT_PATH; const b = blocks.find((x) => x.name === e.from && x.path === p); if (b) b.name = e.to; for (const a of att.values()) if (a.block === e.from && a.path === p) a.block = e.to; break; }
        case "remove": { const p = e.path || DEFAULT_PATH; const names = new Set(e.names || [e.name]); for (let i = blocks.length - 1; i >= 0; i--) if (names.has(blocks[i].name) && blocks[i].path === p) blocks.splice(i, 1); for (const a of att.values()) if (names.has(a.block) && a.path === p) a.state = "removed"; break; }
        case "attach": { const id = e.id || newId(); att.set(id, makeAtt({ ...e, id }, at)); break; }
        case "reply": { const a = att.get(e.to ?? e.comment); if (a) a.replies.push({ id: e.id || newId(), author: e.by || "agent", body: e.body, at }); break; }
        case "resolve": { const a = att.get(e.id ?? e.comment); if (a) a.state = e.unresolved ? "active" : "resolved"; break; }
        case "detach": { const a = att.get(e.id); if (a) a.state = "removed"; break; }
        case "amend": { const a = att.get(e.id); if (a) { if (e.body !== undefined) a.body = e.body; if (e.selector !== undefined) a.selector = e.selector; } break; }
      }
    }
  }
  // project annotations → a single viewer-facing list. Tags (isTagKind) and
  // threads share one shape; the viewer splits them by `isTag`. Legacy
  // block-level annotations (selector null — old `wb change comment` with no
  // --exact) are reanchored to the block's H1 so nothing is block-level anymore.
  const live = new Set(blocks.map((b) => b.path + "\0" + b.name));
  const byBlock = new Map();
  for (const b of blocks) byBlock.set(b.path + "\0" + b.name, b);
  const annotations = [];
  for (const a of att.values()) {
    if (!live.has(a.path + "\0" + a.block) || a.state === "removed") continue;
    if (!a.selector || !a.selector.exact) {
      const b = byBlock.get(a.path + "\0" + a.block);
      const h1 = b ? h1Of(b.md) : null;
      if (h1) a.selector = { exact: h1, prefix: "", suffix: "" };
    }
    annotations.push({
      id: a.id, kind: a.kind, isTag: isTagKind(a.kind), block: a.block, path: a.path,
      selector: a.selector || null, body: a.body || "", author: a.by, at: a.at,
      resolved: a.state === "resolved", state: a.state, replies: a.replies || [],
    });
  }
  annotations.sort((a, b) => (a.at || "").localeCompare(b.at || ""));
  const rev = changes.length ? changes[changes.length - 1].rev : 0;
  return { blocks, annotations, attachments: [...att.values()], rev, hash: versionHash(blocks), updatedAt: changes.length ? changes[changes.length - 1].at : null };
}

// First H1 heading text of a block's markdown (the title line), collapsed to a
// single line. Used to reanchor legacy block-level annotations to the block's
// heading so no annotation is block-level under the new model.
function h1Of(md) {
  const m = String(md || "").match(/^#[^#].*$/m);
  if (!m) return null;
  return m[0].replace(/^#\s+/, "").replace(/\s+/g, " ").trim() || null;
}

// Referential validation against the current folded doc. Throws on the first
// bad op so a multi-op change aborts before anything is appended.
export function validateOps(doc, ops) {
  const blockNames = new Map();
  const namesOf = (p) => { let s = blockNames.get(p); if (!s) { s = new Set(); blockNames.set(p, s); } return s; };
  for (const b of doc.blocks) namesOf(b.path || DEFAULT_PATH).add(b.name);
  const attIds = new Set(doc.attachments.map((a) => a.id));
  for (const e of ops) {
    if (!e || typeof e !== "object") throw new Error("each op must be an object");
    const p = e.path || DEFAULT_PATH;
    switch (e.op) {
      case "add": validName(e.name); if (namesOf(p).has(e.name)) throw new Error(`block "${e.name}" already exists in ${p}`); break;
      case "edit": case "move": if (!namesOf(p).has(e.name)) throw new Error(`no block "${e.name}" in ${p}`); break;
      case "rename": validName(e.to); if (!namesOf(p).has(e.from)) throw new Error(`no block "${e.from}" in ${p}`); if (namesOf(p).has(e.to)) throw new Error(`block "${e.to}" already exists in ${p}`); break;
      case "remove": for (const n of (e.names || [e.name])) if (!namesOf(p).has(n)) throw new Error(`no block "${n}" in ${p}`); break;
      case "attach": if (!namesOf(p).has(e.block)) throw new Error(`no block "${e.block}" in ${p}`); break;
      case "reply": if (!attIds.has(e.to ?? e.comment)) throw new Error(`no attachment "${e.to ?? e.comment}"`); break;
      case "resolve": case "detach": case "amend": { const k = e.id ?? e.comment; if (!attIds.has(k)) throw new Error(`no attachment "${k}"`); break; }
      case "baseline": break;
      default: throw new Error(`unknown op "${e.op}"`);
    }
  }
}

// Validate a transaction's ops in order against the doc AS IT EVOLVES through
// the ops themselves (the WIP doc). Each op is checked against the running
// block/attachment state, then the state is advanced to mirror `fold` — so an op
// can reference a block or attachment created by an earlier op in the SAME tx
// (e.g. add a block then move/flag/comment it, or comment then reply/resolve).
export function validateOpsInOrder(baseDoc, ops) {
  const blockNames = new Map();
  const namesOf = (p) => { let s = blockNames.get(p); if (!s) { s = new Set(); blockNames.set(p, s); } return s; };
  for (const b of baseDoc.blocks) namesOf(b.path || DEFAULT_PATH).add(b.name);
  const attIds = new Set(baseDoc.attachments.map((a) => a.id));
  for (const e of ops) {
    if (!e || typeof e !== "object") throw new Error("each op must be an object");
    const p = e.path || DEFAULT_PATH;
    switch (e.op) {
      case "add": validName(e.name); if (namesOf(p).has(e.name)) throw new Error(`block "${e.name}" already exists in ${p}`); namesOf(p).add(e.name); break;
      case "edit": case "move": if (!namesOf(p).has(e.name)) throw new Error(`no block "${e.name}" in ${p}`); break;
      case "rename": validName(e.to); if (!namesOf(p).has(e.from)) throw new Error(`no block "${e.from}" in ${p}`); if (namesOf(p).has(e.to)) throw new Error(`block "${e.to}" already exists in ${p}`); namesOf(p).delete(e.from); namesOf(p).add(e.to); break;
      case "remove": for (const n of (e.names || [e.name])) { if (!namesOf(p).has(n)) throw new Error(`no block "${n}" in ${p}`); namesOf(p).delete(n); } break;
      case "attach": if (!namesOf(p).has(e.block)) throw new Error(`no block "${e.block}" in ${p}`); if (e.id) attIds.add(e.id); break;
      case "reply": if (!attIds.has(e.to ?? e.comment)) throw new Error(`no attachment "${e.to ?? e.comment}"`); break;
      case "resolve": case "detach": case "amend": { const k = e.id ?? e.comment; if (!attIds.has(k)) throw new Error(`no attachment "${k}"`); break; }
      case "baseline": break;
      default: throw new Error(`unknown op "${e.op}"`);
    }
  }
}

export function loadDoc(dir) {
  if (!isBlockDocDir(dir)) return null;
  return fold(readChanges(dir));
}

// ---- op builders (used by the CLI and the viewer) ----
export function attachOp(kind, block, { body = null, selector = null, by = agentName(), id = newId(), path = DEFAULT_PATH } = {}) {
  return { op: "attach", id, kind, block, by, body, selector, path, at: nowIso() };
}
export function replyOp(to, body, { by = agentName(), id = newId() } = {}) {
  return { op: "reply", to, id, by, body: String(body), at: nowIso() };
}
export function resolveOp(id, resolved = true) {
  return { op: "resolve", id, ...(resolved ? {} : { unresolved: true }) };
}
export function detachOp(id) { return { op: "detach", id }; }
export function amendOp(id, { body, selector } = {}) {
  const o = { op: "amend", id }; if (body !== undefined) o.body = body; if (selector !== undefined) o.selector = selector; return o;
}
// Build the op to set or clear a status tag on a block span. A tag is an
// annotation whose kind is in TAG_KINDS (unverified/superseded/…). Set is
// idempotent on (kind, block, path, anchor): a second set of the same tag on the
// same span is a no-op; clear is a no-op if that tag isn't set there. Returns
// null when there's nothing to append. Unlike threads, tags are not replyable
// and have no resolve lifecycle — you set them and clear (detach) them.
export function tagSetOp(doc, block, kind, { selector, body = null, by = "agent", path = DEFAULT_PATH } = {}) {
  const exact = selector?.exact || null;
  const existing = (doc.attachments || []).find((a) => a.block === block && a.kind === kind && a.state === "active" && a.path === path && (a.selector?.exact || null) === exact);
  if (existing) return null;
  return attachOp(kind, block, { body, selector, by, path });
}
export function tagClearOp(doc, block, kind, { selector, path = DEFAULT_PATH } = {}) {
  const exact = selector?.exact || null;
  const existing = (doc.attachments || []).find((a) => a.block === block && a.kind === kind && a.state === "active" && a.path === path && (a.selector?.exact || null) === exact);
  return existing ? detachOp(existing.id) : null;
}
export function changeIdFor(title) { return slugify(title) || null; }

// Strip inline markdown syntax (code spans, emphasis, links) the way the
// viewer's markdown renderer collapses it to text — outside fenced code
// blocks, which render verbatim (only the fence markers themselves drop).
// Selectors are matched against that rendered textContent, so slicing
// prefix/suffix straight from the raw block source leaves stray backticks
// etc. in the selector and it can never re-match in the DOM.
function stripInlineMd(s) {
  return s
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/(\*\*|__)([^*_]+?)\1/g, "$2")
    .replace(/(\*|_)([^*_]+?)\1/g, "$2")
    .replace(/~~([^~]+?)~~/g, "$1");
}
function mdToPlainText(md) {
  const src = String(md);
  const fence = /^```[^\n]*\n([\s\S]*?)\n```$/gm;
  let out = "", last = 0, m;
  while ((m = fence.exec(src))) {
    out += stripInlineMd(src.slice(last, m.index)) + m[1];
    last = m.index + m[0].length;
  }
  return out + stripInlineMd(src.slice(last));
}

export function selectorFor(md, exact) {
  const plain = mdToPlainText(md);
  const i = plain.indexOf(exact);
  if (i === -1) throw new Error(`quote not found in block: "${exact.slice(0, 40)}…"`);
  const prefix = i > 0 ? plain.slice(Math.max(0, i - 32), i) : "";
  const suffix = plain.slice(i + exact.length, i + exact.length + 32);
  return { exact, prefix, suffix };
}