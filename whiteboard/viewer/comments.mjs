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

function matchWithContext(hay, exact, prefix, suffix) {
  const p = prefix ? `(${wsPattern(prefix)})` : "";
  const e = `(${wsPattern(exact)})`;
  const s = suffix ? `(${wsPattern(suffix)})` : "";
  const m = new RegExp(p + e + s).exec(hay);
  if (!m) return null;
  const exactGroup = prefix ? 2 : 1;
  const start = m.index + (prefix ? m[1].length : 0);
  return { start, end: start + m[exactGroup].length };
}

// Return { start, end } offsets of `exact` in `hay` (whitespace-flexible,
// verified by prefix/suffix when present), or null. Nothing in the haystack or
// stored selector is mutated.
export function quoteMatch(hay, exact, prefix, suffix) {
  if (!exact) return null;
  if (!prefix && !suffix) return matchWithContext(hay, exact, "", "");
  const full = matchWithContext(hay, exact, prefix, suffix);
  if (full) return full;
  if (suffix) {
    const bySuffix = matchWithContext(hay, exact, "", suffix);
    if (bySuffix) return bySuffix;
  }
  if (prefix) {
    const byPrefix = matchWithContext(hay, exact, prefix, "");
    if (byPrefix) return byPrefix;
  }
  const matches = [];
  const re = new RegExp(`(${wsPattern(exact)})`, "g");
  let m;
  while ((m = re.exec(hay))) matches.push({ start: m.index, end: m.index + m[1].length });
  return matches.length === 1 ? matches[0] : null;
}

export function quoteIndex(hay, exact, prefix, suffix) {
  const r = quoteMatch(hay, exact, prefix, suffix);
  return r ? r.start : -1;
}

// Revision deletions are review metadata, not part of the canonical current
// text. Keep ordinary Markdown <del> content anchorable outside a diff.
const ANCHOR_IGNORE = "[data-wb-anchor-ignore], .wb-diff del, .wb-diff .wb-del, .wb-removed";

// Text used by quote selectors is document content, not controls injected by
// the viewer. Both selector creation and replay use this same projection.
export function anchorTextNodes(root) {
  const out = [];
  const nf = root.ownerDocument.defaultView?.NodeFilter?.SHOW_TEXT ?? 4;
  const walker = root.ownerDocument.createTreeWalker(root, nf, null);
  let node;
  while ((node = walker.nextNode())) {
    if (!node.parentElement?.closest(ANCHOR_IGNORE)) out.push(node);
  }
  return out;
}

export function anchorText(root) {
  return anchorTextNodes(root).map((node) => node.nodeValue).join("");
}

// Selectors saved before controls were excluded can still contain their text.
// Normalize those contexts with the same declared ignore set used by the DOM.
export function normalizeAnchorSelector(root, selector) {
  const ignored = [...root.querySelectorAll(ANCHOR_IGNORE)].map((node) => node.textContent).filter(Boolean);
  const clean = (value) => ignored.reduce((text, token) => text.split(token).join(""), String(value ?? ""));
  return { exact: clean(selector?.exact), prefix: clean(selector?.prefix), suffix: clean(selector?.suffix) };
}

export function anchorOffset(root, target, offset) {
  let total = 0;
  for (const node of anchorTextNodes(root)) {
    if (node === target) return total + offset;
    total += node.nodeValue.length;
  }
  return -1;
}

function rectOf(value) {
  return typeof value?.getBoundingClientRect === "function" ? value.getBoundingClientRect() : value;
}

export function relativeTop(anchor, container) {
  return rectOf(anchor).top - rectOf(container).top;
}
