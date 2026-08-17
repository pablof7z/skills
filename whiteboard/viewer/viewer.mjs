// Whiteboard session viewer. Renders one session's deliverable.md, shows
// comments as margin notes anchored to the document text, threads replies, and
// keeps live via SSE. Overlays: floating TOC + minimap + change bars (nav.mjs),
// syntax highlighting + Mermaid (codeblocks.mjs). Sidebar holds Chat and History.

import { initChat } from "./chat.mjs";
import { initHistory } from "./history.mjs";
import { initCodeBlocks } from "./codeblocks.mjs";
import { initComments } from "./comments.mjs";
import { initNav } from "./nav.mjs";
import { renderDocDiff } from "./docdiff.mjs";

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
          <div class="doc-wrap" id="doc-wrap">
            <article id="doc"></article>
            <div class="margin-rail" id="margin-rail" aria-label="Comments"></div>
          </div>
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
        <div class="side-scroll" id="comments-panel"><div class="empty">Comments float beside the document at the position they were made. Select text in the document to add one.</div></div>
        <div class="side-scroll" id="chat-panel" hidden></div>
        <div class="side-scroll" id="history-panel" hidden></div>
      </aside>
    </div>
    <div class="notes-drawer" id="notes-drawer">
      <div class="grip" id="notes-grip">▾ Notes log</div>
      <pre id="notes"></pre>
    </div>`;

  const docEl = document.getElementById("doc");
  const docScroll = document.getElementById("doc-scroll");
  const docWrap = document.getElementById("doc-wrap");
  const railEl = document.getElementById("margin-rail");
  const commentsPanel = document.getElementById("comments-panel");
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

  const codeblocks = initCodeBlocks();
  const comments = initComments({ docEl, railEl, state, renderMarkdown, postComment, getVersion: () => state.deliverable.version, onChange: (n) => { countEl.textContent = String(n); } });
  const nav = initNav({ docScroll, docEl, state });
  const chat = initChat(chatPanelEl, API);
  const history = initHistory(historyPanelEl, API);

  function setTab(tab) {
    state.tab = tab;
    document.querySelectorAll(".side-head .tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === tab));
    commentsPanel.hidden = tab !== "comments";
    chatPanelEl.hidden = tab !== "chat";
    historyPanelEl.hidden = tab !== "history";
    // Margin notes share the document scroll; show them only for the Comments tab.
    docWrap.classList.toggle("comments-on", tab === "comments");
    if (tab === "chat") chat.refresh().then(() => chat.focus && chat.focus());
    if (tab === "history") history.refresh();
    nav.refresh();
  }
  document.querySelectorAll(".side-head .tab").forEach((t) => t.addEventListener("click", () => setTab(t.dataset.tab)));

  async function renderDoc() {
    if (state.diffMode) {
      docEl.innerHTML = renderDocDiff(state.oldViewedContent, state.deliverable.content, renderMarkdown);
      diffBannerEl.hidden = false;
      diffBannerTextEl.textContent = `Changes since v${(state.viewedVersion || "").slice(0, 8)} → v${(state.deliverable.version || "").slice(0, 8)}`;
    } else {
      docEl.innerHTML = renderMarkdown(state.deliverable.content);
      diffBannerEl.hidden = true;
      comments.anchor();
    }
    await codeblocks.enhance(docEl);
    comments.render();
    nav.refresh();
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

    const viewed = s.viewedVersion || null;
    if (viewed === null) {
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
    if (needRender) { await renderDoc(); }
    lastCommentSig = sig;
    chat.refresh();
    if (state.tab === "history" || versionChanged) history.refresh();
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
    await renderDoc();
  });

  setTab("comments");
  runRefresh().then(connectSSE);
}