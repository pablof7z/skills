// blockcomposer.mjs — text-selection → comment composer for block-doc sessions.
// When the human selects text inside a block's rendered markdown, a "Comment"
// FAB appears; clicking it opens a composer. On send, the comment is anchored to
// the block (name from the section) with a {exact, prefix, suffix} selector
// computed against that block's text, then posted via the passed postComment.

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

function cumulativeOffsets(root) {
  const out = [];
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let n, cum = 0;
  while ((n = w.nextNode())) { out.push({ node: n, start: cum, end: (cum += n.nodeValue.length) }); }
  return out;
}

function offsetIn(root, node, off) {
  for (const { node: t, start } of cumulativeOffsets(root)) if (t === node) return start + off;
  return -1;
}

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

function selectorsFor(blockMd, range, sel) {
  const full = blockMd.textContent;
  let start = offsetIn(blockMd, range.startContainer, range.startOffset);
  let end = offsetIn(blockMd, range.endContainer, range.endOffset);
  const exact = range.toString();
  if (start === -1 && exact) start = full.indexOf(exact);
  if (end === -1 && start >= 0) end = start + exact.length;
  const prefix = start > 0 ? full.slice(Math.max(0, start - 32), start) : "";
  const suffix = end >= 0 && end < full.length ? full.slice(end, end + 32) : "";
  return { exact, prefix, suffix };
}

export function initBlockComposer({ docEl, postComment }) {
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
    fab.addEventListener("click", () => { openComposer(range, sel, blockMd); removeFab(); });
  }

  function openComposer(range, sel, blockMd) {
    closeComposer();
    const block = blockNameOf(blockMd);
    const selector = selectorsFor(blockMd, range, sel);
    const rect = range.getBoundingClientRect();
    composer = document.createElement("div");
    composer.className = "composer";
    composer.style.left = `${rect.left + window.scrollX}px`;
    composer.style.top = `${rect.top + window.scrollY - 6}px`;
    composer.innerHTML = `<textarea placeholder="Comment on \`${esc(block || "")}\`…"></textarea><div class="row"><button class="cancel">Cancel</button><button class="send" disabled>Comment</button></div>`;
    document.body.appendChild(composer);
    const ta = composer.querySelector("textarea");
    const send = composer.querySelector(".send");
    const cancel = composer.querySelector(".cancel");
    ta.focus();
    ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });
    cancel.addEventListener("click", closeComposer);
    send.addEventListener("click", async () => {
      const text = ta.value.trim();
      if (!text) return;
      send.disabled = true;
      await postComment({ block, text, selector, creator: "user" });
      closeComposer();
    });
  }

  document.addEventListener("mouseup", () => setTimeout(positionFab, 0));
  document.addEventListener("keyup", (e) => { if (e.key === "Escape") { removeFab(); closeComposer(); } });

  return { destroy: () => { removeFab(); closeComposer(); } };
}