// blockview.mjs — viewer for block-document sessions (document.json).
// Renders each block as a <section data-block-id> with its markdown, shows block
// flags as badges, and renders comments as margin notes anchored to the block
// (by block name, with an optional in-block selector span highlight). Reply +
// resolve via the API. Live via the page's shared SSE stream (see main.mjs).
// Legacy deliverable.md sessions use the separate viewer.mjs path; this
// module only runs for model === "blocks".

import { onRefresh, onStatus } from "./main.mjs";
import { initCodeBlocks } from "./codeblocks.mjs";
import { initTocRail } from "./toc-rail.mjs";
import { initBlockComposer } from "./blockcomposer.mjs";
import { initDiffMode, ago } from "./blockdiff.mjs";
import { initChat } from "./chat.mjs";
import { quoteMatch } from "./comments.mjs";
import { styleOf } from "./annotations.mjs";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

const DEFAULT_PATH = "default.md";
const blockKey = (b) => `${b.path || DEFAULT_PATH}\u0000${b.name}`;

const SANITIZE_OPTS = {
  USE_PROFILES: { html: true },
  ADD_ATTR: ["data-footnote-ref", "data-footnote-backref", "data-footnotes", "aria-describedby", "aria-label"],
};

// Colored chip for a kind, used in thread cards and tag chips.
function kindBadge(kind) { const s = styleOf(kind); return `<span class="kind-badge ${s.cls}" title="${esc(s.label)}">${s.icon}</span>`; }

function renderMarkdown(md) {
  const raw = window.marked ? window.marked.parse(md || "") : esc(md || "");
  return window.DOMPurify ? window.DOMPurify.sanitize(raw, SANITIZE_OPTS) : raw;
}
function renderBody(text) { return renderMarkdown(text); }

// Wrap the first occurrence of selector.exact (whitespace-flexibly, verified
// by prefix/suffix) in a <mark> within a block's rendered DOM. Returns true if
// highlighted. Reuses the quote matcher from comments.mjs so a quote that
// crosses a rendered block/line boundary (textContent has a newline where the
// stored exact has a space) still anchors, and the highlight span uses the real
// match end instead of exact.length (which can cut the mark short when the
// rendered text has more whitespace chars than the stored exact).
function highlightIn(blockMd, selector, id, kindCls) {
  if (!selector || !selector.exact) return false;
  const r = quoteMatch(blockMd.textContent, selector.exact, selector.prefix, selector.suffix);
  if (!r) return false;
  return wrapRange(blockMd, r.start, r.end, id, kindCls);
}

// Walk text nodes, split, and wrap [start,end) in a <mark class="wb-anno <kindCls>" data-anno-id=id>.
function wrapRange(root, start, end, id, kindCls) {
  const map = [];
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let n, cum = 0;
  while ((n = w.nextNode())) map.push({ node: n, start: cum, end: (cum += n.nodeValue.length) });
  const si = map.findIndex((m) => start >= m.start && start < m.end);
  const ei = map.findIndex((m) => end > m.start && end <= m.end);
  if (si === -1 || ei === -1) return false;
  const sn = map[si].node, relS = start - map[si].start;
  if (relS > 0) sn.splitText(relS);
  const startTail = relS > 0 ? sn.nextSibling : sn;
  const map2 = [];
  const w2 = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let nn, c = 0;
  while ((nn = w2.nextNode())) map2.push({ node: nn, start: c, end: (c += nn.nodeValue.length) });
  const ee = map2.find((m) => end > m.start && end <= m.end);
  if (!ee) return false;
  const relE = end - ee.start;
  if (relE > 0 && relE < ee.node.nodeValue.length) ee.node.splitText(relE);
  const wrapped2 = [];
  const w3 = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let tn, on = false;
  while ((tn = w3.nextNode())) {
    if (tn === startTail) on = true;
    if (on) { wrapped2.push(tn); if (tn === ee.node) break; }
  }
  for (const t of wrapped2) {
    if (!t.parentNode) continue;
    const mark = document.createElement("mark");
    mark.className = "wb-anno" + (kindCls ? " " + kindCls : "");
    if (id) mark.dataset.annoId = id;
    t.parentNode.insertBefore(mark, t);
    mark.appendChild(t);
  }
  return true;
}

