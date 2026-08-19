// Shared quote-matching helpers for anchoring comments to block text. Used by
// the block viewer (blockview.mjs) and the anchoring tests. Whitespace-flexible
// so a stored selector.exact (collapsed spaces, from a browser selection or raw
// markdown) still re-anchors against rendered textContent that preserves
// newlines and multi-space runs from block structure.

function wsPattern(s) {
  return String(s ?? "")
    .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    .replace(/\s+/g, "\\s+");
}

// Return { start, end } offsets of `exact` in `hay` (whitespace-flexible,
// verified by prefix/suffix when present), or null. Nothing in the haystack or
// stored selector is mutated.
export function quoteMatch(hay, exact, prefix, suffix) {
  if (!exact) return null;
  const e = wsPattern(exact);
  const s = suffix ? wsPattern(suffix) : "";
  let m;
  if (prefix) m = new RegExp("(" + wsPattern(prefix) + ")(" + e + ")" + s).exec(hay);
  else if (suffix) m = new RegExp("(" + e + ")(" + s + ")").exec(hay);
  else m = new RegExp("(" + e + ")").exec(hay);
  if (!m) return null;
  const pfx = prefix ? m[1].length : 0;
  const ex = prefix ? m[2] : m[1];
  return { start: m.index + pfx, end: m.index + pfx + ex.length };
}

export function quoteIndex(hay, exact, prefix, suffix) {
  const r = quoteMatch(hay, exact, prefix, suffix);
  return r ? r.start : -1;
}