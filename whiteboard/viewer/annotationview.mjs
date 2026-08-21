import { styleOf } from "./annotations.mjs";
import { relativeTop } from "./comments.mjs";
import { ago } from "./blockdiff.mjs";
import { blockKey, DEFAULT_PATH } from "./continuity.mjs";

const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[char]));
const managed = (node, key) => { node.dataset.liveKey = key; return node; };
const interacting = (node) => !!node && (node.contains(document.activeElement) || !!node.querySelector("textarea")?.value.trim());
export const threadIsPinned = (state, item, node) => state.activeId === item.id || interacting(node);

function syncChildren(parent, desired, before = null) {
  const keep = new Set(desired);
  for (const node of [...parent.children]) {
    if (node.dataset.liveKey && !keep.has(node)) node.remove();
  }
  const current = [...parent.children].filter((node) => node.dataset.liveKey);
  if (current.length === desired.length && current.every((node, index) => node === desired[index])) return;
  let cursor = parent.firstElementChild;
  for (const node of desired) {
    while (cursor && !cursor.dataset.liveKey) cursor = cursor.nextElementSibling;
    if (node !== cursor) parent.insertBefore(node, cursor || before);
    cursor = node.nextElementSibling;
  }
}

export function createAnnotationView({
  API, state, railEl, drawerScrollEl, commentsToggleEl, countEl, docEl,
  renderBody, refresh, updateEdges,
}) {
  const nodes = new Map();
  const getNode = (key, create) => {
    if (!nodes.has(key)) nodes.set(key, managed(create(), key));
    return nodes.get(key);
  };
  const blocks = () => state.displayBlocks || [];
  const annotationsOn = (block) => (state.displayDoc?.annotations || []).filter((annotation) =>
    annotation.block === block.name && (annotation.path || DEFAULT_PATH) === (block.path || DEFAULT_PATH));
  const hasAgentVoice = (item) => item.author === "agent" || item.replies?.some((reply) => reply.author === "agent");
  const awaitsUser = (item) => item.isTag
    ? item.state === "active" && ["needs-attention", "unverified"].includes(item.kind)
    : !state.resolved.has(item.id) && hasAgentVoice(item) && !item.replies?.some((reply) => reply.author === "user");
  const whoClass = (name) => String(name || "").toLowerCase() === "agent" ? "agent" : "user";

  function syncReplies(card, replies) {
    const parent = card.querySelector(".reply-messages");
    const old = new Map([...parent.children].map((node) => [node.dataset.replyKey, node]));
    const desired = replies.map((reply, index) => {
      const key = String(reply.id || `${reply.at}\u0000${reply.author}\u0000${reply.body}\u0000${index}`);
      const node = old.get(key) || document.createElement("div");
      node.className = "msg"; node.dataset.replyKey = key; node.dataset.liveKey = `reply:${key}`;
      const signature = JSON.stringify([reply.author, reply.at, reply.body]);
      if (node.dataset.signature !== signature) {
        node.innerHTML = `<span class="who ${whoClass(reply.author)}">${esc(reply.author)}</span><span class="when" data-at="${esc(reply.at)}">${ago(reply.at)}</span><div class="body">${renderBody(reply.body)}</div>`;
        node.dataset.signature = signature;
      }
      return node;
    });
    syncChildren(parent, desired);
  }

  function createThread() {
    const card = document.createElement("div");
    card.innerHTML = `<div class="excerpt"></div><div class="msg root-message"></div><div class="reply-messages"></div><div class="reply-box"><textarea placeholder="Reply…"></textarea><div class="row"><button class="resolve-btn" type="button"></button><button class="cancel">cancel</button><button class="send" disabled>Reply</button></div></div>`;
    const textarea = card.querySelector("textarea"), send = card.querySelector(".send");
    textarea.addEventListener("input", () => { send.disabled = !textarea.value.trim(); });
    textarea.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") { event.preventDefault(); send.click(); }
    });
    card.querySelector(".cancel").addEventListener("click", () => { textarea.value = ""; send.disabled = true; });
    send.addEventListener("click", async () => {
      const text = textarea.value.trim(), data = card._liveData;
      if (!text || !data) return;
      send.disabled = true;
      await fetch(`${API}/comments`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ block: data.block.name, path: data.block.path, text, creator: "user", replyTo: data.item.id }) });
      textarea.value = ""; await refresh();
    });
    card.querySelector(".resolve-btn").addEventListener("click", async (event) => {
      event.stopPropagation(); const data = card._liveData; if (!data) return;
      await fetch(`${API}/resolved`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: data.item.id, resolved: !data.resolved, by: "user" }) });
      await refresh();
    });
    card.addEventListener("click", (event) => {
      if (event.target.closest(".reply-box, .collapse-btn")) return;
      state.activeId = card._liveData?.item.id || null;
      document.querySelectorAll(".thread[data-anno-id]").forEach((thread) => thread.classList.toggle("active", thread === card));
    });
    return card;
  }

  function threadNode(block, item, resolved) {
    const card = getNode(`thread:${item.id}`, createThread);
    card._liveData = { block, item, resolved };
    card.dataset.annoId = item.id;
    card.className = `thread ${styleOf(item.kind).cls}${resolved ? " is-resolved" : ""}${state.activeId === item.id ? " active" : ""}${state.collapsed[item.id] ? " collapsed" : ""}${!resolved && awaitsUser(item) ? " awaits-user" : ""}`;
    const hasSelection = !!item.selector?.exact;
    const showQuote = hasSelection && !state.anchored[item.id];
    const stale = hasSelection && state.anchored[item.id] === false;
    const quote = showQuote ? `<span class="excerpt-quote${stale ? " stale" : ""}"${stale ? ' title="Unanchored: the saved context no longer matches this block"' : ""}>${stale ? "Unanchored: " : ""}“${esc(item.selector.exact)}”</span>` : "";
    const style = styleOf(item.kind);
    card.querySelector(".excerpt").innerHTML = `<button class="collapse-btn" type="button" title="${state.collapsed[item.id] ? "Expand" : "Collapse"}">${state.collapsed[item.id] ? "▸" : "▾"}</button><span class="kind-badge ${style.cls}" title="${esc(style.label)}">${style.icon}</span>${quote}<span class="where" data-at="${esc(item.at)}">${ago(item.at)}</span>`;
    card.querySelector(".collapse-btn").onclick = (event) => { event.stopPropagation(); state.collapsed[item.id] = !state.collapsed[item.id]; render(); };
    const root = card.querySelector(".root-message");
    const rootSignature = JSON.stringify([item.author, item.body]);
    if (root.dataset.signature !== rootSignature) {
      root.innerHTML = `<span class="who ${whoClass(item.author)}">${esc(item.author)}</span><div class="body">${renderBody(item.body)}</div>`;
      root.dataset.signature = rootSignature;
    }
    syncReplies(card, item.replies || []);
    const button = card.querySelector(".resolve-btn");
    button.title = resolved ? "Unresolve" : "Resolve"; button.textContent = resolved ? "↺ resolved" : "✓ resolve";
    return card;
  }

  function tagNode(item) {
    const node = getNode(`tag:${item.id}`, () => document.createElement("div"));
    const style = styleOf(item.kind);
    node.className = `wb-tag ${style.cls}${awaitsUser(item) ? " awaits-user" : ""}`;
    node.dataset.annoId = item.id; node.title = item.body ? `${style.label} — ${item.body}` : style.label;
    node.innerHTML = `<span class="tag-icon">${style.icon}</span><span class="tag-label">${esc(style.label)}</span>${item.body ? `<span class="tag-body">${esc(item.body)}</span>` : ""}`;
    return node;
  }

  function pillNode(block, count, expanded) {
    const key = blockKey(block);
    const pill = getNode(`pill:${key}`, () => document.createElement("div"));
    pill.className = `resolved-pill${expanded ? " expanded" : ""}`;
    pill.textContent = `${count} resolved ${expanded ? "▾" : "▸"}`;
    pill.title = expanded ? "Hide resolved" : "Show resolved";
    pill.onclick = () => { state.showResolved[key] = !expanded; render(); };
    return pill;
  }

  function sectionFor(block) {
    return [...docEl.querySelectorAll(":scope > section[data-block-key]")]
      .find((section) => section.dataset.blockKey === blockKey(block));
  }
  function anchorTop(section, item) {
    if (state.anchored[item.id]) {
      const mark = [...section.querySelectorAll("mark.wb-anno")].find((node) => node.dataset.annoId === item.id);
      if (mark) return relativeTop(mark, railEl);
    }
    return relativeTop(section, railEl);
  }

  function renderRail() {
    commentsToggleEl.hidden = true;
    const specs = [];
    for (const block of blocks()) {
      const section = sectionFor(block); if (!section) continue;
      const all = annotationsOn(block), blockTop = relativeTop(section, railEl);
      const tags = all.filter((item) => item.isTag);
      const threads = all.filter((item) => !item.isTag);
      const open = threads.filter((item) => !state.resolved.has(item.id));
      const resolved = threads.filter((item) => state.resolved.has(item.id));
      for (const item of tags) specs.push({ node: tagNode(item), top: blockTop });
      for (const item of open) specs.push({ node: threadNode(block, item, false), top: anchorTop(section, item) });
      if (resolved.length) {
        const expanded = !!state.showResolved[blockKey(block)];
        const pinned = resolved.filter((item) => threadIsPinned(state, item, nodes.get(`thread:${item.id}`)));
        for (const item of pinned) specs.push({ node: threadNode(block, item, true), top: blockTop });
        specs.push({ node: pillNode(block, resolved.length, expanded), top: blockTop });
        for (const item of resolved) {
          const existing = nodes.get(`thread:${item.id}`);
          if (!pinned.includes(item) && expanded) specs.push({ node: threadNode(block, item, true), top: blockTop });
        }
      }
    }
    const composer = railEl.querySelector(":scope > .composer");
    syncChildren(railEl, specs.map(({ node }) => node), composer);
    syncChildren(drawerScrollEl, []);
    let bottom = -8;
    for (const spec of specs) {
      const top = Math.max(spec.top, bottom + 8); spec.node.style.top = `${top}px`; bottom = top + spec.node.offsetHeight;
    }
    updateEdges();
  }

  function renderDrawer() {
    const desired = []; let count = 0;
    for (const block of blocks()) {
      const all = annotationsOn(block); if (!all.length) continue;
      const key = blockKey(block);
      const head = getNode(`head:${key}`, () => document.createElement("div"));
      head.className = "drawer-block-head"; head.textContent = block.name; desired.push(head);
      const tags = all.filter((item) => item.isTag);
      const threads = all.filter((item) => !item.isTag);
      const open = threads.filter((item) => !state.resolved.has(item.id));
      const resolved = threads.filter((item) => state.resolved.has(item.id));
      for (const item of tags) desired.push(tagNode(item));
      for (const item of open) { desired.push(threadNode(block, item, false)); count++; }
      if (resolved.length) {
        const expanded = !!state.showResolved[key];
        const pinned = resolved.filter((item) => threadIsPinned(state, item, nodes.get(`thread:${item.id}`)));
        for (const item of pinned) { desired.push(threadNode(block, item, true)); count++; }
        desired.push(pillNode(block, resolved.length, expanded));
        for (const item of resolved) {
          if (!pinned.includes(item) && expanded) { desired.push(threadNode(block, item, true)); count++; }
        }
      }
    }
    syncChildren(drawerScrollEl, desired);
    syncChildren(railEl, [], railEl.querySelector(":scope > .composer"));
    if (!desired.length) {
      const empty = getNode("empty", () => document.createElement("div"));
      empty.className = "drawer-empty"; empty.textContent = "No annotations."; syncChildren(drawerScrollEl, [empty]);
    }
    countEl.textContent = String(count); commentsToggleEl.hidden = false; updateEdges();
  }

  function render() { state.narrow ? renderDrawer() : renderRail(); }
  function updateTimes() {
    const root = state.narrow ? drawerScrollEl : railEl;
    root.querySelectorAll("[data-at]").forEach((node) => { node.textContent = ago(node.dataset.at); });
  }
  return { render, updateTimes };
}
