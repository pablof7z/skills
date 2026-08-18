// lib/blockdoc.mjs — server-side block-document API helpers.
// Reuses the wb CLI's store/annotations modules so block-doc read/write logic
// is not duplicated. A session is a block-doc session when document.json
// exists; otherwise it uses the legacy deliverable.md path.

import fs from "node:fs";
import path from "node:path";
import { loadDoc, saveDoc } from "../../cli/store.mjs";
import { addComment, addReply, resolveComment } from "../../cli/annotations.mjs";

const DOC = "document.json";

export function isBlockDoc(dir) {
  return fs.existsSync(path.join(dir, DOC));
}

// Full document for the client: { version, docId, rev, blocks, comments, hash }.
export function getDocument(dir) {
  const doc = loadDoc(dir);
  if (!doc) return null;
  return {
    version: doc.version, docId: doc.docId, rev: doc.rev,
    blocks: doc.blocks || [], comments: doc.comments || [], hash: doc.hash,
    updatedAt: doc.updatedAt || null,
  };
}

export function getComments(dir) {
  const doc = loadDoc(dir);
  return { comments: doc ? doc.comments || [] : [] };
}

// Human adds a comment on a block (optionally with a selector for in-block span).
export function postComment(dir, { block, text, selector, creator }) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document.json");
  const c = addComment(doc, block, String(text ?? "").slice(0, 8000), {
    by: creator || "user", selector,
  });
  saveDoc(dir, doc);
  return c;
}

export function postReply(dir, commentId, text, creator) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document.json");
  const r = addReply(doc, commentId, String(text ?? "").slice(0, 8000), { by: creator || "user" });
  saveDoc(dir, doc);
  return r;
}

// resolved map for the client: { id: { at, by } } for resolved comments.
export function resolvedMap(dir) {
  const doc = loadDoc(dir);
  if (!doc) return {};
  const out = {};
  for (const c of doc.comments || []) if (c.resolved) out[c.id] = { at: c.at, by: "user" };
  return out;
}

export function resolve(dir, id, resolved, by) {
  const doc = loadDoc(dir);
  if (!doc) throw new Error("no document.json");
  resolveComment(doc, id, !!resolved);
  saveDoc(dir, doc);
  return resolvedMap(dir);
}