// doc.mjs — block document as an append-only change log in changes/<rev>.json.
//
// The current document is the fold over all change files (sorted by rev). Each
// change is one atomic file (link EXCL → no rev collision); past changes are
// never mutated.
//
// Attachments are the one primitive for anything anchored to a spot in the doc:
// comments (kind:"comment") and labels (kind:"needs-attention"|"decided"|…).
// They share an anchor (block, or block + selector span), an optional body, an
// author/at, a state (active|resolved|removed), and optional replies. The only
// difference between kinds is how the UI renders them. The fold projects
// attachments back to the legacy {doc.comments, block.flags} shape the viewer
// already consumes (comments carry a `motivation` field for amber-card kinds),
// so the viewer doesn't change. New change files use the unified `attach` op;
// older files' comment/attention/flag/reply/resolve ops are still honored.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { versionHash, validName, slugify, agentName, provenance } from "./store.mjs";

export const CHANGES = "changes";
const PAD = 6;
const newId = () => "c-" + crypto.randomBytes(3).toString("hex");
const nowIso = () => new Date().toISOString();
const padded = (rev) => String(rev).padStart(PAD, "0");

export function changesDir(dir) { return path.join(dir, CHANGES); }
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

function insertIndex(blocks, before, after) {
  if (before) { const i = blocks.findIndex((b) => b.name === before); return i === -1 ? blocks.length : i; }
  if (after) { const i = blocks.findIndex((b) => b.name === after); return i === -1 ? blocks.length : i + 1; }
  return blocks.length;
}

function makeAtt(e, at) {
  return { id: e.id, kind: e.kind, block: e.block, selector: e.selector || null,
    body: e.body ?? null, motivation: e.motivation || null, by: e.by || "agent",
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
          blocks.splice(0, blocks.length, ...(e.blocks || []).map((b) => ({ name: b.name, md: b.md, ...(b.flags ? { flags: [...b.flags] } : {}) })));
          if (Array.isArray(e.attachments)) for (const a of e.attachments) att.set(a.id, { ...a, replies: [...(a.replies || [])] });
          else if (Array.isArray(e.comments)) { // legacy baseline: synthesize attachments
            for (const c of e.comments) att.set(c.id, { id: c.id, kind: c.motivation === "highlighting" ? "needs-attention" : "comment", block: c.block, selector: c.selector || null, body: c.body, motivation: c.motivation || null, by: c.author, at: c.at, state: c.resolved ? "resolved" : "active", replies: [...(c.replies || [])] });
            // label attachments from block.flags — but skip a kind already represented by
            // a comment attachment on that block (e.g. needs-attention already comes
            // from an attention comment; don't double-count it).
            const seen = new Set([...att.values()].map((a) => `${a.block}:${a.kind}`));
            for (const b of e.blocks || []) for (const f of (b.flags || [])) {
              if (seen.has(`${b.name}:${f}`)) continue;
              const id = `lbl-${f}-${b.name}`; if (!att.has(id)) att.set(id, { id, kind: f, block: b.name, selector: null, body: null, motivation: null, by: "agent", at: ch.at, state: "active", replies: [] });
            }
          }
          break;
        case "add": blocks.splice(insertIndex(blocks, e.before, e.after), 0, { name: e.name, md: e.md, ...(e.flags ? { flags: [...e.flags] } : {}) }); break;
        case "edit": { const b = blocks.find((x) => x.name === e.name); if (b) b.md = e.md; break; }
        case "move": { const i = blocks.findIndex((x) => x.name === e.name); if (i >= 0) { const [b] = blocks.splice(i, 1); blocks.splice(insertIndex(blocks, e.before, e.after), 0, b); } break; }
        case "rename": { const b = blocks.find((x) => x.name === e.from); if (b) b.name = e.to; for (const a of att.values()) if (a.block === e.from) a.block = e.to; break; }
        case "remove": { const names = new Set(e.names || [e.name]); for (let i = blocks.length - 1; i >= 0; i--) if (names.has(blocks[i].name)) blocks.splice(i, 1); break; }
        case "attach": { const id = e.id || newId(); att.set(id, makeAtt({ ...e, id }, at)); break; }
        case "reply": { const a = att.get(e.to ?? e.comment); if (a) a.replies.push({ id: e.id || newId(), author: e.by || "agent", body: e.body, at }); break; }
        case "resolve": { const a = att.get(e.id ?? e.comment); if (a) a.state = e.unresolved ? "active" : "resolved"; break; }
        case "detach": { const a = att.get(e.id); if (a) a.state = "removed"; break; }
        case "amend": { const a = att.get(e.id); if (a) { if (e.body !== undefined) a.body = e.body; if (e.selector !== undefined) a.selector = e.selector; } break; }
        // ---- legacy op names (older change files) ----
        case "comment": att.set(e.id, makeAtt({ ...e, kind: "comment" }, at)); break;
        case "attention": att.set(e.id, makeAtt({ ...e, kind: "needs-attention", motivation: e.motivation || "highlighting" }, at)); break;
        case "flag": { // legacy flag op → label attachment
          const id = `lbl-${e.flag}-${e.name}`;
          if (e.on === false) { const a = att.get(id); if (a) a.state = "removed"; }
          else if (!att.has(id)) att.set(id, { id, kind: e.flag, block: e.name, selector: null, body: null, motivation: null, by: "agent", at: ch.at, state: "active", replies: [] });
          break;
        }
      }
    }
  }
  // project attachments → legacy {comments, block.flags}
  const live = new Set(blocks.map((b) => b.name));
  const comments = [];
  const flagsByBlock = {};
  for (const a of att.values()) {
    if (!live.has(a.block) || a.state === "removed") continue;
    if (a.kind !== "comment") {
      if (a.state === "active") (flagsByBlock[a.block] ||= []).push(a.kind);
      // attention-style attachments (motivation=highlighting) also render as an
      // amber card; a plain label (e.g. `wb flag goal decided`) is badge-only.
      const mot = a.motivation || null;
      if (mot) comments.push({ id: a.id, block: a.block, author: a.by, body: a.body || "", at: a.at, resolved: a.state === "resolved", replies: a.replies, selector: a.selector, motivation: mot });
    } else {
      comments.push({ id: a.id, block: a.block, author: a.by, body: a.body || "", at: a.at, resolved: a.state === "resolved", replies: a.replies, selector: a.selector, motivation: a.motivation || null });
    }
  }
  for (const b of blocks) b.flags = flagsByBlock[b.name] || [];
  comments.sort((a, b) => (a.at || "").localeCompare(b.at || ""));
  const rev = changes.length ? changes[changes.length - 1].rev : 0;
  return { blocks, comments, attachments: [...att.values()], rev, hash: versionHash(blocks), updatedAt: changes.length ? changes[changes.length - 1].at : null };
}

