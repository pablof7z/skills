// Whiteboard history/diff panel. Lists deliverable.md version snapshots
// (versions/<sha12>.md) and shows a line diff of each version against its
// predecessor, so the human can walk the deltas and see what the agent changed.

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[c]));

// Standard LCS line diff. Fine for document-sized inputs.
function diffLines(a, b) {
  const A = String(a ?? "").split("\n");
  const B = String(b ?? "").split("\n");
  const n = A.length, m = B.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = A[i] === B[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { out.push({ t: "eq", s: A[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { out.push({ t: "del", s: A[i] }); i++; }
    else { out.push({ t: "ins", s: B[j] }); j++; }
  }
  while (i < n) { out.push({ t: "del", s: A[i] }); i++; }
  while (j < m) { out.push({ t: "ins", s: B[j] }); j++; }
  return out;
}

function renderDiff(a, b) {
  const d = diffLines(a, b);
  if (d.every((l) => l.t === "eq")) {
    return `<div class="empty">No changes in this version.</div>`;
  }
  const lines = d.map((l) => {
    const sign = l.t === "ins" ? "+" : l.t === "del" ? "−" : " ";
    const cls = l.t === "ins" ? "ins" : l.t === "del" ? "del" : "eq";
    return `<div class="diff-line ${cls}"><span class="diff-sign">${sign}</span><span class="diff-text">${esc(l.s)}</span></div>`;
  }).join("");
  return `<div class="diff">${lines}</div>`;
}

export function initHistory(container, API) {
  container.innerHTML = `
    <div class="hist-list" id="hist-list"></div>
    <div class="diff-wrap" id="hist-diff"><div class="empty">Select a version to see what changed.</div></div>`;

  const listEl = container.querySelector("#hist-list");
  const diffEl = container.querySelector("#hist-diff");
  let versions = [];
  let selected = null;
  const cache = new Map();

  async function fetchVersion(v) {
    if (cache.has(v)) return cache.get(v);
    try {
      const r = await fetch(`${API}/versions/${v}`);
      if (!r.ok) return "";
      const d = await r.json();
      cache.set(v, d.content || "");
      return d.content || "";
    } catch { return ""; }
  }

  async function showDiff(v) {
    const idx = versions.findIndex((x) => x.version === v);
    const prev = versions[idx + 1]; // older predecessor
    const b = await fetchVersion(v);
    const a = prev ? await fetchVersion(prev.version) : "";
    const label = prev
      ? `diff: <strong>${v.slice(0, 8)}</strong> ← previous ${prev.version.slice(0, 8)}`
      : `first version <strong>${v.slice(0, 8)}</strong>`;
    diffEl.innerHTML = `<div class="diff-head">${label}</div>${renderDiff(a, b)}`;
  }

  function render() {
    if (versions.length === 0) {
      listEl.innerHTML = `<div class="empty">No versions yet. They appear as the deliverable is edited.</div>`;
      return;
    }
    listEl.innerHTML = "";
    versions.forEach((v, i) => {
      const isCurrent = i === 0;
      const row = document.createElement("div");
      row.className = "hist-row" + (selected === v.version ? " active" : "");
      row.dataset.version = v.version;
      const date = new Date(v.mtime).toLocaleString();
      row.innerHTML = `<span class="hist-hash">${v.version.slice(0, 8)}</span><span class="hist-date">${esc(date)}</span>${isCurrent ? `<span class="hist-tag">current</span>` : ""}`;
      row.addEventListener("click", () => {
        selected = v.version;
        document.querySelectorAll(".hist-row").forEach((r) => r.classList.remove("active"));
        row.classList.add("active");
        showDiff(v.version);
      });
      listEl.appendChild(row);
    });
  }

  async function refresh() {
    try {
      const r = await fetch(`${API}/versions`);
      const d = await r.json();
      const next = d.versions || [];
      // invalidate cache for any version that disappeared/reappeared? keep simple: clear on new set
      const prevKeys = new Set(versions.map((v) => v.version));
      const nextKeys = new Set(next.map((v) => v.version));
      if (prevKeys.size !== nextKeys.size || [...nextKeys].some((k) => !prevKeys.has(k))) cache.clear();
      versions = next;
      render();
      const target = selected && nextKeys.has(selected) ? selected : (next[0] && next[0].version);
      if (target) { selected = target; await showDiff(target); }
    } catch {}
  }

  return { refresh };
}