// W3C Web Annotation comments + agent attention markers: anchor top-level
// comments and highlighting annotations to document text, render them as margin
// notes positioned at their anchor's Y (sharing the document scroll), thread
// replies, and handle text-selection -> comment composition. Attention markers
// (motivation "highlighting", agent-authored) render as amber call-outs and can
// be dismissed (resolved).

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

const whoClass = (name) => (String(name || "").toLowerCase() === "agent" ? "agent" : "user");

const SANITIZE_OPTS = {
  USE_PROFILES: { html: true },
  ADD_ATTR: ["data-footnote-ref", "data-footnote-backref", "data-footnotes", "aria-describedby", "aria-label"],
};

function renderBody(text, renderMarkdown) {
  const raw = window.marked ? window.marked.parse(text || "") : esc(text);
  return window.DOMPurify ? window.DOMPurify.sanitize(raw, SANITIZE_OPTS) : raw;
}

// Whitespace-flexible quote matcher. The document's textContent preserves
// raw newlines and multi-space runs from block structure, but a stored
// TextQuoteSelector.exact comes from a browser selection (collapsed spaces) or
// from raw markdown. To re-anchor without mutating either side, we escape the
// query and turn each whitespace run into `\s+`, so "live demo doc for"
// matches "live demo\ndoc for". The returned index is a real offset into the
// unmodified haystack; nothing in the DOM or stored selector is changed.
function wsPattern(s) {
  return String(s ?? "")
    .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    .replace(/\s+/g, "\\s+");
}
export function quoteMatch(hay, exact, prefix, suffix) {
  if (!exact) return null;
  const e = wsPattern(exact);
  const s = suffix ? wsPattern(suffix) : "";
  let m;
  if (prefix) m = new RegExp("(" + wsPattern(prefix) + ")(" + e + ")" + s).exec(hay);
  else if (suffix) m = new RegExp("(" + e + ")(" + s + ")").exec(hay);
  else m = new RegExp("(" + e + ")").exec(hay);
  if (!m) return null;
  const pfx = prefix ? m[1].length : 0;
  const ex = prefix ? m[2] : m[1];
  return { start: m.index + pfx, end: m.index + pfx + ex.length };
}
export function quoteIndex(hay, exact, prefix, suffix) {
  const r = quoteMatch(hay, exact, prefix, suffix);
  return r ? r.start : -1;
}

