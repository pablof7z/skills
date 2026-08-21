// diff-summary.mjs — pure token/word-level diff summaries for block markdown.
// No DOM, no fs; imports nothing. Used by apply.mjs and staging.mjs to turn a
// caller-supplied edit (old md → new md) into a human-readable content delta,
// so a full-text `edit` op can't silently drift without the caller seeing it.

function tokenize(md) {
  return String(md == null ? "" : md).match(/[A-Za-z0-9]+|[^\sA-Za-z0-9]/g) || [];
}

// Standard LCS-backed token diff, coalesced into runs of {type, tokens}.
function lcsOps(oldT, newT) {
  const n = oldT.length, m = newT.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = oldT[i] === newT[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const ops = [];
  const push = (type, tok) => {
    const last = ops[ops.length - 1];
    if (last && last.type === type) last.tokens.push(tok);
    else ops.push({ type, tokens: [tok] });
  };
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (oldT[i] === newT[j]) { push("equal", oldT[i]); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) { push("remove", oldT[i]); i++; }
    else { push("add", newT[j]); j++; }
  }
  while (i < n) { push("remove", oldT[i]); i++; }
  while (j < m) { push("add", newT[j]); j++; }
  return ops;
}

const CONTEXT_N = 2;

// Group consecutive non-equal runs into hunks (a hunk = one changed region,
// possibly both removed and added tokens — e.g. a word moved), each carrying
// a couple of surrounding words as context.
function diffHunks(oldMd, newMd) {
  const ops = lcsOps(tokenize(oldMd), tokenize(newMd));
  const hunks = [];
  let k = 0;
  while (k < ops.length) {
    if (ops[k].type === "equal") { k++; continue; }
    const start = k;
    const added = [], removed = [];
    while (k < ops.length && ops[k].type !== "equal") {
      if (ops[k].type === "add") added.push(...ops[k].tokens);
      else removed.push(...ops[k].tokens);
      k++;
    }
    const before = start > 0 ? ops[start - 1] : null;
    const after = k < ops.length ? ops[k] : null;
    const ctx = [...(before ? before.tokens.slice(-CONTEXT_N) : []), ...(after ? after.tokens.slice(0, CONTEXT_N) : [])].join(" ");
    hunks.push({ added, removed, context: ctx || added[0] || removed[0] || "" });
  }
  return hunks;
}

// { hunks, added, removed, text } — a one-line summary of oldMd → newMd.
export function summarizeEdit(oldMd, newMd) {
  if (oldMd === newMd) return { hunks: 0, added: 0, removed: 0, text: "no changes" };
  const hunks = diffHunks(oldMd, newMd);
  const added = hunks.reduce((s, h) => s + h.added.length, 0);
  const removed = hunks.reduce((s, h) => s + h.removed.length, 0);
  const text = `${hunks.length} hunk${hunks.length === 1 ? "" : "s"}, +${added} −${removed} word${added === 1 ? "" : "s"}`;
  return { hunks: hunks.length, added, removed, text };
}

const DETAIL_CAP = 3;

// Per-hunk detail lines: `  "<context>"   +token −token`, capped at 3 hunks.
export function editDetail(oldMd, newMd) {
  if (oldMd === newMd) return [];
  const hunks = diffHunks(oldMd, newMd);
  const lines = hunks.slice(0, DETAIL_CAP).map((h) => {
    const parts = [];
    if (h.added.length) parts.push(`+${h.added.join(" ")}`);
    if (h.removed.length) parts.push(`−${h.removed.join(" ")}`);
    return `  "${h.context}"   ${parts.join(" ")}`;
  });
  if (hunks.length > DETAIL_CAP) lines.push(`  …and ${hunks.length - DETAIL_CAP} more`);
  return lines;
}

function countLinesWords(md) {
  const s = String(md == null ? "" : md);
  const lines = s.split("\n").filter((l) => l.trim().length).length;
  const words = (s.match(/\S+/g) || []).length;
  return `${lines} line(s), ${words} word(s)`;
}

export function summarizeAdd(md) { return countLinesWords(md); }
export function summarizeRemove(md) { return countLinesWords(md); }
