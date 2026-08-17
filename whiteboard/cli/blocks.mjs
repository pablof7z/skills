// blocks.mjs — block mutations and read projections for a wb document.
// Blocks are { name, md, flags? }; array order is document order. Mutations take
// the content as a string (the CLI handles --text/--file/stdin). Placement uses
// --before <name> / --after <name>; default is append to the end.

import { findBlock, requireBlock, uniqueName, validName } from "./store.mjs";

// ---- read projections ----

export function readTagged(doc) {
  return doc.blocks.map((b) => `<${b.name}>\n${b.md}\n</${b.name}>`).join("\n\n") + "\n";
}

export function readMd(doc) {
  return doc.blocks.map((b) => b.md).join("\n\n") + "\n";
}

export function readJson(doc) {
  return JSON.stringify(doc, null, 2) + "\n";
}

// ---- placement helper ----
function insertIndex(doc, { before, after }) {
  if (before) {
    const i = doc.blocks.findIndex((b) => b.name === before);
    if (i === -1) throw new Error(`--before: no block "${before}"`);
    return i;
  }
  if (after) {
    const i = doc.blocks.findIndex((b) => b.name === after);
    if (i === -1) throw new Error(`--after: no block "${after}"`);
    return i + 1;
  }
  return doc.blocks.length;
}

// ---- mutations ----

export function writeAdd(doc, name, md, place = {}) {
  uniqueName(doc, name);
  const block = { name, md: String(md) };
  doc.blocks.splice(insertIndex(doc, place), 0, block);
  return block;
}

export function writeEdit(doc, name, md) {
  const b = requireBlock(doc, name);
  b.md = String(md);
  return b;
}

export function writeMove(doc, name, place = {}) {
  const i = doc.blocks.findIndex((b) => b.name === name);
  if (i === -1) throw new Error(`no block "${name}"`);
  const [block] = doc.blocks.splice(i, 1);
  doc.blocks.splice(insertIndex(doc, place), 0, block);
  return block;
}

export function writeRename(doc, oldName, newName) {
  if (oldName === newName) return requireBlock(doc, oldName);
  validName(newName);
  if (findBlock(doc, newName)) throw new Error(`block "${newName}" already exists`);
  const b = requireBlock(doc, oldName);
  b.name = newName;
  for (const c of doc.comments) if (c.block === oldName) c.block = newName;
  return b;
}

export function writeRemove(doc, names) {
  const removed = [];
  for (const name of names) {
    const i = doc.blocks.findIndex((b) => b.name === name);
    if (i === -1) throw new Error(`no block "${name}"`);
    removed.push(doc.blocks.splice(i, 1)[0]);
    doc.comments = doc.comments.filter((c) => c.block !== name);
  }
  return removed;
}

// ---- flags ----

export function setFlag(doc, name, flag, on = true) {
  const b = requireBlock(doc, name);
  b.flags = b.flags || [];
  const has = b.flags.includes(flag);
  if (on && !has) b.flags.push(flag);
  if (!on && has) b.flags = b.flags.filter((f) => f !== flag);
  if (b.flags.length === 0) delete b.flags;
  return b;
}