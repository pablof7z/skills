// lib/blockdoc.mjs — server-side block-document API for the viewer.
// Backs the changes/<rev>.json log (cli/doc.mjs): reads project the fold; writes
// append a change. A session is block-doc when it has a changes/ dir (or a
// legacy document.json that auto-migrates on first load).

import path from "node:path";
import {
  loadDoc, appendChange, validateOps, isBlockDocDir,
  commentOp, replyOp, resolveOp,
} from "../../cli/doc.mjs";

export function isBlockDoc(dir) { return isBlockDocDir(dir); }

// Full document for the client: { version, docId, rev, blocks, comments, hash }.
export function getDocument(dir) {
  const doc = loadDoc(dir);
  if (!doc) return null;
  return {
    version: 1, docId: "deliverable", rev: doc.rev,
    blocks: doc.blocks || [], comments: doc.comments || [], hash: doc.hash,
    updatedAt: doc.updatedAt || null,
  };
}

export function getComments(dir) {
  const doc = loadDoc(dir);
  return { comments: doc ? doc.comments || [] : [] };
}

function projectedComment(op) {
  return { id: op.id, block: op.block, author: op.by, body: op.body, at: op.at, resolved: false, replies: [], ...(op.selector ? { selector: op.selector } : {}) };
}

// Human adds a comment on a block (optionally with a selector for in-block span).
export function postComment(dir, { block, text, selector, creator }) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document");
  const op = commentOp(block, String(text ?? "").slice(0, 8000), { by: creator || "user", selector });
  validateOps(doc, [op]);
  appendChange(dir, { title: `comment on ${block}`, by: creator || "user", ops: [op] });
  return projectedComment(op);
}

export function postReply(dir, commentId, text, creator) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document");
  const op = replyOp(commentId, String(text ?? "").slice(0, 8000), { by: creator || "user" });
  validateOps(doc, [op]);
  appendChange(dir, { title: `reply to ${commentId}`, by: creator || "user", ops: [op] });
  return { id: op.id, author: op.by, body: op.body, at: op.at };
}

// resolved map for the client: { id: { at, by } } for resolved comments.
export function resolvedMap(dir) {
  const doc = loadDoc(dir);
  if (!doc) return {};
  const out = {};
  for (const c of doc.comments || []) if (c.resolved) out[c.id] = { at: c.at, by: c.author };
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