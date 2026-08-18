// blockview.mjs — viewer for block-document sessions (document.json).
// Renders each block as a <section data-block-id> with its markdown, shows block
// flags as badges, and renders comments as margin notes anchored to the block
// (by block name, with an optional in-block selector span highlight). Reply +
// resolve via the API. Live via SSE. Legacy deliverable.md sessions use the
// separate viewer.mjs path; this module only runs for model === "blocks".

import { initCodeBlocks } from "./codeblocks.mjs";
import { initBlockComposer } from "./blockcomposer.mjs";
import { initDiffMode, ago } from "./blockdiff.mjs";
import { initChat } from "./chat.mjs";

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
          <button class="chat-toggle" id="chat-toggle" type="button" title="Chat with the agent">Chat</button>
          <span class="conn" id="conn">live</span>
        </div>
        <div class="diff-bar" id="diff-bar" hidden><div id="diff-before" class="rev-picker"></div><span class="diff-arrow">→</span><div id="diff-after" class="rev-picker"></div><button class="diff-markread" id="diff-markread" type="button">Done</button></div>
        <div class="doc-scroll" id="doc-scroll">
          <div class="doc-wrap doc-wrap-block comments-on" id="doc-wrap">
            <article id="doc"></article>
            <div class="margin-rail" id="margin-rail" aria-label="Comments"></div>
          </div>
        </div>
      </main>
    </div>
    <nav class="toc-rail" id="toc-rail"><div class="toc-title">Contents</div><ol class="toc-list" id="toc-list"></ol></nav>
    <aside class="chat-side" id="chat-side" hidden><div class="chat-head"><span class="chat-head-title">Chat</span><button class="chat-close" id="chat-close" type="button" aria-label="Close chat">✕</button></div><div id="chat-mount"></div></aside>
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
  const chatSideEl = document.getElementById("chat-side");
  const chatMountEl = document.getElementById("chat-mount");
  const chatToggleEl = document.getElementById("chat-toggle");
  const chatCloseEl = document.getElementById("chat-close");
  const docWrapEl = document.getElementById("doc-wrap");
  const codeblocks = initCodeBlocks();
  const state = { doc: null, notes: "", resolved: new Set(), activeId: null, showResolved: {}, collapsed: {}, anchored: {},
    diffMode: false, revisions: [], beforeRev: null, afterRev: "current", viewedRev: 0, diffBeforeDoc: null, diffAfterDoc: null };

  const composer = initBlockComposer({
    docEl,
    railEl,
    postComment: async (p) => {
      await fetch(`${API}/comments`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(p) });
      await runRefresh();
    },
  });

  const whoClass = (n) => (String(n || "").toLowerCase() === "agent" ? "agent" : "user");

  function commentsOn(name) { return (state.doc?.comments || []).filter((c) => c.block === name); }

  function renderBlocks() {
    docEl.innerHTML = "";
    state.anchored = {};
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
      // Highlight spans for OPEN comments and record which anchors still match the
      // current text. state.anchored[id] === true  -> highlighted in the doc (card
      // omits the quote); false -> anchor no longer matches (stale, shown in the
      // card); undefined -> resolved comment (not highlighted this pass, shown).
      for (const c of commentsOn(b.name)) {
        if (state.resolved.has(c.id)) continue;
        state.anchored[c.id] = highlightIn(sec.querySelector(".block-md"), c.selector);
      }
    }
  }

  // Render one comment as a margin card. The resolve button lives in the reply
  // row footer (pushed left by its margin-right:auto), NOT in the excerpt. The
  // excerpt shows the anchored selected text (if any) plus a relative time.
  // isResolved controls the toggle label; resolved cards are NOT faded (they
  // only differ by label).
  function renderCard(b, c, anchorY, lastBottom, isResolved) {
    const card = document.createElement("div");
    card.className = "thread" + (isResolved ? " is-resolved" : "") + (state.activeId === c.id ? " active" : "") + (state.collapsed[c.id] ? " collapsed" : "");
    card.dataset.annoId = c.id;
    // Show the anchored text inside the card ONLY when it is NOT highlighted in the
    // document. When the anchor still matches, the highlight in the main text is the
    // indicator and the card omits the quote. A stale anchor (highlight attempted
    // but failed) gets a .stale marker + title; resolved comments show the quote
    // without the stale marker.
    const hasSel = !!(c.selector && c.selector.exact);
    const showQuote = hasSel && !state.anchored[c.id];
    const stale = hasSel && state.anchored[c.id] === false;
    const staleTitle = stale ? ` title="Anchor no longer matches the current block (it may have been edited)"` : "";
    const quote = showQuote ? `<span class="excerpt-quote${stale ? " stale" : ""}"${staleTitle}>“${esc(c.selector.exact)}”</span>` : "";
    let replies = "";
    for (const r of c.replies || []) {
      replies += `<div class="msg"><span class="who ${whoClass(r.author)}">${esc(r.author)}</span><span class="when" data-at="${esc(r.at)}">${ago(r.at)}</span><div class="body">${renderBody(r.body)}</div></div>`;
    }
    card.innerHTML = `<div class="excerpt"><button class="collapse-btn" type="button" title="${state.collapsed[c.id] ? "Expand" : "Collapse"}">${state.collapsed[c.id] ? "▸" : "▾"}</button>${quote}<span class="where" data-at="${esc(c.at)}">${ago(c.at)}</span></div><div class="msg"><span class="who ${whoClass(c.author)}">${esc(c.author)}</span><div class="body">${renderBody(c.body)}</div></div>${replies}<div class="reply-box"><textarea placeholder="Reply…"></textarea><div class="row"><button class="resolve-btn" type="button" title="${isResolved ? "Unresolve" : "Resolve"}">${isResolved ? "↺ resolved" : "✓ resolve"}</button><button class="cancel">cancel</button><button class="send" disabled>Reply</button></div></div>`;
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

  // TOC lists the rendered headings (h1/h2/h3) inside each block — the actual
  // titles/subtitles — instead of the block name slugs. A block with no heading
  // falls back to its name so it stays navigable. Indentation reuses the
  // existing .toc-h2/.toc-h3 classes; needs-attention dot is per block.
  function renderTOC() {
    tocList.innerHTML = "";
    const append = (text, level, att, el) => {
      const li = document.createElement("li");
      li.className = "toc-item toc-h" + level + (att ? " has-attention" : "");
      li.innerHTML = `<span class="dot" aria-hidden="true"></span><span class="toc-text">${esc(text)}</span>`;
      li.addEventListener("click", () => el.scrollIntoView({ behavior: "smooth", block: "start" }));
      tocList.appendChild(li);
    };
    for (const b of state.doc?.blocks || []) {
      const sec = docEl.querySelector(`section[data-block-id="${cssEscape(b.name)}"]`);
      const heads = sec ? [...sec.querySelectorAll("h1, h2, h3")] : [];
      const att = (b.flags || []).includes("needs-attention");
      if (!heads.length) { append(b.name, 1, att, sec || docEl); continue; }
      for (const h of heads) append(h.textContent, Number(h.tagName.slice(1)), att, h);
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
    state.viewedRev = Number(s.viewedVersion) || 0;
    state.revisions = rev.revisions || [];
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
    chat.refresh();
    if (state.diffMode) { await diff.render(); return; }
    // A block-changing change came in since the user last clicked “Done”: jump
    // into the diff, comparing last-viewed → current. Only on live (SSE)
    // refresh, not the initial load, and only if there really are block changes.
    if (auto && state.viewedRev > 0 && state.viewedRev < (d.rev ?? 0) &&
        state.revisions.some((r) => r.rev > state.viewedRev && r.rev <= (d.rev ?? 0) && r.blocks > 0)) {
      await diff.enter();
    }
  }

  const diff = initDiffMode({
    API, state, docEl, codeblocks, renderMarkdown,
    diffBarEl, docWrapEl, diffBeforeEl, diffAfterEl,
    onExit: () => { renderBlocks(); renderComments(); renderTOC(); },
  });
  const chat = initChat(chatMountEl, API);

  function connectSSE() {
    const es = new EventSource(`${API}/events`);
    es.addEventListener("open", () => { connEl.textContent = "live"; connEl.classList.remove("bad"); });
    es.addEventListener("error", () => { connEl.textContent = "reconnecting…"; connEl.classList.add("bad"); });
    es.addEventListener("refresh", () => runRefresh({ auto: true }));
    return es;
  }

  gripEl.addEventListener("click", () => drawerEl.classList.toggle("open"));
  diffToggleEl.addEventListener("click", () => state.diffMode ? diff.exit() : diff.enter());
  diffBeforeEl.addEventListener("change", () => { state.beforeRev = diffBeforeEl.value === "current" ? "current" : Number(diffBeforeEl.value); diff.render(); });
  diffAfterEl.addEventListener("change", () => { state.afterRev = diffAfterEl.value === "current" ? "current" : Number(diffAfterEl.value); diff.render(); });
  diffMarkReadEl.addEventListener("click", diff.markRead);
  const openChat = () => { chatSideEl.hidden = false; chatToggleEl.classList.add("active"); chat.refresh().then(() => chat.focus && chat.focus()); };
  const closeChat = () => { chatSideEl.hidden = true; chatToggleEl.classList.remove("active"); };
  chatToggleEl.addEventListener("click", () => chatSideEl.hidden ? openChat() : closeChat());
  chatCloseEl.addEventListener("click", closeChat);
  runRefresh().then(connectSSE);

  // Auto-refresh the relative time labels every 30s without a full re-render
  // (a full re-render would wipe in-progress reply textareas).
  setInterval(() => { railEl.querySelectorAll("[data-at]").forEach((el) => { el.textContent = ago(el.dataset.at); }); }, 30000);
}

function cssEscape(s) {
  return String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => `\\${c}`);
}