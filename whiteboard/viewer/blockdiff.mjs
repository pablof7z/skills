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

// Build the <option> list for a before/after select. value is a rev number or
// the literal string "current". Semantic shortcuts (current, previous, last
// viewed) are emitted first, then one row per real revision. Identical values
// across the shortcuts and the revision list are deduped (first occurrence
// wins). Pure.
export function buildSelectOptions(revisions, currentRev, viewedRev) {
  const out = [];
  const seen = new Set();
  const push = (value, label, group) => {
    const key = String(value);
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ value, label, group });
  };
  push("current", "current", "shortcut");
  if (Number.isFinite(currentRev)) push(currentRev - 1, "previous (current-1)", "shortcut");
  if (viewedRev && viewedRev !== currentRev) push(viewedRev, "last viewed", "shortcut");
  for (const r of revisions || []) push(r.rev, `rev ${r.rev} · ${ago(r.at)}`, "rev");
  return out;
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
  function populateSelects() {
    const opts = buildSelectOptions(state.revisions, state.doc?.rev ?? 0, state.viewedRev);
    for (const sel of [diffBeforeEl, diffAfterEl]) {
      sel.innerHTML = opts.map((o) => `<option value="${esc(o.value)}">${esc(o.label)}</option>`).join("");
    }
    diffBeforeEl.value = String(state.beforeRev);
    diffAfterEl.value = String(state.afterRev);
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
    try {
      const res = await fetch(`${API}/revisions`);
      state.revisions = (await res.json()).revisions || [];
    } catch { state.revisions = []; }
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
    populateSelects();
  }

  return { populate: populateSelects, render, enter, exit, markRead };
}