export function initBlockViewer(rootEl, project, slug) {
  const API = `/api/session/${encodeURIComponent(project)}/${encodeURIComponent(slug)}`;
  rootEl.innerHTML = `
    <div class="app block-app">
      <main class="doc-col">
        <div class="topbar">
          <a class="back" href="/">← sessions</a>
          <span class="title" id="title">Whiteboard</span>
          <span class="status" id="status">exploring</span>
          <div class="view-tabs" id="view-tabs"><span class="view-tab active" data-view="document">Document</span><span class="view-tab" data-view="notes">Notes</span></div>
          <button class="diff-toggle" id="diff-toggle" type="button" title="Show changes">⇄</button>
          <button class="chat-toggle" id="chat-toggle" type="button" title="Chat with the agent">Chat</button>
          <button class="comments-toggle" id="comments-toggle" type="button" title="Comments" hidden><span class="ct-icon">💬</span><span class="ct-count" id="ct-count">0</span></button>
          <span class="conn" id="conn">live</span>
        </div>
        <div class="diff-bar" id="diff-bar" hidden><div id="diff-before" class="rev-picker"></div><span class="diff-arrow">→</span><div id="diff-after" class="rev-picker"></div><button class="diff-markread" id="diff-markread" type="button">Done</button></div>
        <div class="doc-scroll" id="doc-scroll">
          <div class="doc-wrap doc-wrap-block comments-on" id="doc-wrap">
            <article id="doc"></article>
            <div class="margin-rail" id="margin-rail" aria-label="Comments"></div>
          </div>
        </div>
        <div class="notes-view" id="notes-view" hidden></div>
      </main>
    </div>
    <nav class="toc-rail" id="toc-rail"><div class="toc-title">Contents</div><ol class="toc-list" id="toc-list"></ol></nav>
    <aside class="chat-side" id="chat-side" hidden><div class="chat-head"><span class="chat-head-title">Chat</span><button class="chat-close" id="chat-close" type="button" aria-label="Close chat">✕</button></div><div id="chat-mount"></div></aside>
    <aside class="comments-drawer" id="comments-drawer" hidden><div class="drawer-head"><span class="drawer-title">Comments</span><button class="drawer-close" id="drawer-close" type="button" aria-label="Close comments">✕</button></div><div class="drawer-scroll" id="drawer-scroll"></div></aside>`;

  const docEl = document.getElementById("doc");
  const railEl = document.getElementById("margin-rail");
  const tocList = document.getElementById("toc-list");
  const titleEl = document.getElementById("title");
  const statusEl = document.getElementById("status");
  const connEl = document.getElementById("conn");
  const docScrollEl = document.getElementById("doc-scroll");
  const notesViewEl = document.getElementById("notes-view");
  const viewTabsEl = document.getElementById("view-tabs");
  const tocRailEl = document.getElementById("toc-rail");
  initTocRail(tocRailEl);
  const diffBarEl = document.getElementById("diff-bar");
  const diffToggleEl = document.getElementById("diff-toggle");
  const diffBeforeEl = document.getElementById("diff-before");
  const diffAfterEl = document.getElementById("diff-after");
  const diffMarkReadEl = document.getElementById("diff-markread");
  const chatSideEl = document.getElementById("chat-side");
  const chatMountEl = document.getElementById("chat-mount");
  const chatToggleEl = document.getElementById("chat-toggle");
  const chatCloseEl = document.getElementById("chat-close");
  const commentsToggleEl = document.getElementById("comments-toggle");
  const ctCountEl = document.getElementById("ct-count");
  const commentsDrawerEl = document.getElementById("comments-drawer");
  const drawerCloseEl = document.getElementById("drawer-close");
  const drawerScrollEl = document.getElementById("drawer-scroll");
  const docWrapEl = document.getElementById("doc-wrap");
  // Off-screen indicators for agent annotations the user hasn't addressed.
  // Shown at the top/bottom edge of the doc viewport when such a card is
  // scrolled out of view; click to jump to the nearest one.
  const awaitAboveEl = Object.assign(document.createElement("div"), { className: "await-edge above", hidden: true });
  awaitAboveEl.innerHTML = `<span class="await-edge-flag">●</span><span class="await-edge-count">0</span><span class="await-edge-arrow">↑</span>`;
  const awaitBelowEl = Object.assign(document.createElement("div"), { className: "await-edge below", hidden: true });
  awaitBelowEl.innerHTML = `<span class="await-edge-flag">●</span><span class="await-edge-count">0</span><span class="await-edge-arrow">↓</span>`;
  docScrollEl.appendChild(awaitAboveEl);
  docScrollEl.appendChild(awaitBelowEl);
  const codeblocks = initCodeBlocks();
  const state = { doc: null, name: "", notes: "", view: "document", activePath: null, resolved: new Set(), activeId: null, showResolved: {}, collapsed: {}, anchored: {},
    diffMode: false, revisions: [], beforeRev: null, afterRev: "current", viewedRev: 0, diffBeforeDoc: null, diffAfterDoc: null, narrow: false };

  const composer = initBlockComposer({
    docEl,
    railEl,
    postComment: async (p) => {
      await fetch(`${API}/comments`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(p) });
      await runRefresh();
    },
  });

  const whoClass = (n) => (String(n || "").toLowerCase() === "agent" ? "agent" : "user");

  function annotationsOn(b) { return (state.doc?.annotations || []).filter((a) => a.block === b.name && (a.path || DEFAULT_PATH) === (b.path || DEFAULT_PATH)); }
  // Distinct file paths in first-appearance order; the blocks of the active
  // file only (what the main column renders); switch the active file (used by
  // the TOC file-tree headers in multi-file sessions).
  function distinctPaths() {
    const out = [], seen = new Set();
    for (const b of state.doc?.blocks || []) { const p = b.path || DEFAULT_PATH; if (!seen.has(p)) { seen.add(p); out.push(p); } }
    return out;
  }
  function visibleBlocks() { return (state.doc?.blocks || []).filter((b) => (b.path || DEFAULT_PATH) === state.activePath); }
  async function switchFile(p) {
    state.activePath = p;
    if (state.diffMode) {
      await diff.render();   // re-render the diff for the newly-active file
    } else {
      renderBlocks();
      await codeblocks.enhance(docEl);
      renderComments();
    }
    renderTOC();
    if (distinctPaths().length > 1) titleEl.textContent = `${state.name} · ${p}`;
    docScrollEl.scrollTop = 0;
  }

  // An annotation "awaits the user" when the agent has spoken (or flagged) and
  // the user hasn't replied or dismissed it — it still needs the human's eyes.
  // Tags are attention markers (needs-attention / unverified) the agent set and
  // the user hasn't cleared. Threads await when the agent has voice and no user
  // reply has followed. Resolved threads don't await anyone.
  function hasAgentVoice(a) { return a.author === "agent" || (Array.isArray(a.replies) && a.replies.some((r) => r.author === "agent")); }
  function hasUserReply(a) { return Array.isArray(a.replies) && a.replies.some((r) => r.author === "user"); }
  function awaitsUser(a) {
    if (a.isTag) return a.state === "active" && (a.kind === "needs-attention" || a.kind === "unverified");
    if (state.resolved.has(a.id)) return false;
    return hasAgentVoice(a) && !hasUserReply(a);
  }

  function renderBlocks() {
    docEl.innerHTML = "";
    state.anchored = {};
    for (const b of visibleBlocks()) {
      const sec = document.createElement("section");
      sec.className = "block";
      sec.dataset.blockId = b.name;
      sec.dataset.blockPath = b.path || DEFAULT_PATH;
      sec.dataset.blockIdx = String(docEl.children.length);
      sec.innerHTML = '<div class="block-md">' + renderMarkdown(b.md) + '</div>';
      docEl.appendChild(sec);
      // Highlight the anchor span of every open thread and active tag, colored
      // by kind. state.anchored[id] === true  -> highlighted (card omits the quote);
      // false -> anchor no longer matches (stale, shown in the card); undefined ->
      // resolved thread (not highlighted this pass, shown).
      for (const a of annotationsOn(b)) {
        if (!a.isTag && state.resolved.has(a.id)) continue; // resolved threads: no highlight
        if (a.isTag && a.state !== "active") continue; // cleared tags: no highlight
        state.anchored[a.id] = highlightIn(sec.querySelector(".block-md"), a.selector, a.id, styleOf(a.kind).cls);
      }
    }
  }

  // Render one comment as a margin card. The resolve button lives in the reply
  // row footer (pushed left by its margin-right:auto), NOT in the excerpt. The
  // excerpt shows the anchored selected text (if any) plus a relative time.
  // isResolved controls the toggle label; resolved cards are NOT faded (they
  // only differ by label).
  function buildCardEl(b, c, isResolved) {
    const card = document.createElement("div");
    card.className = "thread " + styleOf(c.kind).cls + (isResolved ? " is-resolved" : "") + (state.activeId === c.id ? " active" : "") + (state.collapsed[c.id] ? " collapsed" : "") + ((!isResolved && awaitsUser(c)) ? " awaits-user" : "");
    card.dataset.annoId = c.id;
    // Show the anchored text inside the card ONLY when it is NOT highlighted in the
    // document. When the anchor still matches, the highlight in the main text is the
    // indicator and the card omits the quote. A stale anchor (highlight attempted
    // but failed) gets a .stale marker + title; resolved comments show the quote
    // without the stale marker.
    const hasSel = !!(c.selector && c.selector.exact);
    const showQuote = hasSel && !state.anchored[c.id];
    const stale = hasSel && state.anchored[c.id] === false;
    const staleTitle = stale ? ` title="Unanchored: the saved context no longer matches this block"` : "";
    const quote = showQuote ? `<span class="excerpt-quote${stale ? " stale" : ""}"${staleTitle}>${stale ? "Unanchored: " : ""}“${esc(c.selector.exact)}”</span>` : "";
    let replies = "";
    for (const r of c.replies || []) {
      replies += `<div class="msg"><span class="who ${whoClass(r.author)}">${esc(r.author)}</span><span class="when" data-at="${esc(r.at)}">${ago(r.at)}</span><div class="body">${renderBody(r.body)}</div></div>`;
    }
    card.innerHTML = `<div class="excerpt"><button class="collapse-btn" type="button" title="${state.collapsed[c.id] ? "Expand" : "Collapse"}">${state.collapsed[c.id] ? "▸" : "▾"}</button>${kindBadge(c.kind)}${quote}<span class="where" data-at="${esc(c.at)}">${ago(c.at)}</span></div><div class="msg"><span class="who ${whoClass(c.author)}">${esc(c.author)}</span><div class="body">${renderBody(c.body)}</div></div>${replies}<div class="reply-box"><textarea placeholder="Reply…"></textarea><div class="row"><button class="resolve-btn" type="button" title="${isResolved ? "Unresolve" : "Resolve"}">${isResolved ? "↺ resolved" : "✓ resolve"}</button><button class="cancel">cancel</button><button class="send" disabled>Reply</button></div></div>`;
    const ta = card.querySelector("textarea");
    const send = card.querySelector(".send");
    ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });
    ta.addEventListener("keydown", (e) => { if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); send.click(); } });
    send.addEventListener("click", async () => {
      const text = ta.value.trim(); if (!text) return;
      send.disabled = true;
      await fetch(`${API}/comments`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ block: b.name, text, creator: "user", replyTo: c.id }) });
      await runRefresh();
    });
    card.querySelector(".cancel").addEventListener("click", () => { ta.value = ""; send.disabled = true; });
    card.querySelector(".resolve-btn").addEventListener("click", async (e) => {
      e.stopPropagation();
      await fetch(`${API}/resolved`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: c.id, resolved: !isResolved, by: "user" }) });
      await runRefresh();
    });
    card.querySelector(".collapse-btn").addEventListener("click", (e) => {
      e.stopPropagation();
      state.collapsed[c.id] = !state.collapsed[c.id];
      renderComments();
    });
    card.addEventListener("click", (e) => { if (e.target.closest(".reply-box")) return; state.activeId = c.id; (state.narrow ? drawerScrollEl : railEl).querySelectorAll(".thread").forEach((t) => t.classList.toggle("active", t === card)); });
    return card;
  }

  // Rail mode: dock the card in the margin rail at its anchor Y.
  function renderCard(b, c, anchorY, lastBottom, isResolved) {
    const card = buildCardEl(b, c, isResolved);
    railEl.appendChild(card);
    const top = Math.max(anchorY, lastBottom + 8);
    card.style.top = `${top}px`;
    return top + card.offsetHeight;
  }

  // A tag renders as a small colored chip in the margin rail at its anchor Y —
