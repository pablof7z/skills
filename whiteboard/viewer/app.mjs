// Whiteboard viewer client. Renders the session deliverable as markdown, anchors
// W3C Web Annotation comments to the document text at the version they were made
// against, and keeps everything live via SSE filesystem events from the server.

const $ = (id) => document.getElementById(id);
const docEl = $("doc");
const threadsEl = $("threads");
const countEl = $("count");
const titleEl = $("title");
const statusEl = $("status");
const versionEl = $("version");
const connEl = $("conn");
const notesEl = $("notes");
const drawerEl = $("notes-drawer");
const gripEl = $("notes-grip");

const state = {
  session: null,
  deliverable: { content: "", version: "" },
  notes: "",
  annotations: [],
  activeId: null,
  tab: "all",
};

// ---------- markdown ----------

function renderMarkdown(md) {
  const raw = window.marked ? window.marked.parse(md || "") : (md || "");
  const clean = window.DOMPurify
    ? window.DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } })
    : raw;
  return clean;
}

function renderDoc() {
  docEl.innerHTML = renderMarkdown(state.deliverable.content);
  anchorAll();
}

// ---------- text-node offset mapping ----------

function textNodes(root) {
  const out = [];
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let n;
  while ((n = w.nextNode())) {
    // skip content inside our own marks? marks contain real text we want to anchor to
    out.push(n);
  }
  return out;
}

function cumulativeOffsets(root) {
  const nodes = textNodes(root);
  let cum = 0;
  return nodes.map((n) => {
    const start = cum;
    cum += n.nodeValue.length;
    return { node: n, start, end: cum };
  });
}

function offsetOf(root, targetNode, targetOffset) {
  const map = cumulativeOffsets(root);
  for (const { node, start } of map) {
    if (node === targetNode) return start + targetOffset;
  }
  // target may be an element (e.g. selection anchored on a block); approximate
  // by walking to the first text node at or after it.
  return -1;
}

// ---------- anchoring ----------

function quoteIndex(haystack, exact, prefix, suffix) {
  if (!exact) return -1;
  if (prefix && suffix) {
    const full = prefix + exact + suffix;
    const i = haystack.indexOf(full);
    if (i !== -1) return i + prefix.length;
  }
  if (prefix) {
    const i = haystack.indexOf(prefix + exact);
    if (i !== -1) return i + prefix.length;
  }
  if (suffix) {
    const i = haystack.indexOf(exact + suffix);
    if (i !== -1) return i;
  }
  return haystack.indexOf(exact);
}

// Wrap a [start,end] char range in #doc with <mark data-anno-id>. Returns true on success.
function wrapRangeByOffsets(root, start, end, annoId) {
  if (start < 0 || end <= start) return false;
  const map = cumulativeOffsets(root);
  // find node containing start
  let si = map.findIndex((m) => start >= m.start && start < m.end);
  let ei = map.findIndex((m) => end > m.start && end <= m.end);
  if (si === -1 || ei === -1) return false;
  // split at start
  const startNode = map[si].node;
  const relStart = start - map[si].start;
  if (relStart > 0) startNode.splitText(relStart);
  // after split, the tail node holds the remainder
  const startTail = relStart > 0 ? startNode.nextSibling : startNode;
  // recompute end node position relative to startTail
  // find end within the document again (offsets in textContent are unchanged)
  const map2 = cumulativeOffsets(root);
  const endEntry = map2.find((m) => end > m.start && end <= m.end);
  if (!endEntry) return false;
  const relEnd = end - endEntry.start;
  if (relEnd > 0 && relEnd < endEntry.node.nodeValue.length) endEntry.node.splitText(relEnd);
  // collect text nodes between startTail and the end node (inclusive)
  const wrapped = [];
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  let cur = w.nextNode();
  let collecting = false;
  while (cur) {
    if (cur === startTail) collecting = true;
    if (collecting) {
      wrapped.push(cur);
      if (cur === endEntry.node || (relEnd > 0 && cur === endEntry.node)) break;
    }
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

function anchorAll() {
  const fullText = docEl.textContent;
  for (const a of topLevel()) {
    const sel = (a.target && a.target.selector) || [];
    const tq = sel.find((s) => s.type === "TextQuoteSelector");
    const tp = sel.find((s) => s.type === "TextPositionSelector");
    let start = -1;
    if (tq) start = quoteIndex(fullText, tq.exact, tq.prefix, tq.suffix);
    if (start === -1 && tp) start = tp.start;
    let end = start === -1 ? -1 : start + ((tq && tq.exact ? tq.exact.length : (tp ? tp.end - tp.start : 0)));
    if (start === -1) { a._anchored = false; continue; }
    const id = a.id.split(":").pop();
    a._anchored = wrapRangeByOffsets(docEl, start, end, id);
    a._start = a._anchored ? start : -1;
  }
}

// ---------- annotation helpers ----------

const isTopLevel = (a) => a && a.motivation !== "replying" && !(a.target && a.target.id);
const topLevel = () => state.annotations.filter(isTopLevel);
const repliesOf = (parentId) =>
  state.annotations
    .filter((a) => a.motivation === "replying" && a.target && a.target.id === parentId)
    .sort((a, b) => (a.created || "").localeCompare(b.created || ""));

function excerptOf(a) {
  const sel = (a.target && a.target.selector) || [];
  const tq = sel.find((s) => s.type === "TextQuoteSelector");
  return tq ? tq.exact : "";
}

// ---------- sidebar ----------

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function renderBody(text) {
  // small markdown subset, sanitized
  const raw = window.marked ? window.marked.parse(text || "") : esc(text);
  return window.DOMPurify ? window.DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } }) : raw;
}

