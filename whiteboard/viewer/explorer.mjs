// Explorer: lists all whiteboard sessions under the root with unread badges,
// grouped by project. Live-updates via SSE.

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function fmtDate(iso) {
  if (!iso) return "";
  return iso.replace("T", " ").slice(0, 10);
}

function statusColor(status) {
  switch (status) {
    case "decided": return "#0a8a5f";
    case "converging": return "#b88500";
    case "archived": return "#9aa0a6";
    default: return "#2f6feb";
  }
}

export function initExplorer(root) {
  document.title = "Whiteboard — sessions";
  root.innerHTML = `
    <div class="explorer">
      <header class="ex-head">
        <div class="ex-title">Whiteboard</div>
        <div class="ex-sub" id="ex-sub">sessions</div>
      </header>
      <div class="ex-scroll" id="ex-list"></div>
    </div>`;

  const listEl = document.getElementById("ex-list");

  function sessionHref(p, slug) {
    return `/session/${encodeURIComponent(p)}/${encodeURIComponent(slug)}`;
  }

  function render(sessions) {
    document.getElementById("ex-sub").textContent = `${sessions.length} session${sessions.length === 1 ? "" : "s"}`;
    if (sessions.length === 0) {
      listEl.innerHTML = `<div class="ex-empty">No whiteboard sessions yet. Start one from a chat with the whiteboard skill.</div>`;
      return;
    }
    // group by project
    const byProject = new Map();
    for (const s of sessions) {
      if (!byProject.has(s.project)) byProject.set(s.project, []);
      byProject.get(s.project).push(s);
    }
    const projects = [...byProject.keys()].sort();
    listEl.innerHTML = "";
    for (const proj of projects) {
      const sec = document.createElement("section");
      sec.className = "ex-project";
      sec.innerHTML = `<h2>${esc(proj)}</h2>`;
      for (const s of byProject.get(proj)) {
        const card = document.createElement("a");
        card.className = "ex-card" + (s.unread > 0 ? " has-unread" : "");
        card.href = sessionHref(s.project, s.slug);
        const badge = s.unread > 0 ? `<span class="unread-badge">${s.unread}</span>` : "";
        const status = `<span class="status-pill" style="color:${statusColor(s.status)};border-color:${statusColor(s.status)}40">${esc(s.status)}</span>`;
        card.innerHTML = `
          ${badge}
          <div class="ex-card-main">
            <div class="ex-card-name">${esc(s.name)}</div>
            <div class="ex-card-meta">
              ${status}
              <span class="meta">${s.commentCount} comment${s.commentCount === 1 ? "" : "s"}</span>
              ${s.lastActivity ? `<span class="meta">· ${esc(fmtDate(s.lastActivity))}</span>` : ""}
            </div>
          </div>`;
        sec.appendChild(card);
      }
      listEl.appendChild(sec);
    }
  }

  async function refresh() {
    try {
      const r = await fetch("/api/sessions");
      const d = await r.json();
      render(d.sessions || []);
    } catch (e) {
      listEl.innerHTML = `<div class="ex-empty">Failed to load sessions.</div>`;
    }
  }

  refresh();
  const es = new EventSource("/api/events");
  es.addEventListener("sessions", refresh);
  es.addEventListener("error", () => { /* auto-reconnect */ });
}