// blockdiff.mjs — revision-review controls for the block viewer.
//
// Owns relative-time labels, revision picker presentation, baseline loading,
// and review acknowledgement. Rendering remains on the live document surface.

import { mountDiffDetail } from "./diffprefs.mjs";


const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

// Relative time label from an ISO timestamp: "just now", "Nm ago", "Nh ago",
// "Nd ago", else a short YYYY-MM-DD date. Pure (uses Date.now).
export function ago(iso) {
  if (!iso) return "—";
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return "—";
  const s = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (s < 45) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  if (s < 86400 * 30) return `${Math.floor(s / 86400)}d ago`;
  return new Date(t).toISOString().slice(0, 10);
}

// Options for the rev picker: each { value, title, meta, group }. Per-revision
// options show the change's title + "N change(s) · ago"; the closed button shows
// only the title, the opened panel shows title + meta. Shortcuts (Current, Last
// viewed) are pinned at the top. Dedup by value.
export function buildPickerOptions(revisions, currentRev, viewedRev) {
  const out = []; const seen = new Set();
  const revBy = new Map((revisions || []).map((r) => [r.rev, r]));
  const cur = revBy.get(currentRev);
  const ch = (n) => `${n} change${n === 1 ? "" : "s"}`;
  const meta = (r) => r.blocks ? `${ch(r.blocks)} to document · ${ago(r.at)}` : r.changes ? `${ch(r.changes)} to annotations · ${ago(r.at)}` : `no document change · ${ago(r.at)}`;
  const push = (value, title, meta, group, by = null, jump = false, labels = []) => {
    const key = String(value); if (seen.has(key)) return; seen.add(key);
    out.push({ value, title, meta, group, by, jump, labels });
  };
  // No separate shortcut rows: the revision that IS current carries the
  // "current" sentinel value (so the after-picker keeps tracking the live doc)
  // and a "Current" label; the rev last viewed (when != current) gets a
  // "Last viewed" label. Falls back to a synthetic "current" row if the live
  // rev isn't in the list yet.
  for (const r of revisions || []) {
    const isCurrent = r.rev === currentRev;
    const labels = isCurrent ? ["Current"] : (viewedRev && viewedRev === r.rev) ? ["Last viewed"] : [];
    push(isCurrent ? "current" : r.rev, r.title || `rev ${r.rev}`, meta(r), "rev", r.by || null, !!(r.via && r.via.itermSessionId), labels);
  }
  if (!seen.has("current")) push("current", cur?.title || "Current", cur ? meta(cur) : "now", "rev", cur?.by || null, !!(cur?.via && cur.via.itermSessionId), ["Current"]);
  return out;
}

export function latestBlockRevision(revisions, throughRev) {
  return (revisions || []).reduce((latest, revision) =>
    revision.blocks > 0 && revision.rev <= throughRev ? Math.max(latest, revision.rev) : latest, 0);
}

export function reviewBaseline(revisions, currentRev, viewedRev) {
  if (viewedRev > 0) return viewedRev;
  const oldest = (revisions || []).reduce((first, revision) =>
    revision.rev <= currentRev ? Math.min(first, revision.rev) : first, Number.POSITIVE_INFINITY);
  return Number.isFinite(oldest) ? oldest : Math.max(0, currentRev - 1);
}

// A custom dropdown (not a system <select>): a button showing the selected
// option's title (semibold) + a muted "N changes · ago" line; click opens a
// panel of all options grouped by shortcut/rev. Sets container.value and
// dispatches "change" on pick so the existing wiring (reading el.value) works.
function mountRevPicker(container, options, value, onJump) {
  let panel = null;
  let cur = options;
  const find = (v) => cur.find((o) => String(o.value) === String(v)) || cur[0];
  const renderBtn = () => {
    const o = find(container.value);
    const lbls = (o?.labels || []).map((l) => `<span class="rp-label${l === "Last viewed" ? " rp-label-lv" : ""}">${esc(l)}</span>`).join("");
    container.innerHTML = `<button type="button" class="rev-picker-btn"><span class="rp-title">${esc(o?.title || "—")}</span>${lbls}<span class="rp-caret">▾</span></button>`;
    container.querySelector(".rev-picker-btn").addEventListener("click", (e) => { e.stopPropagation(); panel ? close() : open(); });
  };
  function open() {
    panel = document.createElement("div"); panel.className = "rev-picker-panel";
    let last = null; const rows = [];
    for (const o of cur) {
      if (o.group !== last && rows.length) rows.push(`<div class="rp-sep"></div>`);
      last = o.group;
      const by = o.by ? `<span class="rp-by" title="authored by ${esc(o.by)}">${esc(o.by)}</span>` : "";
      const jump = o.jump ? `<button type="button" class="rp-jump" title="Open the terminal that made this change">↗</button>` : "";
      const lbls = (o.labels || []).map((l) => `<span class="rp-label${l === "Last viewed" ? " rp-label-lv" : ""}">${esc(l)}</span>`).join("");
      rows.push(`<div class="rp-opt ${String(o.value) === String(container.value) ? "sel" : ""}" data-value="${esc(o.value)}"><span class="rp-title-row"><span class="rp-title">${esc(o.title)}</span>${lbls}</span><span class="rp-meta-row"><span class="rp-meta">${esc(o.meta)}</span>${by}${jump}</span></div>`);
    }
    panel.innerHTML = rows.join("");
    container.appendChild(panel);
    panel.addEventListener("click", (e) => {
      const jb = e.target.closest(".rp-jump");
      if (jb) { e.stopPropagation(); const row = jb.closest(".rp-opt"); if (row && onJump) onJump(row.dataset.value); return; }
      const row = e.target.closest(".rp-opt"); if (!row) return;
      container.value = row.dataset.value;
      container.dispatchEvent(new Event("change", { bubbles: true }));
      close(); renderBtn();
    });
    setTimeout(() => document.addEventListener("click", close, { once: true }), 0);
  }
  function close() { if (panel) { panel.remove(); panel = null; } }
  container.value = value; renderBtn();
  return { setOptions(opts, val) { cur = opts; container.value = val; renderBtn(); } };
}


