// Whiteboard session viewer. Renders one session's deliverable.md, anchors W3C
// Web Annotation comments to the document text, threads replies, and keeps live
// via SSE. Marks the session seen on load and on each refresh so unread badges
// clear. Sidebar has Comments, Chat, and History (diff) tabs.

import { initChat } from "./chat.mjs";
import { initHistory } from "./history.mjs";
import { renderDocDiff } from "./docdiff.mjs";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

// DOMPurify options: full HTML profile, plus the footnote extension's data/aria
// attributes (USE_PROFILES html already allows most, these are belt-and-suspenders).
const SANITIZE_OPTS = {
  USE_PROFILES: { html: true },
  ADD_ATTR: ["data-footnote-ref", "data-footnote-backref", "data-footnotes", "aria-describedby", "aria-label"],
};

function renderMarkdown(md) {
  const raw = window.marked ? window.marked.parse(md || "") : esc(md || "");
  return window.DOMPurify ? window.DOMPurify.sanitize(raw, SANITIZE_OPTS) : raw;
}

export function initViewer(root, project, slug) {
  const API = `/api/session/${encodeURIComponent(project)}/${encodeURIComponent(slug)}`;
  const backHref = "/";

  root.innerHTML = `
    <div class="app">
      <main class="doc-col">
        <div class="topbar">
          <a class="back" href="${backHref}">← sessions</a>
          <span class="title" id="title">Whiteboard</span>
          <span class="status" id="status">exploring</span>
          <span class="version" id="version">v—</span>
          <span class="conn" id="conn">live</span>
        </div>
        <div class="diff-banner" id="diff-banner" hidden>
          <span id="diff-banner-text"></span>
          <button id="diff-markread" type="button">Mark as read</button>
        </div>
        <div class="doc-scroll" id="doc-scroll">
          <div class="doc-wrap"><article id="doc"></article></div>
        </div>
      </main>
      <aside class="side">
        <div class="side-head">
          <div class="tabs">
            <span class="tab active" data-tab="comments">Comments</span>
            <span class="tab" data-tab="chat">Chat</span>
            <span class="tab" data-tab="history">History</span>
          </div>
          <span class="count" id="count">0</span>
        </div>
        <div class="side-scroll" id="threads"></div>
        <div class="side-scroll" id="chat-panel" hidden></div>
        <div class="side-scroll" id="history-panel" hidden></div>
      </aside>
    </div>
    <div class="notes-drawer" id="notes-drawer">
      <div class="grip" id="notes-grip">▾ Notes log</div>
      <pre id="notes"></pre>
    </div>`;

  const docEl = document.getElementById("doc");
  const threadsEl = document.getElementById("threads");
  const chatPanelEl = document.getElementById("chat-panel");
  const historyPanelEl = document.getElementById("history-panel");
  const countEl = document.getElementById("count");
  const titleEl = document.getElementById("title");
  const statusEl = document.getElementById("status");
  const versionEl = document.getElementById("version");
  const connEl = document.getElementById("conn");
  const notesEl = document.getElementById("notes");
  const drawerEl = document.getElementById("notes-drawer");
  const gripEl = document.getElementById("notes-grip");
  const diffBannerEl = document.getElementById("diff-banner");
  const diffBannerTextEl = document.getElementById("diff-banner-text");
  const diffMarkReadEl = document.getElementById("diff-markread");

  const state = { deliverable: { content: "", version: "" }, notes: "", annotations: [], activeId: null, tab: "comments", viewedVersion: null, diffMode: false, oldViewedContent: "" };

  const chat = initChat(chatPanelEl, API);
  const history = initHistory(historyPanelEl, API);

  function setTab(tab) {
    state.tab = tab;
    document.querySelectorAll(".side-head .tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === tab));
    threadsEl.hidden = tab !== "comments";
    chatPanelEl.hidden = tab !== "chat";
    historyPanelEl.hidden = tab !== "history";
    if (tab === "chat") chat.refresh().then(() => chat.focus && chat.focus());
    if (tab === "history") history.refresh();
  }
  document.querySelectorAll(".side-head .tab").forEach((t) => t.addEventListener("click", () => setTab(t.dataset.tab)));

  // ---- text-node offset mapping ----
  function cumulativeOffsets(rootNode) {
    const out = [];
    const w = document.createTreeWalker(rootNode, NodeFilter.SHOW_TEXT, null);
    let n, cum = 0;
    while ((n = w.nextNode())) { out.push({ node: n, start: cum, end: (cum += n.nodeValue.length) }); }
    return out;
  }
  function offsetOf(rootNode, target, off) {
    for (const { node, start } of cumulativeOffsets(rootNode)) if (node === target) return start + off;
    return -1;
  }
  function quoteIndex(hay, exact, prefix, suffix) {
    if (!exact) return -1;
    if (prefix && suffix) { const i = hay.indexOf(prefix + exact + suffix); if (i !== -1) return i + prefix.length; }
    if (prefix) { const i = hay.indexOf(prefix + exact); if (i !== -1) return i + prefix.length; }
    if (suffix) { const i = hay.indexOf(exact + suffix); if (i !== -1) return i; }
    return hay.indexOf(exact);
  }
  function wrapRangeByOffsets(rootNode, start, end, annoId) {
    if (start < 0 || end <= start) return false;
    const map = cumulativeOffsets(rootNode);
    let si = map.findIndex((m) => start >= m.start && start < m.end);
    let ei = map.findIndex((m) => end > m.start && end <= m.end);
    if (si === -1 || ei === -1) return false;
    const sn = map[si].node, relS = start - map[si].start;
    if (relS > 0) sn.splitText(relS);
    const startTail = relS > 0 ? sn.nextSibling : sn;
    const map2 = cumulativeOffsets(rootNode);
    const ee = map2.find((m) => end > m.start && end <= m.end);
    if (!ee) return false;
    const relE = end - ee.start;
    if (relE > 0 && relE < ee.node.nodeValue.length) ee.node.splitText(relE);
    const wrapped = [];
    const w = document.createTreeWalker(rootNode, NodeFilter.SHOW_TEXT, null);
    let cur = w.nextNode(), collecting = false;
    while (cur) {
      if (cur === startTail) collecting = true;
      if (collecting) { wrapped.push(cur); if (cur === ee.node) break; }
      cur = w.nextNode();
    }
    for (const tn of wrapped) {
      if (!tn.parentNode) continue;
      const mark = document.createElement("mark");
      mark.className = "wb-anno";
      mark.dataset.annoId = annoId;
      tn.parentNode.insertBefore(mark, tn);
      mark.appendChild(tn);
    }
    return true;
  }

  // ---- annotation helpers ----
  const isTopLevel = (a) => a && a.motivation !== "replying" && !(a.target && a.target.id);
  const topLevel = () => state.annotations.filter(isTopLevel);
  const repliesOf = (pid) => state.annotations
    .filter((a) => a.motivation === "replying" && a.target && a.target.id === pid)
    .sort((a, b) => (a.created || "").localeCompare(b.created || ""));
  const excerptOf = (a) => {
    const tq = ((a.target && a.target.selector) || []).find((s) => s.type === "TextQuoteSelector");
    return tq ? tq.exact : "";
  };

  function anchorAll() {
    const full = docEl.textContent;
    for (const a of topLevel()) {
      const sel = (a.target && a.target.selector) || [];
      const tq = sel.find((s) => s.type === "TextQuoteSelector");
      const tp = sel.find((s) => s.type === "TextPositionSelector");
      let start = tq ? quoteIndex(full, tq.exact, tq.prefix, tq.suffix) : -1;
      if (start === -1 && tp) start = tp.start;
      const len = tq && tq.exact ? tq.exact.length : (tp ? tp.end - tp.start : 0);
      const end = start === -1 ? -1 : start + len;
      if (start === -1) { a._anchored = false; continue; }
      const id = a.id.split(":").pop();
      a._anchored = wrapRangeByOffsets(docEl, start, end, id);
      a._start = a._anchored ? start : -1;
    }
  }

  function renderDoc() {
    if (state.diffMode) {
      docEl.innerHTML = renderDocDiff(state.oldViewedContent, state.deliverable.content, renderMarkdown);
      diffBannerEl.hidden = false;
      diffBannerTextEl.textContent = `Changes since v${(state.viewedVersion || "").slice(0, 8)} → v${(state.deliverable.version || "").slice(0, 8)}`;
    } else {
      docEl.innerHTML = renderMarkdown(state.deliverable.content);
      diffBannerEl.hidden = true;
      anchorAll();
    }
    enhanceCodeBlocks(docEl);
  }

  // ---- code blocks: syntax highlighting + mermaid ----
  function highlightCode(root) {
    if (!window.hljs) return;
    for (const code of root.querySelectorAll("pre code")) {
      if (code.classList.contains("language-mermaid")) continue;
      if (code.dataset.highlighted) continue;
      try { window.hljs.highlightElement(code); code.dataset.highlighted = "yes"; } catch {}
    }
  }

  let mermaidLoading = null;
  function loadMermaid() {
    if (window.mermaid) return Promise.resolve(window.mermaid);
    if (mermaidLoading) return mermaidLoading;
    mermaidLoading = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js";
      s.onload = () => { try { window.mermaid.initialize({ startOnLoad: false, securityLevel: "loose" }); } catch {} resolve(window.mermaid); };
      s.onerror = () => reject(new Error("mermaid load failed"));
      document.head.appendChild(s);
    });
    return mermaidLoading;
  }

  async function renderMermaid(root) {
    const blocks = [...root.querySelectorAll("pre code.language-mermaid")];
    if (blocks.length === 0) return;
    try {
      const mermaid = await loadMermaid();
      const nodes = [];
      for (const code of blocks) {
        const pre = code.parentElement;
        if (!pre) continue;
        const div = document.createElement("div");
        div.className = "mermaid";
        div.textContent = code.textContent;
        pre.replaceWith(div);
        nodes.push(div);
      }
      await mermaid.run({ nodes });
    } catch {
      // offline / load failed: leave rendered as a code block
    }
  }

  async function enhanceCodeBlocks(root) {
    highlightCode(root);
    await renderMermaid(root);
  }

  function renderBody(text) {
    const raw = window.marked ? window.marked.parse(text || "") : esc(text);
    return window.DOMPurify ? window.DOMPurify.sanitize(raw, SANITIZE_OPTS) : raw;
  }
  const whoClass = (name) => (String(name || "").toLowerCase() === "agent" ? "agent" : "user");

  function renderMsg(a) {
    const div = document.createElement("div");
    div.className = "msg";
    const who = (a.creator && a.creator.name) || "user";
    const when = (a.created || "").replace("T", " ").slice(0, 16);
    div.innerHTML = `<span class="who ${whoClass(who)}">${esc(who)}</span><span class="when">${esc(when)}</span><div class="body">${renderBody(a.body && a.body.value)}</div>`;
    return div;
  }

  function wireReply(card, parent) {
    const ta = card.querySelector("textarea");
    const send = card.querySelector(".send");
    const cancel = card.querySelector(".cancel");
    ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });
    send.addEventListener("click", async () => {
      const text = ta.value.trim();
      if (!text) return;
      send.disabled = true;
      await postComment({ text, replyTo: parent.id, creator: "user" });
      ta.value = "";
    });
    cancel.addEventListener("click", () => { ta.value = ""; send.disabled = true; });
  }

  function setActive(id) {
    state.activeId = id;
    document.querySelectorAll(".thread").forEach((c) => c.classList.toggle("active", c.dataset.annoId === id));
    document.querySelectorAll("mark.wb-anno").forEach((m) => m.classList.toggle("active", m.dataset.annoId === id));
    const mark = document.querySelector(`mark.wb-anno[data-anno-id="${id}"]`);
    if (mark) mark.scrollIntoView({ behavior: "smooth", block: "center" });
    else { const c = document.querySelector(`.thread[data-anno-id="${id}"]`); if (c) c.scrollIntoView({ behavior: "smooth", block: "center" }); }
  }

  function renderThreads() {
    const items = topLevel().slice().sort((a, b) => {
      const pa = a._start ?? Infinity, pb = b._start ?? Infinity;
      return pa !== pb ? pa - pb : (a.created || "").localeCompare(b.created || "");
    });
    countEl.textContent = String(items.length);
    if (items.length === 0) { threadsEl.innerHTML = `<div class="empty">Select text in the document to add a comment.</div>`; return; }
    threadsEl.innerHTML = "";
    for (const a of items) {
      const id = a.id.split(":").pop();
      const card = document.createElement("div");
      card.className = "thread" + (a._anchored === false ? " orphaned" : "") + (state.activeId === id ? " active" : "");
      card.dataset.annoId = id;
      const ex = excerptOf(a);
      const ver = (a.target && a.target.version ? a.target.version : "—").slice(0, 8);
      const where = a._anchored === false ? `not found in current doc (made @ ${ver})` : `@ ${ver}`;
      card.innerHTML = `<div class="excerpt">${esc(ex.slice(0, 160))}${ex.length > 160 ? "…" : ""}<span class="where">${esc(where)}</span></div><div class="msg-list"></div><div class="reply-box"><textarea placeholder="Reply…"></textarea><div class="row"><button class="cancel">cancel</button><button class="send" disabled>Reply</button></div></div>`;
      const list = card.querySelector(".msg-list");
      list.appendChild(renderMsg(a));
      for (const r of repliesOf(a.id)) list.appendChild(renderMsg(r));
      wireReply(card, a);
      card.addEventListener("click", (e) => { if (e.target.closest(".reply-box")) return; setActive(id); });
      threadsEl.appendChild(card);
    }
  }

  docEl.addEventListener("click", (e) => {
    const m = e.target.closest("mark.wb-anno");
    if (m) setActive(m.dataset.annoId);
  });

  // ---- selection -> comment ----
  let fab = null;
  const removeFab = () => { if (fab) { fab.remove(); fab = null; } };
  document.addEventListener("mouseup", () => setTimeout(positionFab, 0));
  document.addEventListener("keyup", (e) => { if (e.key === "Escape") removeFab(); });

  function positionFab() {
    removeFab();
    if (state.diffMode) return; // don't allow commenting on a diff view
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return;
    const range = sel.getRangeAt(0);
    if (!docEl.contains(range.commonAncestorContainer)) return;
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
    fab.addEventListener("click", () => { openComposer(range, sel); removeFab(); });
  }

  function selectorsFor(range, sel) {
    const full = docEl.textContent;
    let start = offsetOf(docEl, range.startContainer, range.startOffset);
    let end = offsetOf(docEl, range.endContainer, range.endOffset);
    const exact = sel.toString();
    if (start === -1 && exact) start = full.indexOf(exact);
    if (end === -1 && start >= 0) end = start + exact.length;
    const prefix = start > 0 ? full.slice(Math.max(0, start - 32), start) : "";
    const suffix = end >= 0 && end < full.length ? full.slice(end, end + 32) : "";
    const selector = [{ type: "TextQuoteSelector", exact, prefix, suffix }];
    if (start >= 0 && end > start) selector.push({ type: "TextPositionSelector", start, end });
    return selector;
  }

  function openComposer(range, sel) {
    const selector = selectorsFor(range, sel);
    const rect = range.getBoundingClientRect();
    const box = document.createElement("div");
    box.style.cssText = `position:absolute;z-index:60;left:${rect.left + window.scrollX}px;top:${rect.top + window.scrollY - 6}px;background:#fff;border:1px solid var(--line);border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,0.18);padding:10px;width:300px;`;
    box.innerHTML = `<textarea placeholder="Why is this?…" style="width:100%;min-height:70px;font:inherit;font-size:13.5px;padding:7px;border:1px solid var(--line);border-radius:8px;"></textarea><div style="display:flex;gap:6px;margin-top:6px;justify-content:flex-end;"><button class="cancel" style="background:#f0f0ee;border:none;border-radius:7px;padding:5px 10px;cursor:pointer;">Cancel</button><button class="send" style="background:var(--accent);color:#fff;border:none;border-radius:7px;padding:5px 10px;cursor:pointer;" disabled>Comment</button></div>`;
    document.body.appendChild(box);
    const ta = box.querySelector("textarea"), send = box.querySelector(".send"), cancel = box.querySelector(".cancel");
    ta.focus();
    ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });
    const close = () => { box.remove(); window.getSelection().removeAllRanges(); };
    cancel.addEventListener("click", close);
    send.addEventListener("click", async () => {
      const text = ta.value.trim();
      if (!text) return;
      send.disabled = true;
      await postComment({ text, selector, version: state.deliverable.version, creator: "user" });
      close();
    });
  }

  // ---- API ----
  const getJSON = (p) => fetch(p).then((r) => r.json());
  async function postComment(payload) {
    await fetch(`${API}/comments`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
    await runRefresh();
  }
  async function markSeen() { try { await fetch(`${API}/seen`, { method: "POST" }); } catch {} }

  const commentSig = (annos) => annos.map((a) => `${a.id}:${a.created || ""}`).sort().join("|");
  let lastCommentSig = "";
  let seenMarkedFor = "";
  let refreshTimer = null;
  let refreshInFlight = false;
  let refreshPending = false;

  async function refreshAll() {
    const [s, d, n, c] = await Promise.all([
      getJSON(`${API}/session`), getJSON(`${API}/deliverable`), getJSON(`${API}/notes`), getJSON(`${API}/comments`),
    ]);
    const annos = c.annotations || [];
    const sig = commentSig(annos);
    const versionChanged = d.version !== state.deliverable.version;
    let needRender = versionChanged || n.content !== state.notes || sig !== lastCommentSig;

    // Inline diff: compare current deliverable to the version the human last
    // actively looked at (viewedVersion, stored server-side in .viewed.json).
    const viewed = s.viewedVersion || null;
    if (viewed === null) {
      // First ever look: baseline so future edits diff against this version.
      state.viewedVersion = d.version; state.diffMode = false; state.oldViewedContent = "";
      fetch(`${API}/viewed`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ version: d.version }) }).catch(() => {});
    } else if (viewed !== d.version) {
      if (state.viewedVersion !== viewed || state.oldViewedContent === "" || versionChanged) {
        try { const r = await fetch(`${API}/versions/${viewed}`); const vd = await r.json(); state.oldViewedContent = vd.content || ""; }
        catch { state.oldViewedContent = ""; }
      }
      state.viewedVersion = viewed; state.diffMode = true; needRender = true;
    } else {
      state.viewedVersion = viewed; state.diffMode = false;
    }

    state.deliverable = d; state.notes = n.content; state.annotations = annos;
    titleEl.textContent = s.name || "Whiteboard";
    statusEl.textContent = s.status || "exploring";
    document.title = `${s.name || "Whiteboard"} — Whiteboard`;
    versionEl.textContent = `v${(d.version || "").slice(0, 8)}`;
    notesEl.textContent = n.content || "(no notes yet)";
    // Only re-render when something actually changed, so an in-progress text
    // selection in the document is not blown away by no-op refreshes.
    if (needRender) { renderDoc(); renderThreads(); }
    lastCommentSig = sig;
    // Chat is cheap and stateless to refresh; history only when its tab is open
    // or the deliverable version changed (a new snapshot may have appeared).
    chat.refresh();
    if (state.tab === "history" || versionChanged) history.refresh();
    // Mark seen only when the comment set actually changed, to avoid a
    // .seen.json write -> fs.watch -> refresh feedback loop.
    if (sig !== seenMarkedFor) { seenMarkedFor = sig; markSeen(); }
  }

  function scheduleRefresh() {
    if (refreshInFlight) { refreshPending = true; return; }
    if (refreshTimer) return;
    refreshTimer = setTimeout(() => { refreshTimer = null; runRefresh(); }, 120);
  }
  async function runRefresh() {
    refreshInFlight = true;
    try { await refreshAll(); } finally { refreshInFlight = false; }
    if (refreshPending) { refreshPending = false; scheduleRefresh(); }
  }

  // ---- SSE ----
  function connectSSE() {
    const es = new EventSource(`${API}/events`);
    es.addEventListener("open", () => { connEl.textContent = "live"; connEl.classList.remove("bad"); });
    es.addEventListener("error", () => { connEl.textContent = "reconnecting…"; connEl.classList.add("bad"); });
    es.addEventListener("refresh", scheduleRefresh);
    return es;
  }

  gripEl.addEventListener("click", () => drawerEl.classList.toggle("open"));

  diffMarkReadEl.addEventListener("click", async () => {
    await fetch(`${API}/viewed`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ version: state.deliverable.version }) });
    state.viewedVersion = state.deliverable.version;
    state.diffMode = false;
    renderDoc();
  });

  runRefresh().then(connectSSE);
}