// blockdiff.mjs — diff-mode helpers for the block viewer.
//
// Kept in its own module so blockview.mjs stays under the repo's 300-LOC soft
// limit. Three pure helpers: a relative-time label, a select-option builder
// for the before/after revision picker, and a whole-document diff renderer
// that delegates inline word-level diffing to worddiff.mjs.

import { renderWordDiff } from "./worddiff.mjs";

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
  const push = (value, title, meta, group) => {
    const key = String(value); if (seen.has(key)) return; seen.add(key);
    out.push({ value, title, meta, group });
  };
  push("current", "Current", cur ? `${ch(cur.changes || 0)} · ${ago(cur.at)}` : "now", "shortcut");
  if (viewedRev && viewedRev !== currentRev) {
    const v = revBy.get(viewedRev);
    push(viewedRev, "Last viewed (Done)", v ? `${ch(v.changes || 0)} · ${ago(v.at)}` : "—", "shortcut");
  }
  for (const r of revisions || []) push(r.rev, r.title || `rev ${r.rev}`, `${ch(r.changes || 0)} · ${ago(r.at)}`, "rev");
  return out;
}

// A custom dropdown (not a system <select>): a button showing the selected
// option's title (semibold) + a muted "N changes · ago" line; click opens a
// panel of all options grouped by shortcut/rev. Sets container.value and
// dispatches "change" on pick so the existing wiring (reading el.value) works.
function mountRevPicker(container, options, value) {
  let panel = null;
  let cur = options;
  const find = (v) => cur.find((o) => String(o.value) === String(v)) || cur[0];
  const renderBtn = () => {
    const o = find(container.value);
    container.innerHTML = `<button type="button" class="rev-picker-btn"><span class="rp-title">${esc(o?.title || "—")}</span><span class="rp-caret">▾</span></button>`;
    container.querySelector(".rev-picker-btn").addEventListener("click", (e) => { e.stopPropagation(); panel ? close() : open(); });
  };
  function open() {
    panel = document.createElement("div"); panel.className = "rev-picker-panel";
    let last = null; const rows = [];
    for (const o of cur) {
      if (o.group !== last && rows.length) rows.push(`<div class="rp-sep"></div>`);
      last = o.group;
      rows.push(`<div class="rp-opt ${String(o.value) === String(container.value) ? "sel" : ""}" data-value="${esc(o.value)}"><span class="rp-title">${esc(o.title)}</span><span class="rp-meta">${esc(o.meta)}</span></div>`);
    }
    panel.innerHTML = rows.join("");
    container.appendChild(panel);
    panel.addEventListener("click", (e) => {
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

// Render a whole document as a diff between beforeDoc and afterDoc. For each
// block name in (before ∪ after), matched by name:
//  - in both  -> <section> whose .block-md is renderWordDiff(before, after)
//  - only after -> <section> with "+ <name>" header, .block-md = green wb-ins
//  - only before -> <section> with "− <name>" header, .block-md = red wb-del
// Sections are ordered by afterDoc; removed-only-before blocks are appended.
// renderMarkdown: (md) -> sanitized HTML. Pure string output.
export function renderBlockDiff({ beforeDoc, afterDoc, renderMarkdown }) {
  const before = new Map((beforeDoc?.blocks || []).map((b) => [b.name, b]));
  const after = afterDoc?.blocks || [];
  const afterNames = new Set(after.map((b) => b.name));
  const parts = [];
  for (const b of after) {
    const old = before.get(b.name);
    if (old) {
      parts.push(section(b.name, renderWordDiff(old.md || "", b.md || "", renderMarkdown), blockFlags(b)));
    } else {
      parts.push(section(`+ ${b.name}`, `<div class="wb-ins">${renderMarkdown(b.md || "")}</div>`, blockFlags(b), "wb-added"));
    }
  }
  for (const b of beforeDoc?.blocks || []) {
    if (!afterNames.has(b.name)) {
      parts.push(section(`− ${b.name}`, `<div class="wb-del">${renderMarkdown(b.md || "")}</div>`, blockFlags(b), "wb-removed"));
    }
  }
  return parts.join("");
}

function blockFlags(b) {
  const FLAG_BADGE = {
    "needs-attention": { cls: "flag-attention", icon: "⚑", title: "Needs your attention" },
    decided: { cls: "flag-decided", icon: "✓", title: "Decided" },
    superseded: { cls: "flag-superseded", icon: "↳", title: "Superseded" },
  };
  let flags = "";
  for (const f of b.flags || []) {
    const badge = FLAG_BADGE[f];
    if (badge) flags += `<span class="block-flag ${badge.cls}" title="${esc(badge.title)}">${badge.icon}</span>`;
  }
  return flags;
}

function section(name, mdHtml, flags, extraCls = "") {
  const cls = "block" + (extraCls ? ` ${extraCls}` : "");
  const nameHtml = /^[+\u2212−]/.test(name) ? `<span class="diff-block-sign">${esc(name.slice(0, 1))}</span><span class="block-name">${esc(name.slice(2))}</span>` : `<span class="block-name">${esc(name)}</span>`;
  return `<section class="${cls}" data-block-id="${esc(name.replace(/^[+\u2212−]\s/, ""))}"><div class="block-head">${nameHtml}${flags}</div><div class="block-md">${mdHtml}</div></section>`;
}

// Diff-mode controller for the block viewer. Owns enter/exit/render/markRead so
// blockview.mjs stays thin. deps: { API, state, docEl, codeblocks, renderMarkdown,
// diffBarEl, docWrapEl, diffBeforeEl, diffAfterEl, onExit }. Returns the methods
// the viewer wires to buttons/selects and the refresh hook.
export function initDiffMode({
  API, state, docEl, codeblocks, renderMarkdown,
  diffBarEl, docWrapEl, diffBeforeEl, diffAfterEl, onExit,
}) {
  let beforePicker = null, afterPicker = null;
  function populateSelects() {
    const opts = buildPickerOptions(state.revisions, state.doc?.rev ?? 0, state.viewedRev);
    if (!beforePicker) beforePicker = mountRevPicker(diffBeforeEl, opts, String(state.beforeRev));
    else beforePicker.setOptions(opts, String(state.beforeRev));
    if (!afterPicker) afterPicker = mountRevPicker(diffAfterEl, opts, String(state.afterRev));
    else afterPicker.setOptions(opts, String(state.afterRev));
  }

  async function render() {
    let afterDoc = state.doc;
    try {
      if (state.afterRev !== "current") {
        const res = await fetch(`${API}/revisions/${state.afterRev}`);
        afterDoc = await res.json();
      }
    } catch { afterDoc = null; }
    let beforeDoc = null;
    try {
      const res = await fetch(`${API}/revisions/${state.beforeRev}`);
      beforeDoc = await res.json();
    } catch { beforeDoc = null; }
    if (!beforeDoc || !afterDoc) {
      docEl.innerHTML = `<div class="diff-error">Could not load revisions ${esc(state.beforeRev)} → ${esc(state.afterRev)}.</div>`;
      return;
    }
    state.diffBeforeDoc = beforeDoc; state.diffAfterDoc = afterDoc;
    docEl.innerHTML = renderBlockDiff({ beforeDoc, afterDoc, renderMarkdown });
    await codeblocks.enhance(docEl);
  }

  async function enter() {
    state.diffMode = true;
    diffBarEl.hidden = false;
    docWrapEl.classList.add("diff-on");
    if (!state.revisions?.length) {
      try { const res = await fetch(`${API}/revisions`); state.revisions = (await res.json()).revisions || []; } catch { state.revisions = []; }
    }
    state.beforeRev = state.viewedRev || ((state.doc?.rev ?? 1) - 1);
    state.afterRev = "current";
    populateSelects();
    await render();
  }

  async function exit() {
    state.diffMode = false;
    diffBarEl.hidden = true;
    docWrapEl.classList.remove("diff-on");
    onExit?.();
  }

  async function markRead() {
    await fetch(`${API}/viewed`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ version: String(state.doc?.rev ?? 0) }) });
    state.viewedRev = state.doc?.rev ?? 0;
    // "Done" = I've reviewed the changes. Mark viewed=current, then leave the
    // diff and return to the normal doc view — so the next block-changing
    // change (viewedRev < newRev, blocks>0) auto-enters the diff again.
    await exit();
  }

  return { populate: populateSelects, render, enter, exit, markRead };
}