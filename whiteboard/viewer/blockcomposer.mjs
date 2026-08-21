// blockcomposer.mjs — text-selection → comment composer for block-doc sessions.
// When the human selects text inside a block's rendered markdown, a "Comment"
// FAB appears; clicking it opens a composer. On send, the comment is anchored to
// the block (name from the section) with a {exact, prefix, suffix} selector
// computed against that block's text, then posted via the passed postComment.

import { COMPOSER_KINDS } from "./annotations.mjs";
import { anchorOffset, anchorText, relativeTop } from "./comments.mjs";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

// The .block-md element containing a node, or null if the selection is outside
// any block's rendered markdown (e.g. over the block-name label or TOC).
function blockMdOf(node) {
  let n = node;
  while (n && n.nodeType !== Node.ELEMENT_NODE) n = n.parentNode;
  return n ? n.closest(".block-md") : null;
}

function blockNameOf(blockMd) {
  const sec = blockMd ? blockMd.parentElement : null;
  return sec && sec.dataset ? sec.dataset.blockId : null;
}
function blockPathOf(blockMd) {
  const sec = blockMd ? blockMd.parentElement : null;
  return sec && sec.dataset ? (sec.dataset.blockPath || "default.md") : null;
}

function selectorsFor(blockMd, range) {
  const full = anchorText(blockMd);
  let start = anchorOffset(blockMd, range.startContainer, range.startOffset);
  let end = anchorOffset(blockMd, range.endContainer, range.endOffset);
  const selected = range.toString();
  if (start === -1 && selected) start = full.indexOf(selected);
  if (end === -1 && start >= 0) end = start + selected.length;
  const exact = start >= 0 && end >= start ? full.slice(start, end) : selected;
  const prefix = start > 0 ? full.slice(Math.max(0, start - 32), start) : "";
  const suffix = end >= 0 && end < full.length ? full.slice(end, end + 32) : "";
  return { exact, prefix, suffix };
}

export function initBlockComposer({ docEl, postComment, railEl }) {
  let fab = null;
  let composer = null;
  const removeFab = () => { if (fab) { fab.remove(); fab = null; } };
  const closeComposer = () => {
    if (composer) { composer.remove(); composer = null; }
    try { window.getSelection().removeAllRanges(); } catch {}
  };

  function positionFab() {
    removeFab();
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return;
    const range = sel.getRangeAt(0);
    const blockMd = blockMdOf(range.startContainer);
    if (!blockMd || !docEl.contains(blockMd)) return;
    const text = sel.toString().trim();
    if (text.length === 0 || text.length > 1500) return;
    const rect = range.getBoundingClientRect();
    fab = document.createElement("button");
    fab.className = "comment-fab";
    fab.textContent = "Comment";
    fab.style.left = `${rect.left + window.scrollX + rect.width / 2 - 40}px`;
    fab.style.top = `${rect.top + window.scrollY - 34}px`;
    document.body.appendChild(fab);
    fab.addEventListener("mousedown", (ev) => ev.preventDefault());
    fab.addEventListener("click", () => { openComposer(range, blockMd, rect); removeFab(); });
  }

  function openComposer(range, blockMd, selectionRect) {
    closeComposer();
    const block = blockNameOf(blockMd);
    const path = blockPathOf(blockMd);
    const selector = selectorsFor(blockMd, range);
    const anchorY = relativeTop(selectionRect, railEl);
    composer = document.createElement("div");
    composer.className = "composer";
    composer.style.position = "absolute";
    composer.style.top = `${anchorY}px`;
    composer.style.left = "0";
    composer.style.right = "6px";
    composer.style.width = "auto";
    const kindOpts = COMPOSER_KINDS.map((k) => `<option value="${k}">${k}</option>`).join("");
    composer.innerHTML = `<div class="composer-quote">“${esc(selector.exact || "")}”</div><textarea placeholder="Add a thread… (⌘↵ to send)"></textarea><div class="row"><select class="composer-kind" title="Kind">${kindOpts}</select><button class="cancel">Cancel</button><button class="send" disabled>Send</button></div>`;
    railEl.appendChild(composer);
    const ta = composer.querySelector("textarea");
    const send = composer.querySelector(".send");
    const cancel = composer.querySelector(".cancel");
    const kindSel = composer.querySelector(".composer-kind");
    ta.focus();
    ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });
    ta.addEventListener("keydown", (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); send.click(); } });
    cancel.addEventListener("click", closeComposer);
    send.addEventListener("click", async () => {
      const text = ta.value.trim();
      if (!text) return;
      send.disabled = true;
      await postComment({ block, text, selector, creator: "user", path, kind: kindSel.value });
      closeComposer();
    });
  }

  document.addEventListener("mouseup", () => setTimeout(positionFab, 0));
  document.addEventListener("keyup", (e) => { if (e.key === "Escape") { removeFab(); closeComposer(); } });

  return { destroy: () => { removeFab(); closeComposer(); } };
}