// colored by kind, non-replyable (tags are set/cleared by the agent, not
// resolved by the human). Shows the kind label + optional short body.
  function buildTagEl(b, a) {
    const s = styleOf(a.kind);
    const card = document.createElement("div");
    card.className = "wb-tag " + s.cls + (awaitsUser(a) ? " awaits-user" : "");
    card.dataset.annoId = a.id;
    card.title = esc(a.body ? `${s.label} — ${a.body}` : s.label);
    card.innerHTML = `<span class="tag-icon">${s.icon}</span><span class="tag-label">${esc(s.label)}</span>${a.body ? `<span class="tag-body">${esc(a.body)}</span>` : ""}`;
    return card;
  }

  // Rail mode: dock the tag chip in the margin rail at its anchor Y.
  function renderTag(b, a, anchorY, lastBottom) {
    const card = buildTagEl(b, a);
    railEl.appendChild(card);
    const top = Math.max(anchorY, lastBottom + 8);
    card.style.top = `${top}px`;
    return top + card.offsetHeight;
  }

  // A comment's card is Y-positioned to its own anchor <mark> when the quote
  // is still highlighted in the block (so the card sits next to the text it
  // refers to, not at the top of a possibly-long block); falls back to the
  // block's top when unanchored/resolved (no mark to measure from).
  function anchorYFor(sec, c) {
    if (state.anchored[c.id]) {
      const mark = sec.querySelector(`mark.wb-anno[data-anno-id="${cssEscape(c.id)}"]`);
      if (mark) return mark.offsetTop;
    }
    return sec.offsetTop;
  }

  function renderComments() {
    if (state.narrow) renderCommentsDrawer();
    else renderCommentsRail();
  }

  // Wide mode: margin-rail cards absolutely positioned by anchor Y.
  function renderCommentsRail() {
    railEl.innerHTML = "";
    drawerScrollEl.innerHTML = "";
    commentsToggleEl.hidden = true;
    let lastBottom = -8;
    let i = -1;
    for (const b of visibleBlocks()) {
      i++;
      const sec = docEl.querySelector(`section[data-block-idx="${i}"]`);
      if (!sec) continue;
      const blockTop = sec.offsetTop;
      const all = annotationsOn(b);
      const tags = all.filter((a) => a.isTag);          // active tags (cleared ones are folded out)
      const threads = all.filter((a) => !a.isTag);
      const open = threads.filter((a) => !state.resolved.has(a.id));
      const resolved = threads.filter((a) => state.resolved.has(a.id));
      for (const a of tags) lastBottom = renderTag(b, a, blockTop, lastBottom);
      for (const a of open) lastBottom = renderCard(b, a, anchorYFor(sec, a), lastBottom, false);
      if (resolved.length > 0) {
        const key = blockKey(b);
        const expanded = !!state.showResolved[key];
        const pill = document.createElement("div");
        pill.className = "resolved-pill" + (expanded ? " expanded" : "");
        pill.textContent = `${resolved.length} resolved ${expanded ? "▾" : "▸"}`;
        pill.title = expanded ? "Hide resolved" : "Show resolved";
        pill.addEventListener("click", () => { state.showResolved[key] = !expanded; renderComments(); });
        railEl.appendChild(pill);
        const top = Math.max(blockTop, lastBottom + 8);
        pill.style.top = `${top}px`;
        lastBottom = top + pill.offsetHeight;
        if (expanded) for (const a of resolved) lastBottom = renderCard(b, a, blockTop, lastBottom, true);
      }
    }
    updateAwaitingIndicators();
  }

  // Narrow mode: comments flow inside the right-side drawer; the doc gets full
  // width and a count indicator stands in for the margin rail. Threads are
  // grouped by block so context is preserved without the Y-anchoring.
  function renderCommentsDrawer() {
    railEl.innerHTML = "";
    drawerScrollEl.innerHTML = "";
    let count = 0;
    let any = false;
    let i = -1;
    for (const b of visibleBlocks()) {
      i++;
      const all = annotationsOn(b);
      if (!all.length) continue;
      const tags = all.filter((a) => a.isTag);
      const threads = all.filter((a) => !a.isTag);
      const open = threads.filter((a) => !state.resolved.has(a.id));
      const resolved = threads.filter((a) => state.resolved.has(a.id));
      if (!tags.length && !open.length && !resolved.length) continue;
      any = true;
      const head = document.createElement("div");
      head.className = "drawer-block-head";
      head.textContent = b.name;
      drawerScrollEl.appendChild(head);
      for (const a of tags) { drawerScrollEl.appendChild(buildTagEl(b, a)); }
      for (const a of open) { drawerScrollEl.appendChild(buildCardEl(b, a, false)); count++; }
      if (resolved.length) {
        const key = blockKey(b);
        const expanded = !!state.showResolved[key];
        const pill = document.createElement("div");
        pill.className = "resolved-pill" + (expanded ? " expanded" : "");
        pill.textContent = `${resolved.length} resolved ${expanded ? "▾" : "▸"}`;
        pill.title = expanded ? "Hide resolved" : "Show resolved";
        pill.addEventListener("click", () => { state.showResolved[key] = !expanded; renderComments(); });
        drawerScrollEl.appendChild(pill);
        if (expanded) for (const a of resolved) { drawerScrollEl.appendChild(buildCardEl(b, a, true)); count++; }
      }
    }
    if (!any) drawerScrollEl.innerHTML = '<div class="drawer-empty">No annotations.</div>';
    ctCountEl.textContent = String(count);
    commentsToggleEl.hidden = false;
    awaitAboveEl.hidden = true;
    awaitBelowEl.hidden = true; // narrow mode: drawer holds the threads; no doc-edge indicators
  }

  // Off-screen agent-annotation indicators: when a card the user still needs to
  // address is scrolled out of the viewport, surface a small count at the
  // top/bottom edge so it can't be missed. Click jumps to the nearest one.
  // The scroller is the window (#doc-scroll doesn't constrain its height, so the
  // body scrolls), so we measure against window.innerHeight and listen to window
  // scroll — not #doc-scroll.
  function updateAwaitingIndicators() {
    if (state.narrow || state.view !== "document") { awaitAboveEl.hidden = awaitBelowEl.hidden = true; return; }
    const vh = window.innerHeight;
    const above = [], below = [];
    for (const card of railEl.querySelectorAll(".awaits-user")) {
      const r = card.getBoundingClientRect();
      if (r.height === 0) continue;
      if (r.bottom <= 2) above.push({ card, y: r.top });
      else if (r.top >= vh - 2) below.push({ card, y: r.top });
    }
    if (above.length) { above.sort((a, b) => b.y - a.y); showAwaitEdge(awaitAboveEl, above.length, above[0].card); } else awaitAboveEl.hidden = true;
    if (below.length) { below.sort((a, b) => a.y - b.y); showAwaitEdge(awaitBelowEl, below.length, below[0].card); } else awaitBelowEl.hidden = true;
  }
  function showAwaitEdge(el, count, target) {
    el.hidden = false;
    el.querySelector(".await-edge-count").textContent = count;
    el._target = target;
    el.style.left = (window.innerWidth / 2) + "px";
    el.style.top = el.classList.contains("above") ? "8px" : (window.innerHeight - el.offsetHeight - 8) + "px";
  }
  awaitAboveEl.addEventListener("click", () => awaitAboveEl._target && awaitAboveEl._target.scrollIntoView({ behavior: "smooth", block: "center" }));
  awaitBelowEl.addEventListener("click", () => awaitBelowEl._target && awaitBelowEl._target.scrollIntoView({ behavior: "smooth", block: "center" }));
  docScrollEl.addEventListener("scroll", () => requestAnimationFrame(updateAwaitingIndicators));
  window.addEventListener("scroll", () => requestAnimationFrame(updateAwaitingIndicators), { passive: true });
  window.addEventListener("resize", () => requestAnimationFrame(updateAwaitingIndicators));

  // TOC lists the rendered headings (h1/h2/h3) inside each block — the actual
  // titles/subtitles — instead of the block name slugs. A block with no heading
  // falls back to its name so it stays navigable. Indentation reuses the
  // existing .toc-h2/.toc-h3 classes: any open thread or active tag on a block marks it.)
  function renderTOC() {
    tocList.innerHTML = "";
    const append = (text, level, att, el) => {
      const li = document.createElement("li");
      li.className = "toc-item toc-h" + Math.min(level, 4) + (att ? " has-attention" : "");
      li.innerHTML = `<span class="dot" aria-hidden="true"></span><span class="toc-text">${esc(text)}</span>`;
      li.addEventListener("click", () => el.scrollIntoView({ behavior: "smooth", block: "start" }));
      tocList.appendChild(li);
    };
    const paths = distinctPaths();
    const multi = paths.length > 1;
    const headsForIdx = (idx) => {
      const sec = docEl.querySelector(`section[data-block-idx="${idx}"]`);
      return sec ? [...sec.querySelectorAll("h1, h2, h3")] : [];
    };
    const hasAtt = (b) => annotationsOn(b).some((a) => a.isTag ? true : !state.resolved.has(a.id));
    // Single file: flat list of block headings (no file header).
    if (!multi) {
      visibleBlocks().forEach((b, idx) => {
        const heads = headsForIdx(idx);
        const sec = docEl.querySelector(`section[data-block-idx="${idx}"]`) || docEl;
        if (!heads.length) { append(b.name, 1, hasAtt(b), sec); return; }
        for (const h of heads) append(h.textContent, Number(h.tagName.slice(1)), hasAtt(b), h);
      });
      return;
    }
    // Multi-file: one switchable header per file. Only the active file's blocks
    // are listed (others collapse to their header). In diff mode each header
    // carries a dot when that file has changes in the before→after range, so
    // you can see that a non-selected file changed too. Clicking a header
    // switches the active file (re-rendering the diff for it in diff mode).
    const changedPaths = new Set();
    if (state.diffMode && state.diffBeforeDoc && state.diffAfterDoc) {
      const bmap = new Map();
      for (const b of state.diffBeforeDoc.blocks || []) bmap.set((b.path || DEFAULT_PATH) + "\u0000" + b.name, b.md || "");
      for (const b of state.diffAfterDoc.blocks || []) {
        const k = (b.path || DEFAULT_PATH) + "\u0000" + b.name;
        if (!bmap.has(k) || bmap.get(k) !== (b.md || "")) changedPaths.add(b.path || DEFAULT_PATH);
        bmap.delete(k);
      }
      for (const k of bmap.keys()) changedPaths.add(k.split("\u0000")[0]);
    }
    for (const p of paths) {
      const isActive = p === state.activePath;
      const fileLi = document.createElement("li");
      fileLi.className = "toc-item toc-file" + (isActive ? " active" : "") + (changedPaths.has(p) ? " has-changes" : "");
      fileLi.innerHTML = `<span class="dot" aria-hidden="true"></span><span class="toc-text">📄 ${esc(p)}</span>`;
      fileLi.addEventListener("click", () => { if (state.activePath !== p) switchFile(p); });
      tocList.appendChild(fileLi);
      if (!isActive) continue;
      visibleBlocks().forEach((b, idx) => {
        const heads = headsForIdx(idx);
        const sec = docEl.querySelector(`section[data-block-idx="${idx}"]`) || docEl;
        if (!heads.length) { append(b.name, 2, hasAtt(b), sec); return; }
        for (const h of heads) append(h.textContent, Number(h.tagName.slice(1)) + 1, hasAtt(b), h);
      });
    }
  }

  async function runRefresh({ auto = false } = {}) {
    const [s, d, n, rev] = await Promise.all([
      fetch(`${API}/session`).then((r) => r.json()),
      fetch(`${API}/document`).then((r) => r.json()),
      fetch(`${API}/notes`).then((r) => r.json()),
      fetch(`${API}/revisions`).then((r) => r.json()).catch(() => ({ revisions: [] })),
    ]);
    state.doc = d; state.notes = n.content || "";
    state.name = s.name || "Whiteboard";
    const paths = distinctPaths();
    if (!paths.includes(state.activePath)) state.activePath = paths[0] || DEFAULT_PATH;
    state.viewedRev = Number(s.viewedVersion) || 0;
    state.revisions = rev.revisions || [];
    state.resolved = new Set(Object.keys(s.resolved || {}));
    titleEl.textContent = paths.length > 1 ? `${state.name} · ${state.activePath}` : state.name;
    statusEl.textContent = s.status || "exploring";
    document.title = `${s.name || "Whiteboard"} — Whiteboard`;
    notesViewEl.innerHTML = n.content ? renderMarkdown(n.content) : "<p class=\"empty-notes\">No notes yet.</p>";
    renderBlocks();
    await codeblocks.enhance(docEl);
    renderComments();
    renderTOC();
    chat.refresh();
    if (state.diffMode) { await diff.render(); renderTOC(); return; }
    // There are block changes the user hasn't reviewed yet (viewedRev < current):
    // jump into the diff comparing last-viewed → current. Fires both on a live
    // (SSE) refresh and on a manual reload, so reopening the page after edits
    // lands on the diff rather than silently showing the new version.
    if (state.viewedRev < (d.rev ?? 0) && (d.rev ?? 0) > 1 &&
        state.revisions.some((r) => r.rev > state.viewedRev && r.rev <= (d.rev ?? 0) && r.blocks > 0)) {
      await diff.enter();
      setView("document");
    }
  }

  const diff = initDiffMode({
    API, state, docEl, codeblocks, renderMarkdown,
    diffBarEl, docWrapEl, diffBeforeEl, diffAfterEl, renderTOC,
    onExit: () => { renderBlocks(); renderComments(); renderTOC(); },
  });
  const chat = initChat(chatMountEl, API);

  function setView(v) {
    state.view = v;
    viewTabsEl.querySelectorAll(".view-tab").forEach((t) => t.classList.toggle("active", t.dataset.view === v));
    docScrollEl.hidden = (v !== "document");
    notesViewEl.hidden = (v !== "notes");
    tocRailEl.hidden = (v !== "document");
    diffBarEl.hidden = (v !== "document") || !state.diffMode;
    updateAwaitingIndicators();
  }
  viewTabsEl.addEventListener("click", (e) => { const tab = e.target.closest(".view-tab"); if (tab) setView(tab.dataset.view); });
  diffToggleEl.addEventListener("click", () => state.diffMode ? diff.exit() : diff.enter());
  diffBeforeEl.addEventListener("change", () => { state.beforeRev = diffBeforeEl.value === "current" ? "current" : Number(diffBeforeEl.value); diff.render(); });
  diffAfterEl.addEventListener("change", () => { state.afterRev = diffAfterEl.value === "current" ? "current" : Number(diffAfterEl.value); diff.render(); });
  diffMarkReadEl.addEventListener("click", diff.markRead);
  const openChat = () => { chatSideEl.hidden = false; chatToggleEl.classList.add("active"); chat.refresh().then(() => chat.focus && chat.focus()); };
  const closeChat = () => { chatSideEl.hidden = true; chatToggleEl.classList.remove("active"); };
  chatToggleEl.addEventListener("click", () => chatSideEl.hidden ? openChat() : closeChat());
  chatCloseEl.addEventListener("click", closeChat);

  // Narrow-viewport comments: hide the margin rail, show a count indicator in
  // the topbar, and reveal threads in a right-side drawer on click.
  const openComments = () => { commentsDrawerEl.hidden = false; commentsToggleEl.classList.add("active"); };
  const closeComments = () => { commentsDrawerEl.hidden = true; commentsToggleEl.classList.remove("active"); };
  commentsToggleEl.addEventListener("click", () => commentsDrawerEl.hidden ? openComments() : closeComments());
  drawerCloseEl.addEventListener("click", closeComments);
  const applyNarrow = (narrow) => {
    state.narrow = narrow;
    docWrapEl.classList.toggle("narrow-comments", narrow);
    if (!narrow) closeComments();
    renderComments();
  };
  const narrowMq = window.matchMedia("(max-width: 920px)");
  applyNarrow(narrowMq.matches);
  narrowMq.addEventListener("change", (e) => applyNarrow(e.matches));
  // Coalesce the noisy burst of refresh events (fs.watch fires several per write) into one re-render.
  let refreshTimer = null;
  const offRefresh = onRefresh(() => {
    if (refreshTimer) clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => { refreshTimer = null; runRefresh({ auto: true }).catch((e) => console.error("wb refresh", e)); }, 80);
  });
  const offStatus = onStatus((s) => {
    connEl.textContent = s === "live" ? "live" : "reconnecting…";
    connEl.classList.toggle("bad", s !== "live");
  });
  runRefresh().catch((e) => console.error("wb init", e));

  // Auto-refresh relative time labels every 30s without a full re-render (which would wipe in-progress replies).
  const timer = setInterval(() => { (state.narrow ? drawerScrollEl : railEl).querySelectorAll("[data-at]").forEach((el) => { el.textContent = ago(el.dataset.at); }); }, 30000);

  // Tear down our stream registrations + timers on re-route; main.mjs owns the shared EventSource.
  return { destroy() { offRefresh(); offStatus(); if (refreshTimer) clearTimeout(refreshTimer); clearInterval(timer); } };
}

function cssEscape(s) {
  return String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => `\\${c}`);
}
