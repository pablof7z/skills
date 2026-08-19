// patch.mjs — minimal unified-diff applier for `wb change edit --diff`.
// Applies standard `diff -u` hunks to a block's text. Hunk context is located by
// content match within a fuzz window (so small line offsets still apply); throws
// on any hard mismatch so it never silently corrupts content. Not a 3-way merge
// — meant for fresh diffs the agent just generated against the current block.

const HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

function parseHunks(diff) {
  const lines = diff.split("\n");
  const hunks = [];
  let cur = null;
  for (const line of lines) {
    if (line.startsWith("@@")) {
      const m = line.match(HUNK);
      if (m) { cur = { oldStart: +m[1], lines: [] }; hunks.push(cur); }
      continue;
    }
    if (!cur) continue; // skip ---/+++ headers and anything before the first hunk
    if (line.startsWith(" ") || line.startsWith("-") || line.startsWith("+")) {
      cur.lines.push({ type: line[0], text: line.slice(1) });
    }
    // a blank line or "\ No newline" marker is not a diff content line — ignore
  }
  return hunks;
}

// Find the index in `lines` where `want` matches, searching outward from `near`.
function findAnchor(lines, want, near) {
  if (!want.length) return Math.max(0, Math.min(near, lines.length));
  const n = want.length;
  for (let d = 0; d <= 200; d++) {
    for (const i of [near + d, near - d]) {
      if (i < 0 || i + n > lines.length) continue;
      let ok = true;
      for (let k = 0; k < n; k++) if (lines[i + k] !== want[k]) { ok = false; break; }
      if (ok) return i;
    }
  }
  return -1;
}

export function applyUnifiedDiff(text, diff) {
  const lines = text.split("\n");
  let offset = 0;
  for (const h of parseHunks(diff)) {
    const oldLines = h.lines.filter((l) => l.type !== "+").map((l) => l.text);
    const newLines = h.lines.filter((l) => l.type !== "-").map((l) => l.text);
    const at = findAnchor(lines, oldLines, Math.max(0, h.oldStart - 1 + offset));
    if (at === -1) throw new Error(`diff hunk @@ -${h.oldStart} did not apply (context not found)`);
    lines.splice(at, oldLines.length, ...newLines);
    offset += newLines.length - oldLines.length;
  }
  return lines.join("\n");
}