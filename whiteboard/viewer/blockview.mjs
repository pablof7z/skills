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
import { initRevisionReview, reviewBaseline } from "./blockdiff.mjs";
import { initEdgeIndicator } from "./edge-indicators.mjs";
import { initChat } from "./chat.mjs";
import { styleOf } from "./annotations.mjs";
import { createAnnotationView } from "./annotationview.mjs";
import { createBlockReconciler } from "./liveblocks.mjs";
import { highlightCurrent, highlightDeletion, highlightsMatchSelector, selectorSignature, unwrapHighlight } from "./highlights.mjs";
import { blockKey, captureSelection, captureViewport, DEFAULT_PATH, restoreSelection, restoreViewport } from "./continuity.mjs";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

const SANITIZE_OPTS = {
  USE_PROFILES: { html: true },
  ADD_ATTR: ["data-footnote-ref", "data-footnote-backref", "data-footnotes", "aria-describedby", "aria-label"],
};

function renderMarkdown(md) {
  const raw = window.marked ? window.marked.parse(md || "") : esc(md || "");
  return window.DOMPurify ? window.DOMPurify.sanitize(raw, SANITIZE_OPTS) : raw;
}
function renderBody(text) { return renderMarkdown(text); }

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
  const codeblocks = initCodeBlocks();
  const state = { doc: null, displayDoc: null, displayBlocks: [], name: "", notes: "", view: "document", activePath: null, resolved: new Set(), activeId: null, showResolved: {}, collapsed: {}, anchored: {},
    reviewingChanges: false, revisions: [], beforeRev: null, afterRev: "current", viewedRev: 0, suppressedBlockRev: 0, diffBeforeDoc: null, diffAfterDoc: null, narrow: false };
  const blockView = createBlockReconciler({ docEl, codeblocks, renderMarkdown });
  // Off-screen indicators: agent annotations the user hasn't addressed, and
  // changed blocks under review — shown at the top/bottom doc-viewport edge
  // when scrolled out of view; click jumps to the nearest one.
  const awaitEdge = initEdgeIndicator(docScrollEl, {
    className: "await-edge", scrollEls: [docScrollEl],
    getItems: () => railEl.querySelectorAll(".awaits-user"),
    isActive: () => !state.narrow && state.view === "document",
  });
  const changeEdge = initEdgeIndicator(docScrollEl, {
    className: "change-edge", flagIcon: "✎", scrollEls: [docScrollEl],
    getItems: () => docEl.querySelectorAll(".block.wb-changed, .block.wb-added, .block.wb-removed"),
    isActive: () => state.reviewingChanges && !state.narrow && state.view === "document",
  });
  const updateEdges = () => { awaitEdge.update(); changeEdge.update(); };

  const composer = initBlockComposer({
    docEl,
    railEl,
    postComment: async (p) => {
      await fetch(`${API}/comments`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(p) });
      await runRefresh();
    },
  });

  function annotationsOn(b) { return (state.displayDoc?.annotations || []).filter((a) => a.block === b.name && (a.path || DEFAULT_PATH) === (b.path || DEFAULT_PATH)); }
  // Distinct file paths in first-appearance order; the blocks of the active
  // file only (what the main column renders); switch the active file (used by
  // the TOC file-tree headers in multi-file sessions).
  function distinctPaths() {
    const out = [], seen = new Set();
    for (const b of state.doc?.blocks || []) { const p = b.path || DEFAULT_PATH; if (!seen.has(p)) { seen.add(p); out.push(p); } }
    return out;
  }
  function visibleBlocks() { return state.displayBlocks; }
  async function switchFile(p) {
    state.activePath = p;
    if (state.reviewingChanges) await revisions.render();
    else await renderSurface({ beforeDoc: null, afterDoc: state.doc });
    if (distinctPaths().length > 1) titleEl.textContent = `${state.name} · ${p}`;
    docScrollEl.scrollTop = 0;
  }

  function syncHighlights(changedKeys) {
    const active = new Map();
    for (const block of visibleBlocks()) for (const annotation of annotationsOn(block)) {
      if (!annotation.selector?.exact) continue;
      if (!annotation.isTag && state.resolved.has(annotation.id)) continue;
      if (annotation.isTag && annotation.state !== "active") continue;
      active.set(annotation.id, { block, annotation });
    }
    for (const mark of docEl.querySelectorAll("mark.wb-anno[data-anno-id]")) {
      if (!active.has(mark.dataset.annoId)) unwrapHighlight(mark);
    }
    for (const id of Object.keys(state.anchored)) if (!active.has(id)) delete state.anchored[id];
    for (const [id, { block, annotation }] of active) {
      const section = [...docEl.querySelectorAll(":scope > section[data-block-key]")]
        .find((node) => node.dataset.blockKey === blockKey(block));
      if (!section) { state.anchored[id] = false; continue; }
      const kindClass = styleOf(annotation.kind).cls;
      const signature = selectorSignature(annotation.selector, kindClass);
      const marks = [...section.querySelectorAll("mark.wb-anno")].filter((mark) => mark.dataset.annoId === id);
      const current = highlightsMatchSelector(marks, signature);
      if (current && !changedKeys.has(blockKey(block))) { state.anchored[id] = true; continue; }
      for (const mark of marks) unwrapHighlight(mark);
      const body = section.querySelector(".block-md");
      state.anchored[id] = highlightCurrent(body, annotation.selector, id, kindClass) ||
        (state.reviewingChanges && highlightDeletion(body, annotation.selector, id, kindClass));
    }
  }

  const annotationView = createAnnotationView({
    API, state, railEl, drawerScrollEl, commentsToggleEl, countEl: ctCountEl, docEl,
    renderBody, refresh: () => runRefresh(), updateEdges,
  });

  const captureContext = () => ({
    viewport: captureViewport(docScrollEl, docEl),
    selection: captureSelection(docEl),
  });

  async function renderSurface({ beforeDoc = null, afterDoc = state.doc, detail = "adaptive", error = null, context = null } = {}) {
    let errorEl = diffBarEl.querySelector(".diff-error-inline");
    if (error) {
      if (!errorEl) { errorEl = document.createElement("span"); errorEl.className = "diff-error-inline"; diffBarEl.appendChild(errorEl); }
      errorEl.textContent = error; return;
    }
    errorEl?.remove();
    const { viewport, selection } = context || captureContext();
    state.displayDoc = afterDoc;
    const result = await blockView.reconcile({ beforeDoc, afterDoc, activePath: state.activePath, detail });
    state.displayBlocks = result.plan.map((entry) => entry.block);
    syncHighlights(result.changedKeys);
    annotationView.render();
    renderTOC();
    updateEdges();
    restoreViewport(docScrollEl, docEl, viewport);
    restoreSelection(docEl, selection);
  }
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
    // are listed (others collapse to their header). During revision review each header
    // carries a dot when that file has changes in the before→after range, so
    // you can see that a non-selected file changed too. Clicking a header
    // switches the active file while keeping the review on the same surface.
    const changedPaths = new Set();
    if (state.reviewingChanges && state.diffBeforeDoc && state.diffAfterDoc) {
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

  async function runRefresh() {
    const [s, d, n, rev] = await Promise.all([
      fetch(`${API}/session`).then((r) => r.json()),
      fetch(`${API}/document`).then((r) => r.json()),
      fetch(`${API}/notes`).then((r) => r.json()),
      fetch(`${API}/revisions`).then((r) => r.json()).catch(() => ({ revisions: [] })),
    ]);
    state.doc = d;
    const nextNotes = n.content || "";
    if (state.notes !== nextNotes) {
      state.notes = nextNotes;
      notesViewEl.innerHTML = nextNotes ? renderMarkdown(nextNotes) : "<p class=\"empty-notes\">No notes yet.</p>";
    }
    state.name = s.name || "Whiteboard";
    const paths = distinctPaths();
    if (!paths.includes(state.activePath)) state.activePath = paths[0] || DEFAULT_PATH;
    state.viewedRev = Number(s.viewedVersion) || 0;
    state.revisions = rev.revisions || [];
    state.resolved = new Set(Object.keys(s.resolved || {}));
    titleEl.textContent = paths.length > 1 ? `${state.name} · ${state.activePath}` : state.name;
    statusEl.textContent = s.status || "exploring";
    document.title = `${s.name || "Whiteboard"} — Whiteboard`;
    // Detection and rendering share one baseline. For a never-reviewed session,
    // compare from the oldest available snapshot so a coalesced annotation
    // refresh cannot mask the document edit immediately before it.
    const baseline = Math.max(reviewBaseline(state.revisions, d.rev ?? 0, state.viewedRev), state.suppressedBlockRev);
    const pendingBlocks = baseline < (d.rev ?? 0) &&
      state.revisions.some((revision) => revision.rev > baseline && revision.rev <= (d.rev ?? 0) && revision.blocks > 0);
    if (state.reviewingChanges) await revisions.render();
    else if (pendingBlocks) await revisions.show({ baseline });
    else await renderSurface({ afterDoc: state.doc });
    setView(state.view);
    await chat.refresh();
  }

  const revisions = initRevisionReview({
    API, state, diffBarEl, diffBeforeEl, diffAfterEl,
    captureContext, onRender: renderSurface,
  });
  const chat = initChat(chatMountEl, API);

  function setView(v) {
    state.view = v;
    viewTabsEl.querySelectorAll(".view-tab").forEach((t) => t.classList.toggle("active", t.dataset.view === v));
    docScrollEl.hidden = (v !== "document");
    notesViewEl.hidden = (v !== "notes");
    tocRailEl.hidden = (v !== "document");
    diffBarEl.hidden = (v !== "document") || !state.reviewingChanges;
    updateEdges();
  }
  viewTabsEl.addEventListener("click", (e) => { const tab = e.target.closest(".view-tab"); if (tab) setView(tab.dataset.view); });
  diffToggleEl.addEventListener("click", () => state.reviewingChanges ? revisions.hide() : revisions.show());
  diffBeforeEl.addEventListener("change", () => { state.beforeRev = diffBeforeEl.value === "current" ? "current" : Number(diffBeforeEl.value); revisions.render(); });
  diffAfterEl.addEventListener("change", () => { state.afterRev = diffAfterEl.value === "current" ? "current" : Number(diffAfterEl.value); revisions.render(); });
  diffMarkReadEl.addEventListener("click", revisions.markRead);
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
    annotationView.render();
  };
  const narrowMq = window.matchMedia("(max-width: 920px)");
  applyNarrow(narrowMq.matches);
  narrowMq.addEventListener("change", (e) => applyNarrow(e.matches));
  // Coalesce the noisy burst of refresh events into one snapshot reconciliation.
  let refreshTimer = null;
  const offRefresh = onRefresh(() => {
    if (refreshTimer) clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => { refreshTimer = null; runRefresh().catch((e) => console.error("wb refresh", e)); }, 80);
  });
  const offStatus = onStatus((s) => {
    connEl.textContent = s === "live" ? "live" : "reconnecting…";
    connEl.classList.toggle("bad", s !== "live");
  });
  runRefresh().catch((e) => console.error("wb init", e));

  const timer = setInterval(annotationView.updateTimes, 30000);

  // Tear down our stream registrations + timers on re-route; main.mjs owns the shared EventSource.
  return { destroy() { offRefresh(); offStatus(); if (refreshTimer) clearTimeout(refreshTimer); clearInterval(timer); } };
}
