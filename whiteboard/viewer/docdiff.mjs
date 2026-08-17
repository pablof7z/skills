// Inline diff rendering for the whiteboard document. Given the previously-viewed
// markdown and the current markdown, produce HTML that shows additions
// highlighted and removals as strikethrough, in place — by line-level LCS,
// grouping consecutive same-type lines and rendering each group as markdown so
// multi-line constructs (lists, code fences) stay intact.

function lcsOps(A, B) {
  const n = A.length, m = B.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = A[i] === B[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { ops.push({ t: "eq", line: A[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { ops.push({ t: "del", line: A[i] }); i++; }
    else { ops.push({ t: "ins", line: B[j] }); j++; }
  }
  while (i < n) { ops.push({ t: "del", line: A[i] }); i++; }
  while (j < m) { ops.push({ t: "ins", line: B[j] }); j++; }
  return ops;
}

// renderMd: (md) -> sanitized html string
export function renderDocDiff(oldContent, newContent, renderMd) {
  const A = String(oldContent ?? "").split("\n");
  const B = String(newContent ?? "").split("\n");
  const ops = lcsOps(A, B);
  const groups = [];
  for (const op of ops) {
    const last = groups[groups.length - 1];
    if (last && last.t === op.t) last.lines.push(op.line);
    else groups.push({ t: op.t, lines: [op.line] });
  }
  let html = "";
  for (const g of groups) {
    if (g.t === "eq" && g.lines.every((l) => l.trim() === "")) continue;
    const rendered = renderMd(g.lines.join("\n"));
    if (g.t === "eq") html += `<div class="wb-eq">${rendered}</div>`;
    else if (g.t === "ins") html += `<div class="wb-ins">${rendered}</div>`;
    else html += `<div class="wb-del">${rendered}</div>`;
  }
  return html;
}