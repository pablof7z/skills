import { anchorText, anchorTextNodes, normalizeAnchorSelector, quoteMatch } from "./comments.mjs";

export function selectorSignature(selector, kindClass = "") {
  return JSON.stringify([selector?.exact || "", selector?.prefix || "", selector?.suffix || "", kindClass]);
}

export function highlightsMatchSelector(marks, signature) {
  return marks.length > 0 && marks.every((mark) => mark.dataset.selectorSignature === signature);
}

function wrapRange(root, nodesFor, start, end, id, kindClass, signature) {
  const map = [];
  let total = 0;
  for (const node of nodesFor(root)) map.push({ node, start: total, end: (total += node.nodeValue.length) });
  const first = map.find((part) => start >= part.start && start < part.end);
  const last = map.find((part) => end > part.start && end <= part.end);
  if (!first || !last) return false;
  const startOffset = start - first.start;
  if (startOffset > 0) first.node.splitText(startOffset);
  const startNode = startOffset > 0 ? first.node.nextSibling : first.node;
  const remapped = [];
  total = 0;
  for (const node of nodesFor(root)) remapped.push({ node, start: total, end: (total += node.nodeValue.length) });
  const final = remapped.find((part) => end > part.start && end <= part.end);
  if (!final) return false;
  const endOffset = end - final.start;
  if (endOffset > 0 && endOffset < final.node.nodeValue.length) final.node.splitText(endOffset);
  let wrapping = false;
  for (const node of nodesFor(root)) {
    if (node === startNode) wrapping = true;
    if (!wrapping) continue;
    const mark = document.createElement("mark");
    mark.className = `wb-anno${kindClass ? ` ${kindClass}` : ""}`;
    mark.dataset.annoId = id;
    mark.dataset.selectorSignature = signature;
    node.parentNode.insertBefore(mark, node);
    mark.appendChild(node);
    if (node === final.node) break;
  }
  return true;
}

export function highlightCurrent(root, selector, id, kindClass) {
  if (!selector?.exact) return false;
  const canonical = normalizeAnchorSelector(root, selector);
  const match = quoteMatch(anchorText(root), canonical.exact, canonical.prefix, canonical.suffix);
  return !!match && wrapRange(root, anchorTextNodes, match.start, match.end, id, kindClass,
    selectorSignature(selector, kindClass));
}

function visibleTextNodes(root) {
  const out = [];
  const showText = root.ownerDocument.defaultView?.NodeFilter?.SHOW_TEXT ?? 4;
  const walker = root.ownerDocument.createTreeWalker(root, showText, null);
  let node;
  while ((node = walker.nextNode())) {
    if (!node.parentElement?.closest("[data-wb-anchor-ignore]")) out.push(node);
  }
  return out;
}

// While changes are visible, a comment on removed text belongs beside that
// visible removal—not at the block top as an unanchored historical quote.
export function highlightDeletion(root, selector, id, kindClass) {
  if (!selector?.exact) return false;
  const candidates = [...root.querySelectorAll(".wb-del, del")]
    .filter((node) => !node.parentElement?.closest(".wb-del, del"));
  for (const candidate of candidates) {
    const text = visibleTextNodes(candidate).map((node) => node.nodeValue).join("");
    const match = quoteMatch(text, selector.exact, selector.prefix, selector.suffix);
    if (match && wrapRange(candidate, visibleTextNodes, match.start, match.end, id, kindClass,
      selectorSignature(selector, kindClass))) return true;
  }
  return false;
}

export function unwrapHighlight(mark) {
  const parent = mark.parentNode;
  while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
  mark.remove();
  parent.normalize();
}
