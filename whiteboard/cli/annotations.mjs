// annotations.mjs — comments, replies, attention markers, and resolution.
// Comments live inside document.json (single source, cascade-clean on block
// delete). Shape: { id, block, selector?, author, body, at, resolved, replies[] }.
// `id` is a short minted id (c-<6hex>); replies thread under their parent comment.

import crypto from "node:crypto";
import { requireBlock } from "./store.mjs";
import { setFlag } from "./blocks.mjs";

const newId = () => "c-" + crypto.randomBytes(3).toString("hex");
const now = () => new Date().toISOString().replace(/\.\d+Z$/, ".000Z");

// Build a {exact, prefix, suffix} repair-hint selector from a block's markdown
// and an exact quote, the way the viewer does (±32 chars of context).
export function selectorFor(md, exact) {
  const i = String(md).indexOf(exact);
  if (i === -1) throw new Error(`quote not found in block: "${exact.slice(0, 40)}…"`);
  const prefix = i > 0 ? md.slice(Math.max(0, i - 32), i) : "";
  const suffix = md.slice(i + exact.length, i + exact.length + 32);
  return { exact, prefix, suffix };
}

export function addComment(doc, name, body, { by = "agent", exact, selector } = {}) {
  requireBlock(doc, name);
  if (exact) selector = selectorFor(requireBlock(doc, name).md, exact);
  const c = { id: newId(), block: name, author: by, body, at: now(), resolved: false, replies: [] };
  if (selector) c.selector = selector;
  doc.comments.push(c);
  return c;
}

export function addReply(doc, commentId, body, { by = "agent" } = {}) {
  const parent = doc.comments.find((c) => c.id === commentId);
  if (!parent) throw new Error(`no comment "${commentId}"`);
  const r = { id: newId(), author: by, body, at: now() };
  parent.replies = parent.replies || [];
  parent.replies.push(r);
  return r;
}

export function resolveComment(doc, commentId, resolved = true) {
  const c = doc.comments.find((x) => x.id === commentId);
  if (!c) throw new Error(`no comment "${commentId}"`);
  c.resolved = resolved;
  return c;
}

// attention = flag the block needs-attention + drop a comment carrying the reason.
export function markAttention(doc, name, reason, { by = "agent" } = {}) {
  setFlag(doc, name, "needs-attention", true);
  return addComment(doc, name, reason || "Needs your attention.", { by });
}

export function findCommentsOn(doc, name) {
  return doc.comments.filter((c) => c.block === name);
}