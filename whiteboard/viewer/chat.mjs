// Whiteboard chat panel. A file-queue chat the human uses from the webapp;
// messages land in <session>/chat/ and (without the pi extension) are drained
// by wait-for-comment.mjs, which wakes the agent. The agent writes reply files
// into the same dir; they render here live.

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

function renderBody(text) {
  const raw = window.marked ? window.marked.parse(text || "") : esc(text);
  return window.DOMPurify ? window.DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } }) : raw;
}

export function initChat(container, API) {
  container.innerHTML = `
    <div class="chat-list" id="chat-list"></div>
    <div class="chat-input">
      <textarea id="chat-text" placeholder="Message the agent… (Enter to send, Shift+Enter for newline)"></textarea>
      <button id="chat-send" disabled>Send</button>
    </div>`;

  const listEl = container.querySelector("#chat-list");
  const ta = container.querySelector("#chat-text");
  const send = container.querySelector("#chat-send");
  let messages = [];

  ta.addEventListener("input", () => { send.disabled = ta.value.trim().length === 0; });

  function render() {
    if (messages.length === 0) {
      listEl.innerHTML = `<div class="empty">Chat with the agent. Your message is queued for the agent; replies appear here.</div>`;
      return;
    }
    listEl.innerHTML = "";
    for (const m of messages) {
      const div = document.createElement("div");
      div.className = `chat-msg ${m.role}`;
      const when = (m.created || "").replace("T", " ").slice(0, 16);
      div.innerHTML = `<span class="who ${m.role}">${esc(m.role)}</span><span class="when">${esc(when)}</span><div class="body">${renderBody(m.text)}</div>`;
      listEl.appendChild(div);
    }
    listEl.scrollTop = listEl.scrollHeight;
  }

  async function refresh() {
    try {
      const r = await fetch(`${API}/chat`);
      const d = await r.json();
      messages = d.messages || [];
      render();
    } catch {}
  }

  async function sendMsg() {
    const text = ta.value.trim();
    if (!text) return;
    send.disabled = true;
    ta.disabled = true;
    try {
      await fetch(`${API}/chat`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
      ta.value = "";
    } finally {
      ta.disabled = false;
      send.disabled = false;
      ta.focus();
    }
    await refresh();
  }

  send.addEventListener("click", sendMsg);
  ta.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendMsg(); }
  });

  return { refresh, focus: () => ta.focus() };
}