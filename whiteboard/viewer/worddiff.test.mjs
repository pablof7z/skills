// Node self-test for worddiff.mjs. Uses a passthrough renderMd so assertions
// run against the raw merged markdown (no browser marked/DOMPurify needed).
// Run: node whiteboard/viewer/worddiff.test.mjs
import { renderWordDiff } from "./worddiff.mjs";

let pass = 0, fail = 0;
function includes(actual, sub, msg) {
  if (actual.includes(sub)) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  missing: ${JSON.stringify(sub)}\n  in:   ${JSON.stringify(actual)}`); }
}
function excludes(actual, sub, msg) {
  if (!actual.includes(sub)) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  unexpected: ${JSON.stringify(sub)}\n  in:   ${JSON.stringify(actual)}`); }
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

// 6) adaptive counts edit islands, not del/ins transitions. Three distant
// replacements remain precise because meaningful anchors separate them.
const sparse = renderWordDiff(
  "Alice drafts the report Monday; Bob reviews it Friday; Carol ships at noon.",
  "Maya drafts the report Monday; Bob reviews it Thursday; Carol ships at dusk.",
  passthrough,
);
includes(sparse, '<div class="wb-mod">', "three sparse replacements stay inline");
includes(sparse, "<del>Alice</del><ins>Maya</ins>", "first sparse island is marked");
includes(sparse, "<del>Friday</del><ins>Thursday</ins>", "middle sparse island is marked");
includes(sparse, "<del>noon</del><ins>dusk</ins>", "last sparse island is marked");

// 7) dense checkerboard churn falls back in Adaptive, but the user can request
// the finest credible detail explicitly.
const churnOld = "The small red fox crossed the narrow stone bridge at dawn.";
const churnNew = "The large blue dog crossed a wide wooden tunnel at dusk.";
const adaptiveChurn = renderWordDiff(churnOld, churnNew, passthrough);
includes(adaptiveChurn, '<div class="wb-del">', "dense rewrite shows a before unit");
includes(adaptiveChurn, '<div class="wb-ins">', "dense rewrite shows an after unit");
excludes(adaptiveChurn, '<div class="wb-mod">', "dense rewrite avoids noisy inline churn");
const detailedChurn = renderWordDiff(churnOld, churnNew, passthrough, { detail: "more-detail" });
includes(detailedChurn, '<div class="wb-mod">', "More detail exposes credible inner matches");

// 8) Before & after is a presentation override even for a tiny edit.
const broadSwap = renderWordDiff("Release on Monday.", "Release on Tuesday.", passthrough, { detail: "before-after" });
includes(broadSwap, '<div class="wb-del">', "Before & after keeps the old unit separate");
includes(broadSwap, '<div class="wb-ins">', "Before & after keeps the new unit separate");
excludes(broadSwap, '<div class="wb-mod">', "Before & after disables inline spans");

// 9) raw Markdown delimiters are never split by inline tags, even in the most
// detailed mode.
const emphasis = renderWordDiff(
  "This is **very important**.", "This is **extremely important**.",
  passthrough, { detail: "more-detail" },
);
includes(emphasis, '<div class="wb-del">This is **very important**.</div>', "Markdown old unit stays valid");
includes(emphasis, '<div class="wb-ins">This is **extremely important**.</div>', "Markdown new unit stays valid");
excludes(emphasis, "**<del>", "diff tags do not enter emphasis delimiters");

// 10) render-neutral wrapping does not manufacture a text change.
const rewrap = renderWordDiff(
  "The release ships Friday after testing.",
  "The release ships Friday\nafter testing.",
  passthrough,
);
excludes(rewrap, "<del>", "source reflow has no deletion");
excludes(rewrap, "<ins>", "source reflow has no insertion");

// 11) punctuation, CJK words, and emoji modifiers are useful atomic changes.
const punctuation = renderWordDiff("Let’s eat, Grandma.", "Let’s eat Grandma.", passthrough);
includes(punctuation, "<del>,</del>", "punctuation is independent from adjacent words");
const cjk = renderWordDiff("明天发布测试版本。", "明天发布稳定版本。", passthrough);
includes(cjk, "<del>测试</del><ins>稳定</ins>", "CJK word replacement stays localized");
const emoji = renderWordDiff("Ask 👩🏻‍💻 today.", "Ask 👩🏽‍💻 today.", passthrough);
includes(emoji, "<del>👩🏻‍💻</del><ins>👩🏽‍💻</ins>", "emoji graphemes are not split");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
