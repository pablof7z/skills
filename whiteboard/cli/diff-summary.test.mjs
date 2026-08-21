// Node self-test for the token-level diff summarizer in diff-summary.mjs.
// Run: node whiteboard/cli/diff-summary.test.mjs
import { summarizeEdit, editDetail, summarizeAdd, summarizeRemove } from "./diff-summary.mjs";

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) pass++;
  else { fail++; console.error(`FAIL ${msg}`); }
}

// (a) single-word swap: 1 hunk, +1 -1
{
  const s = summarizeEdit("the quick fox", "the slow fox");
  ok(s.hunks === 1, "single-word swap: 1 hunk, got " + s.hunks);
  ok(s.added === 1 && s.removed === 1, "single-word swap: +1 -1, got +" + s.added + " -" + s.removed);
  ok(s.text === "1 hunk, +1 −1 word", "single-word swap text: " + s.text);
}

// (b) a word moves from one place to another — 2 hunks (the drift signal)
{
  const oldMd = "some body has real prose";
  const newMd = "some real body has prose";
  const s = summarizeEdit(oldMd, newMd);
  ok(s.hunks === 2, "word-move: 2 hunks, got " + s.hunks);
  ok(s.added === 1 && s.removed === 1, "word-move: +1 -1, got +" + s.added + " -" + s.removed);
  const detail = editDetail(oldMd, newMd);
  ok(detail.length === 2, "word-move: 2 detail lines, got " + detail.length);
}

// (c) identical pair — no changes
{
  const s = summarizeEdit("same text here", "same text here");
  ok(s.hunks === 0 && s.added === 0 && s.removed === 0, "identical: zero counts, got " + JSON.stringify(s));
  ok(s.text === "no changes", "identical text: " + s.text);
  ok(editDetail("same text here", "same text here").length === 0, "identical: no detail lines");
}

// (d) a large rewrite (5 isolated word swaps) triggers the detail cap
{
  const oldMd = "a b c d e f g h i";
  const newMd = "A b C d E f G h I";
  const s = summarizeEdit(oldMd, newMd);
  ok(s.hunks === 5, "large rewrite: 5 hunks, got " + s.hunks);
  const detail = editDetail(oldMd, newMd);
  ok(detail.length === 4, "large rewrite: capped at 3 + 1 summary line, got " + detail.length);
  ok(/…and 2 more/.test(detail[detail.length - 1]), "large rewrite: cap line mentions remaining count: " + detail[detail.length - 1]);
}

// (e) summarizeAdd / summarizeRemove shape
{
  const md = "# Title\nline one\n\nline two words here";
  ok(summarizeAdd(md) === "3 line(s), 8 word(s)", "summarizeAdd shape: " + summarizeAdd(md));
  ok(summarizeRemove(md) === summarizeAdd(md), "summarizeRemove mirrors summarizeAdd");
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