function whoClass(name) {
  const n = String(name || "").toLowerCase();
  if (n === "agent") return "agent";
  return "user";
}

function renderThreads() {
  const items = topLevel().slice();
  items.sort((a, b) => {
    const pa = a._start ?? Infinity;
    const pb = b._start ?? Infinity;
    if (pa !== pb) return pa - pb;
    return (a.created || "").localeCompare(b.created || "");
  });

  const shown = state.tab === "open" ? items : items;
  countEl.textContent = String(shown.length);

  if (shown.length === 0) {
    threadsEl.innerHTML = `<div class="empty">Select text in the document to add a comment.</div>`;
    return;
  }

  threadsEl.innerHTML = "";
  for (const a of shown) {
    const id = a.id.split(":").pop();
    const card = document.createElement("div");
    card.className = "thread" + (a._anchored === false ? " orphaned" : "") + (state.activeId === id ? " active" : "");
    card.dataset.annoId = id;

    const ex = excerptOf(a);
    const ver = a.target && a.target.version ? a.target.version.slice(0, 8) : "—";
    const where = a._anchored === false
      ? `not found in current doc (made @ ${ver})`
      : `@ ${ver}`;
    card.innerHTML = `
      <div class="excerpt">${esc(ex.slice(0, 160))}${ex.length > 160 ? "…" : ""}<span class="where">${esc(where)}</span></div>
      <div class="msg-list"></div>
      <div class="reply-box">
        <textarea placeholder="Reply…"></textarea>
        <div class="row">
          <button class="cancel">cancel</button>
          <button class="send" disabled>Reply</button>
        </div>
      </div>`;

    const list = card.querySelector(".msg-list");
    list.appendChild(renderMsg(a));
    for (const r of repliesOf(a.id)) list.appendChild(renderMsg(r));

    wireReply(card, a);
    card.addEventListener("click", (e) => {
      if (e.target.closest(".reply-box")) return;
      setActive(id);
    });
    threadsEl.appendChild(card);
  }
}

function renderMsg(a) {
  const div = document.createElement("div");
  div.className = "msg";
  const who = (a.creator && a.creator.name) || "user";
  const when = (a.created || "").replace("T", " ").slice(0, 16);
  div.innerHTML = `
    <span class="who ${whoClass(who)}">${esc(who)}</span>
    <span class="when">${esc(when)}</span>
    <div class="body">${renderBody(a.body && a.body.value)}</div>`;
  return div;
}

function wireReply(card, parent) {
  const ta = card.querySelector("textarea");
  const send = card.querySelector(".send");
  const cancel = card.querySelector(".cancel");
  const onInput = () => { send.disabled = ta.value.trim().length === 0; };
  ta.addEventListener("input", onInput);
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
  if (mark) {
    mark.scrollIntoView({ behavior: "smooth", block: "center" });
  } else {
    const card = document.querySelector(`.thread[data-anno-id="${id}"]`);
    if (card) card.scrollIntoView({ behavior: "smooth", block: "center" });
  }
}

docEl.addEventListener("click", (e) => {
  const m = e.target.closest("mark.wb-anno");
  if (m) setActive(m.dataset.annoId);
});

// ---------- selection -> comment ----------

let fab = null;

document.addEventListener("mouseup", () => {
  setTimeout(positionFab, 0);
});
document.addEventListener("keyup", (e) => {
  if (e.key === "Escape") removeFab();
});

function removeFab() {
  if (fab) { fab.remove(); fab = null; }
}

