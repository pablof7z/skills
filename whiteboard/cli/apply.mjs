// apply.mjs — apply an array of block ops as a single ALL-OR-NOTHING change,
// with no staging transaction. Shared by the Pi extension (`wb_apply` tool)
// and the `wb apply` CLI subcommand so their op-build / validate / append logic
// stays in one place.
//
// Every op is built (edit diffs resolve against the WIP doc so a later edit can
// patch a block an earlier op in the same array added/edited), then validated in
// WIP order against the live doc via validateOpsInOrder. If ANY op is invalid
// (bad block name, missing field, a diff that won't apply, an unknown op) this
// throws BEFORE any write, so nothing is appended. On success one change (one
// rev) is appended with all the ops. `by` is attributed at the change level
// (block ops don't carry their own author), like the staging transaction's send.

import { loadDoc, DEFAULT_PATH, appendChange, validateOpsInOrder, changeIdFor } from "./doc.mjs";
import { slugify, agentName, provenance } from "./store.mjs";
import { previewDoc, resolveEditDiff, formatOpDelta, stripOldMd } from "./staging.mjs";

export const APPLY_BLOCK_OPS = ["add", "edit", "move", "rename", "remove"];

function buildOp(session, built, input) {
  if (!input || typeof input !== "object") throw new Error("each op must be an object");
  const op = input.op;
  const p = input.path || DEFAULT_PATH;
  if (op === "add") {
    if (!input.name) throw new Error("add: `name` required");
    if (input.text === undefined) throw new Error("add: `text` required");
    return { op: "add", name: slugify(input.name), md: String(input.text), before: input.before, after: input.after, path: p };
  }
  if (op === "edit") {
    const name = input.block || input.name;
    if (!name) throw new Error("edit: `block` required");
    // Capture the block's md in the WIP doc BEFORE this op (the live block, or
    // an earlier op's result if this op targets a block added/edited earlier in
    // this same apply) — the delta is computed against this, not the live doc.
    const wip = previewDoc(session, built);
    const wipBlock = wip.blocks.find((b) => b.name === name && (b.path || DEFAULT_PATH) === p);
    const oldMd = wipBlock ? wipBlock.md : "";
    let md;
    if (input.text !== undefined) md = String(input.text);
    else if (input.diff !== undefined) md = resolveEditDiff(wip.blocks, name, p, String(input.diff));
    else throw new Error("edit: `text` or `diff` required");
    return { op: "edit", name, md, path: p, oldMd };
  }
  if (op === "move") {
    const name = input.block || input.name;
    if (!name) throw new Error("move: `block` required");
    if (!input.before && !input.after) throw new Error("move: `before` or `after` required");
    return { op: "move", name, before: input.before, after: input.after, path: p };
  }
  if (op === "rename") {
    const from = input.block || input.from;
    const to = input.name || input.to;
    if (!from || !to) throw new Error("rename: `block` (old) and `name` (new) required");
    return { op: "rename", from, to: slugify(to), path: p };
  }
  if (op === "remove") {
    const names = (Array.isArray(input.names) && input.names.length) ? input.names : [input.name || input.block];
    if (!names[0]) throw new Error("remove: `names` or `block` required");
    const wip = previewDoc(session, built);
    const oldMd = names.map((n) => { const b = wip.blocks.find((x) => x.name === n && (x.path || DEFAULT_PATH) === p); return b ? b.md : ""; }).join("\n\n");
    return { op: "remove", names, path: p, oldMd };
  }
  throw new Error(`unknown op "${op}" (one of ${APPLY_BLOCK_OPS.join("|")})`);
}

// Apply `ops` to `session` ({project,slug,dir}) as one atomic change. Returns
// { rev, id, title, ops, deltas } on success; throws on any failure (caller
// surfaces it). With `dryRun`, ops are built and validated but nothing is
// written — returns { dryRun: true, deltas } so a caller can preview drift
// before committing.
export function applyOps(session, { title, ops, summary = null, by, piSessionId = null, dryRun = false }) {
  if (!title) throw new Error("`title` is required");
  if (!Array.isArray(ops) || !ops.length) throw new Error("`ops` (non-empty array) is required");
  if (!loadDoc(session.dir)) throw new Error(`no document in ${session.dir}`);
  const built = [];
  for (const input of ops) built.push(buildOp(session, built, input));
  // All-or-nothing: validate every op against the live doc in WIP order BEFORE
  // any write. validateOpsInOrder throws on the first bad op → nothing appended.
  validateOpsInOrder(loadDoc(session.dir), built);
  const deltas = built.map(formatOpDelta);
  if (dryRun) return { dryRun: true, deltas };
  const via = piSessionId ? { ...provenance(), piSessionId } : undefined;
  const ch = appendChange(session.dir, { id: changeIdFor(title), title, by: by || agentName(), summary, ops: built.map(stripOldMd), via });
  return { rev: ch.rev, id: ch.id, title: ch.title, ops: ch.ops.length, deltas };
}
