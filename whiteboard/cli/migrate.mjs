// migrate.mjs — turn a plain markdown string into wb blocks.
// Default strategy: each H1/H2 heading starts a new block named by the heading
// slug, carrying the heading + its body. Content before the first heading
// becomes a block named "intro". H3–H6 stay inside their parent block (they are
// subheadings, not block boundaries). Lines inside fenced code blocks (``` or
// ~~~) are never treated as headings, so `#` comment lines in bash/rust/python
// don't split. Duplicate slugs get -2, -3 suffixes.
// This is one-time; the agent can split further with `wb change add`.

import { slugify } from "./store.mjs";

export function parseMarkdownToBlocks(md) {
  const lines = String(md).replace(/\r\n/g, "\n").split("\n");
  const blocks = [];
  let cur = null;
  let inFence = false, fenceCh = "";
  const used = new Set();
  const unique = (base) => {
    let n = base, i = 2;
    while (used.has(n)) n = `${base}-${i++}`;
    used.add(n);
    return n;
  };
  for (const line of lines) {
    // track fenced code blocks (``` or ~~~) — never split inside them
    const fence = /^(\s*)(`{3,}|~{3,})/.exec(line);
    if (fence) {
      if (!inFence) { inFence = true; fenceCh = fence[2][0]; }
      else if (fence[2][0] === fenceCh) inFence = false;
    }
    // only H1/H2 start a new block, and only outside a code fence
    const m = !inFence && /^(#{1,2})\s+(.*)$/.exec(line);
    if (m) {
      cur = { name: unique(slugify(m[2]) || "section"), md: "" };
      blocks.push(cur);
      cur.md += line + "\n";
    } else {
      const target = cur || (blocks[blocks.length - 1] = { name: unique("intro"), md: "" });
      target.md += line + (line === "" ? "" : "\n");
    }
  }
  // trim trailing blank lines per block; drop fully-empty blocks
  return blocks
    .map((b) => ({ ...b, md: b.md.replace(/\n+$/, "\n") }))
    .filter((b) => b.md.trim().length > 0);
}

// Ingest the tagged <name>…</name> projection back into blocks (round-trip).
export function parseTaggedToBlocks(text) {
  const blocks = [];
  const re = /^<([a-z0-9][a-z0-9-]*)>\n([\s\S]*?)\n<\/\1>\s*$/gm;
  let m, idx = 0;
  while ((m = re.exec(text))) {
    blocks.push({ name: m[1], md: m[2] + "\n" });
    idx = re.lastIndex;
  }
  if (idx < text.trim().length && blocks.length === 0) {
    // not tagged — treat as a single markdown doc
    return parseMarkdownToBlocks(text);
  }
  return blocks;
}