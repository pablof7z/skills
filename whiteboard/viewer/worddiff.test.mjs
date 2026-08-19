// Node self-test for worddiff.mjs. Uses a passthrough renderMd so assertions
// run against the raw merged markdown (no browser marked/DOMPurify needed).
// Run: node whiteboard/viewer/worddiff.test.mjs
import { renderWordDiff } from "./worddiff.mjs";

let pass = 0, fail = 0;
function includes(actual, sub, msg) {
  if (actual.includes(sub)) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  missing: ${JSON.stringify(sub)}\n  in:   ${JSON.stringify(actual)}`); }
}

const passthrough = (s) => s;

// 1) single-word swap — the core case: "nice" -> "better"
const swap = renderWordDiff("this is a nice sentence", "this is a better sentence", passthrough);
includes(swap, "<del>nice</del>", "deleted old word is struck");
includes(swap, "<ins>better</ins>", "inserted new word is highlighted");
includes(swap, "sentence", "unchanged trailing word is preserved");
includes(swap, '<div class="wb-mod">', "modified line is wrapped in .wb-mod");

// 2) pure line addition
const added = renderWordDiff("alpha", "alpha\nbeta", passthrough);
includes(added, '<div class="wb-ins">', "pure-added line is a green .wb-ins block");
includes(added, "beta", "added line content is present");

// 3) pure line deletion
const removed = renderWordDiff("alpha\nbeta", "alpha", passthrough);
includes(removed, '<div class="wb-del">', "pure-removed line is a red .wb-del block");
includes(removed, "beta", "removed line content is present");

// 4) no change — renders as plain markdown, no diff markup
const same = renderWordDiff("hello world", "hello world", passthrough);
if (same === "hello world") pass++;
else { fail++; console.error(`FAIL no-change should yield plain markdown\n  got: ${JSON.stringify(same)}`); }

// 5) multi-word edit within a line
const multi = renderWordDiff("the quick brown fox", "the slow brown fox", passthrough);
includes(multi, "<del>quick</del>", "first changed word deleted");
includes(multi, "<ins>slow</ins>", "replacement word inserted");
includes(multi, "the", "unchanged leading word kept");
includes(multi, "brown fox", "unchanged trailing words kept");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);