// Explorer: lists all whiteboard sessions under the root with unread badges,
// as a flat list sorted by last activity. Live-updates via the page's shared
// SSE stream (see main.mjs). Project filter pills persist their selection in
// localStorage.

import { onSessions } from "./main.mjs";

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function fmtDate(iso) {
  if (!iso) return "";
  return iso.replace("T", " ").slice(0, 10);
}

function relativeTime(iso) {
  if (!iso) return "";
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return fmtDate(iso);
  const s = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  if (s < 2592000) return `${Math.floor(s / 86400)}d ago`;
  return fmtDate(iso);
}

function statusColor(status) {
  switch (status) {
    case "decided": return "#0a8a5f";
    case "converging": return "#b88500";
    case "archived": return "#9aa0a6";
    default: return "#2f6feb";
  }
}

const LS_KEY = "wb-explorer-projects";

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
  let selectedProjects = new Set(JSON.parse(localStorage.getItem(LS_KEY) || "[]"));
  let allSessions = [];

  function saveSelected() {
    localStorage.setItem(LS_KEY, JSON.stringify([...selectedProjects]));
  }

  function sessionHref(p, slug) {
    return `/session/${encodeURIComponent(p)}/${encodeURIComponent(slug)}`;
  }

  function renderPills(projects) {
    const row = document.createElement("div");
    row.className = "ex-filters";
    const allActive = selectedProjects.size === 0;
    row.appendChild(makePill("All", allActive, () => {
      selectedProjects.clear();
      saveSelected();
      render(allSessions);
    }));
    for (const proj of projects) {
      const active = selectedProjects.has(proj);
      row.appendChild(makePill(proj, active, () => {
        if (active) selectedProjects.delete(proj);
        else selectedProjects.add(proj);
        saveSelected();
        render(allSessions);
      }));
    }
    return row;
  }

  function makePill(label, active, onClick) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "ex-pill" + (active ? " active" : "");
    btn.textContent = label;
    btn.addEventListener("click", onClick);
    return btn;
  }

  function render(sessions) {
    allSessions = sessions;
    const distinct = [...new Set(sessions.map((s) => s.project))].sort();
    const shown = sessions.filter((s) => selectedProjects.size === 0 || selectedProjects.has(s.project));

    document.getElementById("ex-sub").textContent =
      `${shown.length} of ${sessions.length} session${sessions.length === 1 ? "" : "s"}`;

    listEl.innerHTML = "";
    listEl.appendChild(renderPills(distinct));

    if (sessions.length === 0) {
      const empty = document.createElement("div");
      empty.className = "ex-empty";
      empty.textContent = "No whiteboard sessions yet. Start one from a chat with the whiteboard skill.";
      listEl.appendChild(empty);
      return;
    }
    if (shown.length === 0) {
      const empty = document.createElement("div");
      empty.className = "ex-empty";
      empty.textContent = "No sessions match the selected project filter.";
      listEl.appendChild(empty);
      return;
    }

    for (const s of shown) {
      const card = document.createElement("a");
      card.className = "ex-card" + (s.unread > 0 ? " has-unread" : "");
      card.href = sessionHref(s.project, s.slug);
      const badge = s.unread > 0 ? `<span class="unread-badge">${s.unread}</span>` : "";
      const status = `<span class="status-pill" style="color:${statusColor(s.status)};border-color:${statusColor(s.status)}40">${esc(s.status)}</span>`;
      const created = s.createdAt ? `<span class="meta">created ${esc(relativeTime(s.createdAt))}</span>` : "";
      const active = s.lastActivity ? `<span class="meta">· active ${esc(relativeTime(s.lastActivity))}</span>` : "";
      card.innerHTML = `
        ${badge}
        <div class="ex-card-main">
          <div class="ex-card-name">${esc(s.name)}</div>
          <div class="ex-card-meta">
            ${status}
            <span class="meta">${s.commentCount} comment${s.commentCount === 1 ? "" : "s"}</span>
            ${created}
            ${active}
          </div>
        </div>`;
      listEl.appendChild(card);
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
  const offSessions = onSessions(refresh);
  // Recompute relative-time labels ("just now" -> "1m ago" …) while the page
  // stays open, without refetching. allSessions is the cached list render() keeps.
  const timer = setInterval(() => { if (allSessions.length) render(allSessions); }, 30000);
  // Tear down our stream registration + timer when the router re-routes
  // (back/forward / SPA navigation).
  return { destroy() { offSessions(); clearInterval(timer); } };
}