// Revision review decorates the persistent document surface. It owns the
// revision pickers and baseline loading, but never replaces document DOM or
// hides comments; the viewer reconciles the selected snapshots in place.
export function initRevisionReview({
  API, state, diffBarEl, diffBeforeEl, diffAfterEl, captureContext, onRender,
}) {
  let beforePicker = null, afterPicker = null;
  const detailControl = mountDiffDetail(diffBarEl, () => {
    if (state.reviewingChanges) render();
  });
  async function jumpToRev(rev) {
    try { await fetch(`${API}/jump`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ rev: Number(rev) }) }); } catch {}
  }
  function populateSelects() {
    const opts = buildPickerOptions(state.revisions, state.doc?.rev ?? 0, state.viewedRev);
    if (!beforePicker) beforePicker = mountRevPicker(diffBeforeEl, opts, String(state.beforeRev), jumpToRev);
    else beforePicker.setOptions(opts, String(state.beforeRev));
    if (!afterPicker) afterPicker = mountRevPicker(diffAfterEl, opts, String(state.afterRev), jumpToRev);
    else afterPicker.setOptions(opts, String(state.afterRev));
  }

  async function loadRevision(rev) {
    if (rev === "current") return state.doc;
    const response = await fetch(`${API}/revisions/${rev}`);
    if (!response.ok) throw new Error(`revision ${rev} unavailable`);
    return response.json();
  }

  async function render(context = null) {
    let afterDoc = state.doc;
    try { afterDoc = await loadRevision(state.afterRev); } catch { afterDoc = null; }
    let beforeDoc = null;
    try { beforeDoc = await loadRevision(state.beforeRev); } catch { beforeDoc = null; }
    if (!beforeDoc || !afterDoc) {
      await onRender({ error: `Could not load revisions ${state.beforeRev} → ${state.afterRev}.`, context });
      return;
    }
    state.diffBeforeDoc = beforeDoc; state.diffAfterDoc = afterDoc;
    await onRender({ beforeDoc, afterDoc, detail: detailControl.value, context });
  }

  async function show({ baseline = null } = {}) {
    const context = captureContext?.();
    state.reviewingChanges = true;
    diffBarEl.hidden = false;
    if (!state.revisions?.length) {
      try { const res = await fetch(`${API}/revisions`); state.revisions = (await res.json()).revisions || []; } catch { state.revisions = []; }
    }
    state.beforeRev = baseline ?? reviewBaseline(state.revisions, state.doc?.rev ?? 0, state.viewedRev);
    state.afterRev = "current";
    populateSelects();
    await render(context);
  }

  async function hide() {
    const context = captureContext?.();
    state.reviewingChanges = false;
    state.suppressedBlockRev = Math.max(state.suppressedBlockRev || 0,
      latestBlockRevision(state.revisions, state.doc?.rev ?? 0));
    diffBarEl.hidden = true;
    state.diffBeforeDoc = null; state.diffAfterDoc = null;
    await onRender({ beforeDoc: null, afterDoc: state.doc, detail: detailControl.value, context });
  }

  async function markRead() {
    await fetch(`${API}/viewed`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ version: String(state.doc?.rev ?? 0) }) });
    state.viewedRev = state.doc?.rev ?? 0;
    await hide();
  }

  return { populate: populateSelects, render, show, hide, markRead };
}