export function initComments({ docEl, railEl, state, renderMarkdown, postComment, getVersion, onChange, onToggleResolve }) {
  const isAttention = (a) => a && a.motivation === "highlighting";
  const isTopLevel = (a) => a && a.motivation !== "replying" && !(a.target && a.target.id) && !isAttention(a);
  const topLevel = () => state.annotations.filter(isTopLevel);
  const attentionItems = () => state.annotations.filter(isAttention);
  const repliesOf = (pid) => state.annotations
    .filter((a) => a.motivation === "replying" && a.target && a.target.id === pid)
    .sort((a, b) => (a.created || "").localeCompare(b.created || ""));
  const excerptOf = (a) => {
    const tq = ((a.target && a.target.selector) || []).find((s) => s.type === "TextQuoteSelector");
    return tq ? tq.exact : "";
  };

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
  function wrapRangeByOffsets(rootNode, start, end, annoId, cls) {
    if (start < 0 || end <= start) return false;
    const map = cumulativeOffsets(rootNode);
    const si = map.findIndex((m) => start >= m.start && start < m.end);
    const ei = map.findIndex((m) => end > m.start && end <= m.end);
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
      mark.className = cls || "wb-anno";
      mark.dataset.annoId = annoId;
      tn.parentNode.insertBefore(mark, tn);
      mark.appendChild(tn);
    }
    return true;
  }

  function anchorOne(a, cls) {
    const sel = (a.target && a.target.selector) || [];
    const tq = sel.find((s) => s.type === "TextQuoteSelector");
    const tp = sel.find((s) => s.type === "TextPositionSelector");
    let start = -1, end = -1;
    if (tq) { const r = quoteMatch(docEl.textContent, tq.exact, tq.prefix, tq.suffix); if (r) { start = r.start; end = r.end; } }
    if (start === -1 && tp) { start = tp.start; end = tp.end; }
    if (start === -1) { a._anchored = false; a._start = -1; return; }
    const id = a.id.split(":").pop();
    a._anchored = wrapRangeByOffsets(docEl, start, end, id, cls);
    a._start = a._anchored ? start : -1;
  }

  function anchor() {
    for (const a of topLevel()) anchorOne(a, "wb-anno");
    for (const a of attentionItems()) anchorOne(a, "wb-attention");
  }

  function renderMsg(a) {
    const div = document.createElement("div");
    div.className = "msg";
    const who = (a.creator && a.creator.name) || "user";
    const when = (a.created || "").replace("T", " ").slice(0, 16);
    div.innerHTML = `<span class="who ${whoClass(who)}">${esc(who)}</span><span class="when">${esc(when)}</span><div class="body">${renderBody(a.body && a.body.value, renderMarkdown)}</div>`;
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
    railEl.querySelectorAll(".thread").forEach((c) => c.classList.toggle("active", c.dataset.annoId === id));
    docEl.querySelectorAll("mark.wb-anno, mark.wb-attention").forEach((m) => m.classList.toggle("active", m.dataset.annoId === id));
    const mark = docEl.querySelector(`mark.wb-attention[data-anno-id="${id}"], mark.wb-anno[data-anno-id="${id}"]`);
    if (mark) mark.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  function wireResolve(card, id, isResolved) {
    const btn = card.querySelector(".resolve-btn");
    if (btn && onToggleResolve) btn.addEventListener("click", (e) => { e.stopPropagation(); onToggleResolve(id, !isResolved); });
  }

  // Render margin notes: comments + agent attention markers, sorted by anchor Y,
  // positioned with simple collision stacking so clustered cards cascade.
  function render() {
    const items = topLevel().concat(attentionItems()).slice().sort((a, b) => {
      const pa = a._start ?? Infinity, pb = b._start ?? Infinity;
      return pa !== pb ? pa - pb : (a.created || "").localeCompare(b.created || "");
    });
    railEl.innerHTML = "";
    if (onChange) onChange(topLevel().length);
    if (items.length === 0) return;
    let lastBottom = -8;
    for (const a of items) {
      const id = a.id.split(":").pop();
      const att = isAttention(a);
      const mark = docEl.querySelector(att ? `mark.wb-attention[data-anno-id="${id}"]` : `mark.wb-anno[data-anno-id="${id}"]`);
      const anchorY = mark ? mark.offsetTop : (a._start ?? 0);
      const isResolved = state.resolved.has(a.id);
      const ver = (a.target && a.target.version ? a.target.version : "—").slice(0, 8);
      const where = a._anchored === false ? `not found @ ${ver}` : `@ ${ver}`;
      const card = document.createElement("div");
      card.className = "thread" + (att ? " attention" : "") + (a._anchored === false ? " orphaned" : "") + (state.activeId === id ? " active" : "") + (isResolved ? " resolved" : "");
      card.dataset.annoId = id;
      if (att) {
        const reason = (a.body && a.body.value) || "Needs your attention.";
        card.innerHTML = `<div class="att-head"><span class="att-flag">⚑</span><span class="where">${esc(where)}</span></div><div class="att-reason">${renderBody(reason, renderMarkdown)}</div><div class="reply-box"><div class="row"><button class="resolve-btn" type="button" title="${isResolved ? "Unresolve" : "Dismiss"}">${isResolved ? "↺ dismissed" : "✓ dismiss"}</button></div></div>`;
      } else {
        const ex = excerptOf(a);
        card.innerHTML = `<div class="excerpt">${esc(ex.slice(0, 120))}${ex.length > 120 ? "…" : ""}<span class="where">${esc(where)}</span></div><div class="msg-list"></div><div class="reply-box"><textarea placeholder="Reply…"></textarea><div class="row"><button class="cancel">cancel</button><button class="send" disabled>Reply</button><button class="resolve-btn" type="button" title="${isResolved ? "Unresolve" : "Mark resolved"}">${isResolved ? "↺ resolved" : "✓ resolve"}</button></div></div>`;
        const list = card.querySelector(".msg-list");
        list.appendChild(renderMsg(a));
        for (const r of repliesOf(a.id)) list.appendChild(renderMsg(r));
        wireReply(card, a);
      }
      wireResolve(card, a.id, isResolved);
      card.addEventListener("click", (e) => { if (e.target.closest(".reply-box")) return; setActive(id); });
      railEl.appendChild(card);
      const naturalTop = Math.max(anchorY, lastBottom + 8);
      card.style.top = `${naturalTop}px`;
      lastBottom = naturalTop + card.offsetHeight;
    }
  }

  docEl.addEventListener("click", (e) => {
    const m = e.target.closest("mark.wb-anno, mark.wb-attention");
    if (m) setActive(m.dataset.annoId);
  });

  // ---- selection -> comment (FAB + composer) ----
  let fab = null;
  const removeFab = () => { if (fab) { fab.remove(); fab = null; } };
  document.addEventListener("mouseup", () => setTimeout(positionFab, 0));
  document.addEventListener("keyup", (e) => { if (e.key === "Escape") { removeFab(); closeComposer(); } });

  function positionFab() {
    removeFab();
    if (state.diffMode) return;
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

  let composer = null;
  function closeComposer() { if (composer) { composer.remove(); composer = null; } try { window.getSelection().removeAllRanges(); } catch {} }
  function openComposer(range, sel) {
    closeComposer();
    const selector = selectorsFor(range, sel);
    const rect = range.getBoundingClientRect();
    composer = document.createElement("div");
    composer.className = "composer";
    composer.style.left = `${rect.left + window.scrollX}px`;
    composer.style.top = `${rect.top + window.scrollY - 6}px`;
    composer.innerHTML = `<textarea placeholder="Why is this?…"></textarea><div class="row"><button class="cancel">Cancel</button><button class="send" disabled>Comment</button></div>`;
    document.body.appendChild(composer);
    const ta = composer.querySelector("textarea"), send = composer.querySelector(".send"), cancel = composer.querySelector(".cancel");
    ta.focus();
    ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });
    cancel.addEventListener("click", closeComposer);
    send.addEventListener("click", async () => {
      const text = ta.value.trim();
      if (!text) return;
      send.disabled = true;
      await postComment({ text, selector, version: getVersion(), creator: "user" });
      closeComposer();
    });
  }

  return { anchor, render, setActive, clear: () => { railEl.innerHTML = ""; } };
}