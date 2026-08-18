// blockview.mjs — viewer for block-document sessions (document.json).
// Renders each block as a <section data-block-id> with its markdown, shows block
// flags as badges, and renders comments as margin notes anchored to the block
// (by block name, with an optional in-block selector span highlight). Reply +
// resolve via the API. Live via SSE. Legacy deliverable.md sessions use the
// separate viewer.mjs path; this module only runs for model === "blocks".

import { initCodeBlocks } from "./codeblocks.mjs";
import { initBlockComposer } from "./blockcomposer.mjs";
import { initDiffMode } from "./blockdiff.mjs";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

const SANITIZE_OPTS = {
  USE_PROFILES: { html: true },
  ADD_ATTR: ["data-footnote-ref", "data-footnote-backref", "data-footnotes", "aria-describedby", "aria-label"],
};

const FLAG_BADGE = {
  "needs-attention": { cls: "flag-attention", icon: "⚑", title: "Needs your attention" },
  decided: { cls: "flag-decided", icon: "✓", title: "Decided" },
  superseded: { cls: "flag-superseded", icon: "↳", title: "Superseded" },
};

function renderMarkdown(md) {
  const raw = window.marked ? window.marked.parse(md || "") : esc(md || "");
  return window.DOMPurify ? window.DOMPurify.sanitize(raw, SANITIZE_OPTS) : raw;
}
function renderBody(text) { return renderMarkdown(text); }

// Wrap the first occurrence of selector.exact (verified by prefix/suffix) in a
// <mark> within a block's rendered DOM. Returns true if highlighted.
function highlightIn(blockMd, selector) {
  if (!selector || !selector.exact) return false;
  const text = blockMd.textContent;
  let start = text.indexOf(selector.exact);
  if (start === -1) return false;
  if (selector.prefix && text.slice(Math.max(0, start - selector.prefix.length), start) !== selector.prefix) {
    const pi = text.indexOf(selector.prefix);
    if (pi !== -1) start = pi + selector.prefix.length;
  }
  const end = start + selector.exact.length;
  return wrapRange(blockMd, start, end);
}