function positionFab() {
  removeFab();
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
  const fullText = docEl.textContent;
  let start = offsetOf(docEl, range.startContainer, range.startOffset);
  let end = offsetOf(docEl, range.endContainer, range.endOffset);
  const exact = sel.toString();
  // Fallback when the selection is anchored on an element (e.g. triple-click):
  // locate the exact text directly so prefix/suffix still get captured.
  if (start === -1 && exact) start = fullText.indexOf(exact);
  if (end === -1 && start >= 0) end = start + exact.length;
  const prefix = start > 0 ? fullText.slice(Math.max(0, start - 32), start) : "";
  const suffix = end >= 0 && end < fullText.length ? fullText.slice(end, end + 32) : "";
  const selector = [{ type: "TextQuoteSelector", exact, prefix, suffix }];
  if (start >= 0 && end > start) selector.push({ type: "TextPositionSelector", start, end });
  return selector;
}

function openComposer(range, sel) {
  const selector = selectorsFor(range, sel);
  const rect = range.getBoundingClientRect();
  const box = document.createElement("div");
  box.style.cssText = `position:absolute;z-index:60;left:${rect.left + window.scrollX}px;top:${rect.top + window.scrollY - 6}px;background:#fff;border:1px solid var(--line);border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,0.18);padding:10px;width:300px;`;
  box.innerHTML = `
    <textarea placeholder="Why is this?…" style="width:100%;min-height:70px;font:inherit;font-size:13.5px;padding:7px;border:1px solid var(--line);border-radius:8px;"></textarea>
    <div style="display:flex;gap:6px;margin-top:6px;justify-content:flex-end;">
      <button class="cancel" style="background:#f0f0ee;border:none;border-radius:7px;padding:5px 10px;cursor:pointer;">Cancel</button>
      <button class="send" style="background:var(--accent);color:#fff;border:none;border-radius:7px;padding:5px 10px;cursor:pointer;" disabled>Comment</button>
    </div>`;
  document.body.appendChild(box);
  const ta = box.querySelector("textarea");
  const send = box.querySelector(".send");
  const cancel = box.querySelector(".cancel");
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

// ---------- API ----------

async function getJSON(p) {
  const r = await fetch(p);
  return r.json();
}

async function postComment(payload) {
  await fetch("/api/comments", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  // SSE will refresh; but refresh immediately too for snappy feel
  await refreshComments();
}

async function refreshAll() {
  const [s, d, n, c] = await Promise.all([
    getJSON("/api/session"),
    getJSON("/api/deliverable"),
    getJSON("/api/notes"),
    getJSON("/api/comments"),
  ]);
  state.session = s;
  state.deliverable = d;
  state.notes = n.content;
  state.annotations = c.annotations || [];
  titleEl.textContent = s.name || "Whiteboard";
  statusEl.textContent = s.status || "exploring";
  versionEl.textContent = `v${(d.version || "").slice(0, 8)}`;
  notesEl.textContent = n.content || "(no notes yet)";
  renderDoc();
  renderThreads();
}

async function refreshDeliverable() {
  const d = await getJSON("/api/deliverable");
  state.deliverable = d;
  versionEl.textContent = `v${(d.version || "").slice(0, 8)}`;
  renderDoc();
  renderThreads();
}

async function refreshComments() {
  const c = await getJSON("/api/comments");
  state.annotations = c.annotations || [];
  renderDoc();
  renderThreads();
}

async function refreshNotes() {
  const n = await getJSON("/api/notes");
  state.notes = n.content;
  notesEl.textContent = n.content || "(no notes yet)";
}

// ---------- SSE ----------

function connectSSE() {
  const es = new EventSource("/api/events");
  es.addEventListener("open", () => { connEl.textContent = "live"; connEl.classList.remove("bad"); });
  es.addEventListener("error", () => { connEl.textContent = "reconnecting…"; connEl.classList.add("bad"); });
  es.addEventListener("deliverable", () => refreshDeliverable());
  es.addEventListener("notes", () => refreshNotes());
  es.addEventListener("comments", () => refreshComments());
  return es;
}

// ---------- tabs + notes drawer ----------

document.querySelectorAll(".side-head .tab").forEach((t) => {
  t.addEventListener("click", () => {
    document.querySelectorAll(".side-head .tab").forEach((x) => x.classList.remove("active"));
    t.classList.add("active");
    state.tab = t.dataset.tab;
    renderThreads();
  });
});

gripEl.addEventListener("click", () => drawerEl.classList.toggle("open"));

// ---------- boot ---------- (awaiting top-level await)

await refreshAll();
connectSSE();