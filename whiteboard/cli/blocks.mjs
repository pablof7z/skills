// blocks.mjs — read projections of a folded block document.
// The document is produced by doc.mjs fold(); this module only renders it to the
// read projections used by `wb read`, the viewer, and the wb_read tool. Block
// identity is (path, name); reads take an optional `path` to scope to one file.
// Mutations are append-change ops, not in-memory edits (see doc.mjs / main.mjs).

import { DEFAULT_PATH } from "./doc.mjs";
import { isTagKind } from "./kinds.mjs";

const norm = (p) => p || DEFAULT_PATH;
const blocksOf = (doc, path) => path ? (doc.blocks || []).filter((b) => norm(b.path) === path) : (doc.blocks || []);
// Distinct paths in first-appearance order (so the tree/file list is stable).
const distinctPaths = (doc) => {
  const seen = new Set(), out = [];
  for (const b of doc.blocks || []) { const p = norm(b.path); if (!seen.has(p)) { seen.add(p); out.push(p); } }
  return out;
};

// Tagged projection: <name>…</name> per block. Default for `wb read` so the
// agent sees block boundaries (and can address a block by name).
export function readTagged(doc, path) {
  return blocksOf(doc, path).map((b) => `<${b.name}>\n${b.md}\n</${b.name}>`).join("\n\n") + "\n";
}

// Plain concatenated markdown (no tags). The pure file body — the contract used
// by the CLI (`wb read --md`) and the markdown seed import (`wb new --from`).
// Keep this free of any action-section so parseMarkdownToBlocks stays clean.
export function readMd(doc, path) {
  return blocksOf(doc, path).map((b) => b.md).join("\n\n") + "\n";
}

const firstLine = (s) => String(s || "").split(/\n/)[0].replace(/\s+/g, " ").trim().slice(0, 120);

// Agent-facing markdown: the file body PLUS an action-section with what the prose
// alone misses — open (unresolved) threads, active tags on blocks, and meta. Used
// by the wb_read tool (format: md); the CLI --md path stays the pure readMd above.
// With no `path` and multiple files, emits a `## 📄 <path>` header per file (the
// tree view); with `path`, scopes to that one file.
export function readMdAgent(doc, path) {
  const paths = path ? [path] : distinctPaths(doc);
  let out;
  if (paths.length <= 1) {
    out = readMd(doc, path); // single file: pure body, no header (backward compat)
  } else {
    out = "";
    for (const p of paths) out += `## 📄 ${p}\n\n${readMd(doc, p)}\n`;
  }
  const scope = (arr) => path ? (arr || []).filter((x) => norm(x.path) === path) : (arr || []);
  const anns = scope(doc.annotations || []);
  const open = anns.filter((a) => !a.isTag && !a.resolved);
  const tagged = anns.filter((a) => a.isTag && a.state === "active");
  if (!open.length && !tagged.length && !doc.rev) return out;
  out += "\n---\n";
  if (open.length) {
    out += "\n## Open threads\n";
    for (const a of open) {
      const where = path ? "" : `${norm(a.path)} · `;
      const anchor = a.selector?.exact ? ` “${firstLine(a.selector.exact)}”` : "";
      out += `- ${a.kind} ${a.id} · ${where}${a.block}${anchor} · ${a.author}: "${firstLine(a.body)}"\n`;
      for (const r of a.replies || []) out += `  ↳ ${r.author}: "${firstLine(r.body)}"\n`;
    }
  }
  if (tagged.length) {
    out += "\n## Tags\n";
    for (const a of tagged) {
      const where = path ? "" : `${norm(a.path)}: `;
      const anchor = a.selector?.exact ? ` “${firstLine(a.selector.exact)}”` : "";
      out += `- ${where}${a.block}${anchor}: ${a.kind}${a.body ? ` — ${firstLine(a.body)}` : ""}\n`;
    }
  }
  out += "\n## Meta\n";
  out += `- rev ${doc.rev} · ${doc.updatedAt ? `updatedAt ${doc.updatedAt}` : "no changes"}\n`;
  return out;
}

// Raw document tree (JSON). Blocks/comments carry `path`; no filtering here.
export function readJson(doc) {
  return JSON.stringify(doc, null, 2) + "\n";
}