// Walk text nodes, split, and wrap [start,end) in a <mark class=wb-anno>.
function wrapRange(root, start, end) {
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
    mark.className = "wb-anno";
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
          <span class="version" id="version">v—</span>
          <button class="diff-toggle" id="diff-toggle" type="button" title="Show changes">⇄</button>
          <span class="conn" id="conn">live</span>
        </div>
        <div class="diff-bar" id="diff-bar" hidden><label>before <select id="diff-before"></select></label><span class="diff-arrow">→</span><label>after <select id="diff-after"></select></label><button class="diff-markread" id="diff-markread" type="button">Mark as read</button></div>
        <div class="doc-scroll" id="doc-scroll">
          <div class="doc-wrap doc-wrap-block comments-on" id="doc-wrap">
            <article id="doc"></article>
            <div class="margin-rail" id="margin-rail" aria-label="Comments"></div>
          </div>
        </div>
      </main>
    </div>
    <nav class="toc-rail" id="toc-rail"><div class="toc-title">Blocks</div><ol class="toc-list" id="toc-list"></ol></nav>
    <div class="notes-drawer" id="notes-drawer"><div class="grip" id="notes-grip">▾ Notes log</div><pre id="notes"></pre></div>`;

  const docEl = document.getElementById("doc");
  const railEl = document.getElementById("margin-rail");
  const tocList = document.getElementById("toc-list");
  const titleEl = document.getElementById("title");
  const statusEl = document.getElementById("status");
  const versionEl = document.getElementById("version");
  const connEl = document.getElementById("conn");
  const notesEl = document.getElementById("notes");
  const drawerEl = document.getElementById("notes-drawer");
  const gripEl = document.getElementById("notes-grip");
  const diffBarEl = document.getElementById("diff-bar");
  const diffToggleEl = document.getElementById("diff-toggle");
  const diffBeforeEl = document.getElementById("diff-before");
  const diffAfterEl = document.getElementById("diff-after");
  const diffMarkReadEl = document.getElementById("diff-markread");
  const docWrapEl = document.getElementById("doc-wrap");
  const codeblocks = initCodeBlocks();
  const state = { doc: null, notes: "", resolved: new Set(), activeId: null, showResolved: {}, collapsed: {},
    diffMode: false, revisions: [], beforeRev: null, afterRev: "current", viewedRev: 0, diffBeforeDoc: null, diffAfterDoc: null };

  const composer = initBlockComposer({
    docEl,
    postComment: async (p) => {
      await fetch(`${API}/comments`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(p) });
      await runRefresh();
    },
  });

  const whoClass = (n) => (String(n || "").toLowerCase() === "agent" ? "agent" : "user");

  function commentsOn(name) { return (state.doc?.comments || []).filter((c) => c.block === name); }

  function renderBlocks() {
    docEl.innerHTML = "";
    for (const b of state.doc?.blocks || []) {
      const sec = document.createElement("section");
      sec.className = "block";
      sec.dataset.blockId = b.name;
      let flags = "";
      for (const f of b.flags || []) {
        const badge = FLAG_BADGE[f];
        if (badge) flags += `<span class="block-flag ${badge.cls}" title="${esc(badge.title)}">${badge.icon}</span>`;
      }
      sec.innerHTML = `<div class="block-head"><span class="block-name">${esc(b.name)}</span>${flags}</div><div class="block-md">${renderMarkdown(b.md)}</div>`;
      docEl.appendChild(sec);
      // Only highlight spans for OPEN comments; resolved comments clear their mark.
      for (const c of commentsOn(b.name)) if (!state.resolved.has(c.id)) highlightIn(sec.querySelector(".block-md"), c.selector);
    }
  }

  // Render one comment as a margin card. The resolve button lives in the excerpt
  // row (always visible/clickable), NOT in the reply box. isResolved controls the
  // toggle label; resolved cards are NOT faded (they only differ by label).
  function renderCard(b, c, anchorY, lastBottom, isResolved) {
    const card = document.createElement("div");
    card.className = "thread" + (isResolved ? " is-resolved" : "") + (state.activeId === c.id ? " active" : "") + (state.collapsed[c.id] ? " collapsed" : "");
    card.dataset.annoId = c.id;
    const when = (c.at || "").replace("T", " ").slice(0, 16);
    let replies = "";
    for (const r of c.replies || []) {
      const rw = (r.at || "").replace("T", " ").slice(0, 16);
      replies += `<div class="msg"><span class="who ${whoClass(r.author)}">${esc(r.author)}</span><span class="when">${esc(rw)}</span><div class="body">${renderBody(r.body)}</div></div>`;
    }
    card.innerHTML = `<div class="excerpt"><button class="collapse-btn" type="button" title="${state.collapsed[c.id] ? "Expand" : "Collapse"}">${state.collapsed[c.id] ? "▸" : "▾"}</button>on <code>${esc(b.name)}</code><span class="where">@ ${esc(when)}</span><button class="resolve-btn" type="button" title="${isResolved ? "Unresolve" : "Resolve"}">${isResolved ? "↺ resolved" : "✓ resolve"}</button></div><div class="msg"><span class="who ${whoClass(c.author)}">${esc(c.author)}</span><div class="body">${renderBody(c.body)}</div></div>${replies}<div class="reply-box"><textarea placeholder="Reply…"></textarea><div class="row"><button class="cancel">cancel</button><button class="send" disabled>Reply</button></div></div>`;
    const ta = card.querySelector("textarea");
    const send = card.querySelector(".send");
    ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });
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
    card.addEventListener("click", (e) => { if (e.target.closest(".reply-box")) return; state.activeId = c.id; railEl.querySelectorAll(".thread").forEach((t) => t.classList.toggle("active", t === card)); });
    railEl.appendChild(card);
    const top = Math.max(anchorY, lastBottom + 8);
    card.style.top = `${top}px`;
    return top + card.offsetHeight;
  }

  function renderComments() {
    railEl.innerHTML = "";
    let lastBottom = -8;
    for (const b of state.doc?.blocks || []) {
      const sec = docEl.querySelector(`section[data-block-id="${cssEscape(b.name)}"]`);
      if (!sec) continue;
      const anchorY = sec.offsetTop;
      const all = commentsOn(b.name);
      const open = all.filter((c) => !state.resolved.has(c.id));
      const resolved = all.filter((c) => state.resolved.has(c.id));
      for (const c of open) lastBottom = renderCard(b, c, anchorY, lastBottom, false);
      if (resolved.length > 0) {
        const expanded = !!state.showResolved[b.name];
        const pill = document.createElement("div");
        pill.className = "resolved-pill" + (expanded ? " expanded" : "");
        pill.textContent = `${resolved.length} resolved ${expanded ? "▾" : "▸"}`;
        pill.title = expanded ? "Hide resolved" : "Show resolved";
        pill.addEventListener("click", () => { state.showResolved[b.name] = !expanded; renderComments(); });
        railEl.appendChild(pill);
        const top = Math.max(anchorY, lastBottom + 8);
        pill.style.top = `${top}px`;
        lastBottom = top + pill.offsetHeight;
        if (expanded) for (const c of resolved) lastBottom = renderCard(b, c, anchorY, lastBottom, true);
      }
    }
  }

  function renderTOC() {
    tocList.innerHTML = "";
    for (const b of state.doc?.blocks || []) {
      const li = document.createElement("li");
      const att = (b.flags || []).includes("needs-attention");
      li.className = "toc-item" + (att ? " has-attention" : "");
      li.innerHTML = `<span class="dot" aria-hidden="true"></span><span class="toc-text">${esc(b.name)}</span>`;
      li.addEventListener("click", () => {
        const sec = docEl.querySelector(`section[data-block-id="${cssEscape(b.name)}"]`);
        if (sec) sec.scrollIntoView({ behavior: "smooth", block: "start" });
      });
      tocList.appendChild(li);
    }
  }

  async function runRefresh() {
    const [s, d, n] = await Promise.all([
      fetch(`${API}/session`).then((r) => r.json()),
      fetch(`${API}/document`).then((r) => r.json()),
      fetch(`${API}/notes`).then((r) => r.json()),
    ]);
    state.doc = d; state.notes = n.content || "";
    state.viewedRev = Number(s.viewedVersion) || 0;
    state.resolved = new Set(Object.keys(s.resolved || {}));
    titleEl.textContent = s.name || "Whiteboard";
    statusEl.textContent = s.status || "exploring";
    document.title = `${s.name || "Whiteboard"} — Whiteboard`;
    versionEl.textContent = `v${(d.hash || "").slice(0, 8)} · rev ${d.rev}`;
    notesEl.textContent = n.content || "(no notes yet)";
    renderBlocks();
    await codeblocks.enhance(docEl);
    renderComments();
    renderTOC();
    if (state.diffMode) await diff.render();
  }

  const diff = initDiffMode({
    API, state, docEl, codeblocks, renderMarkdown,
    diffBarEl, docWrapEl, diffBeforeEl, diffAfterEl,
    onExit: () => { renderBlocks(); renderComments(); renderTOC(); },
  });

  function connectSSE() {
    const es = new EventSource(`${API}/events`);
    es.addEventListener("open", () => { connEl.textContent = "live"; connEl.classList.remove("bad"); });
    es.addEventListener("error", () => { connEl.textContent = "reconnecting…"; connEl.classList.add("bad"); });
    es.addEventListener("refresh", () => runRefresh());
    return es;
  }

  gripEl.addEventListener("click", () => drawerEl.classList.toggle("open"));
  diffToggleEl.addEventListener("click", () => state.diffMode ? diff.exit() : diff.enter());
  diffBeforeEl.addEventListener("change", () => { state.beforeRev = diffBeforeEl.value === "current" ? "current" : Number(diffBeforeEl.value); diff.render(); });
  diffAfterEl.addEventListener("change", () => { state.afterRev = diffAfterEl.value === "current" ? "current" : Number(diffAfterEl.value); diff.render(); });
  diffMarkReadEl.addEventListener("click", diff.markRead);
  runRefresh().then(connectSSE);
}

function cssEscape(s) {
  return String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => `\\${c}`);
}