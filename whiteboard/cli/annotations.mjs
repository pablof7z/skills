// annotations.mjs — the direct (non-staged) annotation surface: `wb attach`
// and `wb tag`. Annotations are meta-discussion about the document, not part
// of the artifact, so they bypass the `wb change` staging transaction: each
// action appends one op as its own change immediately (like `wb note`, like the
// viewer's comment API). `wb change` is reserved for artifact (block) edits.
//
// Every annotation is anchored to a text span — `--on` is mandatory. There are
// no block-level annotations; agents who mean a whole block must anchor to its
// heading. `--kind` drives intent and (viewer-side) color:
//   attach kinds (replyable threads): question | warning | objection | note
//   tag kinds (status markers, set/clear): unverified | superseded | needs-attention | decided

import fs from "node:fs";
import {
  loadDoc, readChanges, appendChange, validateOpsInOrder,
  attachOp, replyOp, resolveOp, tagSetOp, tagClearOp, selectorFor, DEFAULT_PATH,
} from "./doc.mjs";
import { requireAttachKind, requireTagKind, isAttachKind, isTagKind } from "./kinds.mjs";
import { agentName } from "./store.mjs";

const nowIso = () => new Date().toISOString();

function readContent(flags, { optional = false } = {}) {
  if (flags.content !== undefined) return String(flags.content);
  if (flags.text !== undefined) return String(flags.text); // alias for muscle memory
  if (flags.file) return fs.readFileSync(flags.file, "utf8");
  if (!process.stdin.isTTY) return fs.readFileSync(0, "utf8");
  if (optional) return null;
  throw new Error("no content: pass --content, --file, or pipe via stdin");
}

function appendOne(session, op, { title, by }) {
  const doc = loadDoc(session.dir);
  if (!doc) throw new Error(`no document in ${session.dir}`);
  validateOpsInOrder(doc, [op]); // throws if the op references a missing block/thread
  return appendChange(session.dir, { id: null, title, by: by || agentName(), ops: [op] });
}

function selectorForOn(doc, block, on, fpath) {
  if (!on) throw new Error("--on is required (anchor text within the block)");
  const b = (doc.blocks || []).find((x) => x.name === block && (x.path || DEFAULT_PATH) === fpath);
  if (!b) throw new Error(`no block "${block}" in ${fpath}`);
  return selectorFor(b.md, on);
}

function findAtt(doc, id) {
  const a = (doc.attachments || []).find((x) => x.id === id);
  if (!a) throw new Error(`no annotation "${id}"`);
  return a;
}

// ---- wb attach ----

export function attachCreate(session, { block, on, kind, content, by, path }) {
  const fpath = path || DEFAULT_PATH;
  if (!block) throw new Error("usage: wb attach <block> --on \"quote\" --kind <question|warning|objection|note> --content T [--by who] [--path P]");
  requireAttachKind(kind);
  if (!on) throw new Error("--on is required: anchor text within the block");
  if (!content) throw new Error("--content is required for an attach");
  const doc = loadDoc(session.dir);
  if (!doc) throw new Error(`no document in ${session.dir}`);
  const selector = selectorForOn(doc, block, on, fpath);
  const op = attachOp(kind, block, { body: String(content), selector, by: by || agentName(), path: fpath });
  const ch = appendOne(session, op, { title: `${kind} on ${block}`, by });
  return `${kind} ${op.id} on ${block} (${fpath}) — anchored to “${on.slice(0, 40)}${on.length > 40 ? "…" : ""}”. (rev ${ch.rev})`;
}

export function attachReply(session, id, { content, by }) {
  if (!id) throw new Error("usage: wb attach reply <id> --content T [--by who]");
  if (!content) throw new Error("--content is required");
  const doc = loadDoc(session.dir);
  findAtt(doc, id);
  const op = replyOp(id, String(content), { by: by || agentName() });
  const ch = appendOne(session, op, { title: `reply to ${id}`, by });
  return `reply ${op.id} on ${id}. (rev ${ch.rev})`;
}