// Referential validation against the current folded doc. Throws on the first
// bad op so a multi-op change aborts before anything is appended.
export function validateOps(doc, ops) {
  const blockNames = new Set(doc.blocks.map((b) => b.name));
  const attIds = new Set(doc.attachments.map((a) => a.id));
  for (const e of ops) {
    if (!e || typeof e !== "object") throw new Error("each op must be an object");
    switch (e.op) {
      case "add": validName(e.name); if (blockNames.has(e.name)) throw new Error(`block "${e.name}" already exists`); break;
      case "edit": case "move": case "flag": if (!blockNames.has(e.name)) throw new Error(`no block "${e.name}"`); break;
      case "rename": validName(e.to); if (!blockNames.has(e.from)) throw new Error(`no block "${e.from}"`); if (blockNames.has(e.to)) throw new Error(`block "${e.to}" already exists`); break;
      case "remove": for (const n of (e.names || [e.name])) if (!blockNames.has(n)) throw new Error(`no block "${n}"`); break;
      case "attach": case "comment": case "attention": if (!blockNames.has(e.block)) throw new Error(`no block "${e.block}"`); break;
      case "reply": if (!attIds.has(e.to ?? e.comment)) throw new Error(`no attachment "${e.to ?? e.comment}"`); break;
      case "resolve": case "detach": case "amend": { const k = e.id ?? e.comment; if (!attIds.has(k)) throw new Error(`no attachment "${k}"`); break; }
      case "baseline": break;
      default: throw new Error(`unknown op "${e.op}"`);
    }
  }
}

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
export function attachOp(kind, block, { body = null, selector = null, motivation = null, by = agentName(), id = newId() } = {}) {
  return { op: "attach", id, kind, block, by, body, selector, motivation, at: nowIso() };
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
// Build the op to set or clear a block flag (label attachment) against the
// current (preview) doc. Set is idempotent (no-op if already set); clear is a
// no-op if not set. Returns null when there's nothing to stage.
export function flagOp(doc, block, flag, { value = true, body = null, by = "agent" } = {}) {
  const existing = (doc.attachments || []).find((a) => a.block === block && a.kind === flag && a.state === "active");
  if (!value) return existing ? detachOp(existing.id) : null;
  if (existing) return null;
  return attachOp(flag, block, { body, by });
}
export function changeIdFor(title) { return slugify(title) || null; }

export function selectorFor(md, exact) {
  const i = String(md).indexOf(exact);
  if (i === -1) throw new Error(`quote not found in block: "${exact.slice(0, 40)}…"`);
  const prefix = i > 0 ? md.slice(Math.max(0, i - 32), i) : "";
  const suffix = md.slice(i + exact.length, i + exact.length + 32);
  return { exact, prefix, suffix };
}