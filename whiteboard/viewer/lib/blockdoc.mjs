// lib/blockdoc.mjs — server-side block-document API for the viewer.
// Backs the changes/<rev>.json log (cli/doc.mjs): reads project the fold; writes
// append a change. A session is block-doc when it has a changes/ dir.

import path from "node:path";
import {
  loadDoc, readChanges, fold, appendChange, validateOps, isBlockDocDir,
  attachOp, replyOp, resolveOp,
} from "../../cli/doc.mjs";
import { requireAttachKind } from "../../cli/kinds.mjs";

export function isBlockDoc(dir) { return isBlockDocDir(dir); }

// Full document for the client: { version, docId, rev, blocks, annotations,
// attachments, hash }. `annotations` is the unified viewer-facing list (threads
// + tags, kind-discriminated); `attachments` is the raw list for provenance.
export function getDocument(dir) {
  const doc = loadDoc(dir);
  if (!doc) return null;
  return {
    version: 1, docId: "block-doc", rev: doc.rev,
    blocks: doc.blocks || [], annotations: doc.annotations || [],
    attachments: doc.attachments || [], hash: doc.hash,
    updatedAt: doc.updatedAt || null,
  };
}

// Revision list (newest-first): { rev, at, title, by, changes, blocks } per
// change file. `changes` = total ops; `blocks` = block-mutating ops (add/edit/
// move/rename/remove) so the viewer auto-enters the diff only when a change
// actually touched block content.
export function listRevisions(dir) {
  const BLOCK = new Set(["add", "edit", "move", "rename", "remove"]);
  return readChanges(dir)
    .map((c) => ({
      rev: c.rev, at: c.at, title: c.title, by: c.by, via: c.via || null,
      changes: (c.ops || []).length,
      blocks: (c.ops || []).filter((o) => BLOCK.has(o.op)).length,
    }))
    .sort((a, b) => b.rev - a.rev);
}

// The raw change record for a rev (for provenance/jump), or null.
export function changeAt(dir, rev) {
  return readChanges(dir).find((c) => c.rev === Number(rev)) || null;
}

// Document state at a given rev: fold the change log up to rev N. Same shape
// as getDocument, or null when no change files reach that rev.
export function getDocumentAt(dir, rev) {
  const changes = readChanges(dir).filter((c) => c.rev <= rev);
  if (!changes.length) return null;
  const doc2 = fold(changes);
  return {
    version: 1, docId: "block-doc", rev: doc2.rev,
    blocks: doc2.blocks || [], annotations: doc2.annotations || [],
    attachments: doc2.attachments || [], hash: doc2.hash,
    updatedAt: doc2.updatedAt || null,
  };
}

export function getAnnotations(dir) {
  const doc = loadDoc(dir);
  return { annotations: doc ? doc.annotations || [] : [] };
}

function projectedAnnotation(op) {
  return { id: op.id, block: op.block, kind: op.kind, author: op.by, body: op.body, at: op.at, resolved: false, replies: [], ...(op.selector ? { selector: op.selector } : {}) };
}

// Human adds a thread on a block span (always anchored — the composer only fires
// on a text selection). `kind` is one of the attach kinds (default question).
export function postAttach(dir, { block, text, selector, creator, path, kind }) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document");
  if (!selector || !selector.exact) throw new Error("anchor required (--on)");
  requireAttachKind(kind || "question");
  const op = attachOp(kind || "question", block, { body: String(text ?? "").slice(0, 8000), by: creator || "user", selector, path });
  validateOps(doc, [op]);
  appendChange(dir, { title: `${kind || "question"} on ${block}`, by: creator || "user", ops: [op] });
  return projectedAnnotation(op);
}

export function postReply(dir, annotationId, text, creator) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document");
  const op = replyOp(annotationId, String(text ?? "").slice(0, 8000), { by: creator || "user" });
  validateOps(doc, [op]);
  appendChange(dir, { title: `reply to ${annotationId}`, by: creator || "user", ops: [op] });
  return { id: op.id, author: op.by, body: op.body, at: op.at };
}

// resolved map for the client: { id: { at, by } } for resolved threads.
export function resolvedMap(dir) {
  const doc = loadDoc(dir);
  if (!doc) return {};
  const out = {};
  for (const a of doc.annotations || []) if (!a.isTag && a.resolved) out[a.id] = { at: a.at, by: a.author };
  return out;
}

export function resolve(dir, id, resolved, by) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document");
  const op = resolveOp(id, !!resolved);
  validateOps(doc, [op]);
  appendChange(dir, { title: `${resolved ? "resolve" : "unresolve"} ${id}`, by: by || "user", ops: [op] });
  return resolvedMap(dir);
}