export function attachResolve(session, id, { by } = {}) {
  if (!id) throw new Error("usage: wb attach resolve <id>");
  const doc = loadDoc(session.dir);
  findAtt(doc, id);
  const op = resolveOp(id, true);
  const ch = appendOne(session, op, { title: `resolve ${id}`, by });
  return `resolved ${id}. (rev ${ch.rev})`;
}

export function attachReopen(session, id, { by } = {}) {
  if (!id) throw new Error("usage: wb attach reopen <id>");
  const doc = loadDoc(session.dir);
  findAtt(doc, id);
  const op = resolveOp(id, false);
  const ch = appendOne(session, op, { title: `reopen ${id}`, by });
  return `reopened ${id}. (rev ${ch.rev})`;
}

// ---- wb tag ----

export function tagSet(session, { block, on, kind, content, by, path }) {
  const fpath = path || DEFAULT_PATH;
  if (!block) throw new Error("usage: wb tag <block> --on \"quote\" --kind <unverified|superseded|needs-attention|decided> [--content T] [--by who] [--path P]");
  requireTagKind(kind);
  if (!on) throw new Error("--on is required: anchor text within the block");
  const doc = loadDoc(session.dir);
  if (!doc) throw new Error(`no document in ${session.dir}`);
  const selector = selectorForOn(doc, block, on, fpath);
  const op = tagSetOp(doc, block, kind, { selector, body: content || null, by: by || agentName(), path: fpath });
  if (!op) return `${kind} already set on ${block} at “${on.slice(0, 40)}…” — nothing to do.`;
  const ch = appendOne(session, op, { title: `tag ${kind} on ${block}`, by });
  return `tag ${kind} on ${block} (${fpath}) — anchored to “${on.slice(0, 40)}${on.length > 40 ? "…" : ""}”. (rev ${ch.rev})`;
}

export function tagClear(session, { block, on, kind, by, path }) {
  const fpath = path || DEFAULT_PATH;
  if (!block || !kind || !on) throw new Error("usage: wb tag <block> --on \"quote\" --kind <tag-kind> --clear [--by who] [--path P]");
  requireTagKind(kind);
  const doc = loadDoc(session.dir);
  const selector = selectorForOn(doc, block, on, fpath);
  const op = tagClearOp(doc, block, kind, { selector, path: fpath });
  if (!op) return `${kind} not set on ${block} at “${on.slice(0, 40)}…” — nothing to clear.`;
  const ch = appendOne(session, op, { title: `clear ${kind} on ${block}`, by });
  return `cleared ${kind} on ${block}. (rev ${ch.rev})`;
}

// ---- list (shared) ----

export function listAnnotations(session, { block, path, tags, open } = {}) {
  const doc = loadDoc(session.dir);
  if (!doc) throw new Error(`no document in ${session.dir}`);
  const fpath = path || null;
  let items = (doc.annotations || []).filter((a) => !fpath || (a.path || DEFAULT_PATH) === fpath);
  if (block) items = items.filter((a) => a.block === block);
  if (tags === true) items = items.filter((a) => a.isTag);
  if (tags === false) items = items.filter((a) => !a.isTag);
  if (open) items = items.filter((a) => !a.resolved);
  if (!items.length) return "(none)";
  const lines = [];
  for (const a of items) {
    const where = fpath ? "" : `${a.path} · `;
    const anchor = a.selector?.exact ? `“${a.selector.exact.slice(0, 40)}${a.selector.exact.length > 40 ? "…" : ""}” ` : "";
    const state = a.isTag ? (a.state === "active" ? "" : " [removed]") : (a.resolved ? " [resolved]" : "");
    const body = a.body ? ` ${JSON.stringify(a.body.slice(0, 60))}` : "";
    lines.push(`${a.id}  ${where}${a.block} ${anchor}${a.kind}${state}${body}`);
  }
  return lines.join("\n");
}

export { isAttachKind, isTagKind };