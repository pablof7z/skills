// blocks.mjs — read projections of a folded block document.
// The document is produced by doc.mjs fold(); this module only renders it to
// the three read projections used by `wb read` and the viewer. Mutations are
// append-change ops, not in-memory edits (see doc.mjs / main.mjs).

// Tagged projection: <name>…</name> per block. Default for `wb read` so the
// agent sees block boundaries (and can address a block by name).
export function readTagged(doc) {
  return doc.blocks.map((b) => `<${b.name}>\n${b.md}\n</${b.name}>`).join("\n\n") + "\n";
}

// Plain concatenated markdown (no tags).
export function readMd(doc) {
  return doc.blocks.map((b) => b.md).join("\n\n") + "\n";
}

// Raw document tree (JSON).
export function readJson(doc) {
  return JSON.stringify(doc, null, 2) + "\n";
}