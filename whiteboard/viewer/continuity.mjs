import { anchorOffset, anchorText, anchorTextNodes, quoteMatch } from "./comments.mjs";

export const DEFAULT_PATH = "default.md";
export const blockKey = (block) => `${block.path || DEFAULT_PATH}\u0000${block.name}`;
const UNIT_SELECTOR = "h1,h2,h3,h4,h5,h6,p,li,pre,table,hr";

function visualUnits(section) {
  return [...section.querySelectorAll(UNIT_SELECTOR)].filter((node) => {
    if (node.closest(".wb-del, .wb-removed, [data-wb-anchor-ignore]")) return false;
    const parentUnit = node.parentElement?.closest(UNIT_SELECTOR);
    return !parentUnit || !section.contains(parentUnit);
  });
}

const unitText = (node) => String(node?.textContent || "").replace(/\s+/gu, " ").trim();

export function buildBlockPlan(beforeDoc, afterDoc, activePath = DEFAULT_PATH) {
  const after = (afterDoc?.blocks || []).filter((block) => (block.path || DEFAULT_PATH) === activePath);
  if (!beforeDoc) return after.map((block) => ({ key: blockKey(block), kind: "same", block }));

  const before = (beforeDoc.blocks || []).filter((block) => (block.path || DEFAULT_PATH) === activePath);
  const oldByKey = new Map(before.map((block) => [blockKey(block), block]));
  const afterKeys = new Set(after.map(blockKey));
  const plan = after.map((block) => {
    const old = oldByKey.get(blockKey(block));
    if (!old) return { key: blockKey(block), kind: "added", block };
    return { key: blockKey(block), kind: old.md === block.md ? "same" : "changed", block, old };
  });

  for (let index = 0; index < before.length; index++) {
    const block = before[index];
    if (afterKeys.has(blockKey(block))) continue;
    let insertAt = plan.length;
    for (let next = index + 1; next < before.length; next++) {
      const nextKey = blockKey(before[next]);
      const found = plan.findIndex((entry) => entry.key === nextKey && entry.kind !== "removed");
      if (found >= 0) { insertAt = found; break; }
    }
    plan.splice(insertAt, 0, { key: blockKey(block), kind: "removed", block, old: block });
  }
  return plan;
}

export function captureViewport(scrollEl, docEl) {
  if (!scrollEl || !docEl) return null;
  const root = scrollEl.scrollHeight > scrollEl.clientHeight + 1
    ? scrollEl
    : scrollEl.ownerDocument.scrollingElement;
  const viewport = root === scrollEl
    ? scrollEl.getBoundingClientRect()
    : { top: 0, bottom: scrollEl.ownerDocument.defaultView.innerHeight };
  const sections = [...docEl.querySelectorAll(":scope > section[data-block-key]")];
  let visible = null, unit = null, unitIndex = -1;
  for (const section of sections) {
    const units = visualUnits(section);
    const index = units.findIndex((candidate) => candidate.getBoundingClientRect().bottom > viewport.top);
    if (index >= 0) { visible = section; unit = units[index]; unitIndex = index; break; }
  }
  if (!visible) visible = sections.find((section) => section.getBoundingClientRect().bottom > viewport.top);
  if (!visible) return null;
  const index = sections.indexOf(visible);
  return {
    key: visible.dataset.blockKey,
    offset: (unit || visible).getBoundingClientRect().top - viewport.top,
    unitIndex,
    unitText: unitText(unit),
    next: sections.slice(index + 1).map((section) => section.dataset.blockKey),
    previous: sections.slice(0, index).reverse().map((section) => section.dataset.blockKey),
  };
}

export function restoreViewport(scrollEl, docEl, anchor) {
  if (!anchor || !scrollEl || !docEl) return;
  const root = scrollEl.scrollHeight > scrollEl.clientHeight + 1
    ? scrollEl
    : scrollEl.ownerDocument.scrollingElement;
  const sections = [...docEl.querySelectorAll(":scope > section[data-block-key]")];
  const keys = [anchor.key, ...anchor.next, ...anchor.previous];
  const section = keys.map((key) => sections.find((item) => item.dataset.blockKey === key)).find(Boolean);
  if (!section) return;
  const units = visualUnits(section);
  const matching = units.map((node, index) => ({ node, index }))
    .filter(({ node }) => anchor.unitText && unitText(node) === anchor.unitText)
    .sort((a, b) => Math.abs(a.index - anchor.unitIndex) - Math.abs(b.index - anchor.unitIndex));
  const target = matching[0]?.node || units[Math.min(Math.max(0, anchor.unitIndex), Math.max(0, units.length - 1))] || section;
  const viewportTop = root === scrollEl ? scrollEl.getBoundingClientRect().top : 0;
  root.scrollTop += target.getBoundingClientRect().top - viewportTop - anchor.offset;
}

export function captureSelection(docEl) {
  const selection = globalThis.getSelection?.();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
  const range = selection.getRangeAt(0);
  const startEl = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
  const endEl = range.endContainer.nodeType === 1 ? range.endContainer : range.endContainer.parentElement;
  const startRoot = startEl?.closest?.(".block-md");
  const endRoot = endEl?.closest?.(".block-md");
  if (!startRoot || startRoot !== endRoot || !docEl.contains(startRoot)) return null;
  const section = startRoot.closest("section[data-block-key]");
  const start = anchorOffset(startRoot, range.startContainer, range.startOffset);
  const end = anchorOffset(startRoot, range.endContainer, range.endOffset);
  if (!section || start < 0 || end < start) return null;
  const text = anchorText(startRoot);
  return {
    key: section.dataset.blockKey,
    start,
    end,
    exact: text.slice(start, end),
    prefix: text.slice(Math.max(0, start - 32), start),
    suffix: text.slice(end, end + 32),
  };
}

function pointAt(root, offset) {
  const nodes = anchorTextNodes(root);
  let cursor = 0;
  for (const node of nodes) {
    const end = cursor + node.nodeValue.length;
    if (offset <= end) return { node, offset: Math.max(0, offset - cursor) };
    cursor = end;
  }
  const last = nodes.at(-1);
  return last ? { node: last, offset: last.nodeValue.length } : null;
}

export function restoreSelection(docEl, saved) {
  if (!saved || !docEl) return;
  const section = [...docEl.querySelectorAll(":scope > section[data-block-key]")]
    .find((item) => item.dataset.blockKey === saved.key);
  const root = section?.querySelector(".block-md");
  if (!root) return;
  const text = anchorText(root);
  const matched = quoteMatch(text, saved.exact, saved.prefix, saved.suffix);
  const start = matched?.start ?? Math.min(saved.start, text.length);
  const end = matched?.end ?? Math.min(saved.end, text.length);
  const a = pointAt(root, start), b = pointAt(root, end);
  if (!a || !b) return;
  const range = root.ownerDocument.createRange();
  range.setStart(a.node, a.offset); range.setEnd(b.node, b.offset);
  const selection = globalThis.getSelection?.();
  selection?.removeAllRanges(); selection?.addRange(range);
}
