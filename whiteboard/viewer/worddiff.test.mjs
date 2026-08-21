// Node self-test for worddiff.mjs. Uses a passthrough renderMd so assertions
// run against the raw merged markdown (no browser marked/DOMPurify needed).
// Run: node whiteboard/viewer/worddiff.test.mjs
import { renderWordDiff } from "./worddiff.mjs";
import { createRequire } from "node:module";

let pass = 0, fail = 0;
function includes(actual, sub, msg) {
  if (actual.includes(sub)) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  missing: ${JSON.stringify(sub)}\n  in:   ${JSON.stringify(actual)}`); }
}
function excludes(actual, sub, msg) {
  if (!actual.includes(sub)) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  unexpected: ${JSON.stringify(sub)}\n  in:   ${JSON.stringify(actual)}`); }
}
function count(actual, sub, expected, msg) {
  const found = actual.split(sub).length - 1;
  if (found === expected) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  expected ${expected}, found ${found}\n  in: ${JSON.stringify(actual)}`); }
}

const passthrough = (s) => s;
const marked = createRequire(import.meta.url)("./vendor/marked.min.js");
globalThis.marked = marked;

// 1) single-word swap — the core case: "nice" -> "better"
const swap = renderWordDiff("this is a nice sentence", "this is a better sentence", passthrough);
includes(swap, "<del>nice</del>", "deleted old word is struck");
includes(swap, "<ins>better</ins>", "inserted new word is highlighted");
includes(swap, "sentence", "unchanged trailing word is preserved");
includes(swap, '<div class="wb-mod">', "modified line is wrapped in .wb-mod");

// 2) pure line addition
const added = renderWordDiff("alpha", "alpha\n\nbeta", passthrough);
includes(added, '<div class="wb-ins">', "pure-added line is a green .wb-ins block");
includes(added, "beta", "added line content is present");

// 3) pure line deletion
const removed = renderWordDiff("alpha\n\nbeta", "alpha", passthrough);
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

// 9) complete Markdown inline nodes may be replaced, but their delimiters are
// never split by diff tags.
const emphasis = renderWordDiff(
  "This is **very important**.", "This is **extremely important**.",
  passthrough, { detail: "more-detail" },
);
includes(emphasis, '<del>**very important**</del>', "complete old emphasis node is replaced");
includes(emphasis, '<ins>**extremely important**</ins>', "complete new emphasis node is replaced");
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

// 12) one contiguous Markdown insertion is rendered as one fragment. Rendering
// each source line separately breaks headings, blank lines, and code fences.
const quickStart = [
  "Existing introduction.", "", "## Quick start — one group, one relay", "",
  "The usual case: one group on one relay.", "", "```rust",
  "use fava_simple_groups::Group;", "", "let photos = Group::on([relay], \"photos\")?;",
  "```",
].join("\n");
const insertedRegion = renderWordDiff("Existing introduction.", quickStart, passthrough);
count(insertedRegion, '<div class="wb-ins">', 1, "contiguous Markdown insertion has one visual wrapper");
includes(insertedRegion, "## Quick start — one group, one relay\n\nThe usual case", "heading and paragraph keep their boundary");
includes(insertedRegion, "```rust\nuse fava_simple_groups::Group;\n\nlet photos", "code fence remains one Markdown fragment");

// 13) an unchanged structural prefix is a safe container. Diff its prose body,
// while Before & after remains an explicit stacked override.
const listOld = "- Saved-list verbs: save_group / forget_group and save_relay / forget_relay.";
const listNew = "- Saved-list verbs: save_group / remove_group and save_relay / remove_relay.";
const adaptiveList = renderWordDiff(listOld, listNew, passthrough);
includes(adaptiveList, '<div class="wb-mod">', "localized list-item edit stays in one rendered item");
includes(adaptiveList, "- Saved-list verbs:", "list prefix is preserved outside diff spans");
includes(adaptiveList, "<del>forget_group</del><ins>remove_group</ins>", "list body receives inline word detail");
const broadList = renderWordDiff(listOld, listNew, passthrough, { detail: "before-after" });
excludes(broadList, '<div class="wb-mod">', "Before & after still stacks a list-item edit");

// 14) fenced blocks remain atomic even when only one interior line changes.
// Use the real Markdown parser so a split fence cannot hide behind passthrough.
const fenceOld = "Before.\n\n```rust\nlet first = 1;\n```\n\nAfter.";
const fenceNew = "Before.\n\n```rust\nlet first = 1;\nlet second = 2;\n```\n\nAfter.";
const fenced = renderWordDiff(fenceOld, fenceNew, marked.parse);
count(fenced, '<code class="language-rust">', 2, "changed fence renders as complete before and after code blocks");
excludes(fenced, "<p>let second = 2;</p>", "inserted code line never escapes its fence");

// 15) nested structure and emphasis stay on the safe before/after path.
const nestedList = renderWordDiff("- - old nested item", "- * new nested item", passthrough, { detail: "more-detail" });
excludes(nestedList, '<div class="wb-mod">', "nested list markers never receive inline diff tags");
const punctuatedEmphasis = renderWordDiff("Use —*carefully* here.", "Use —*sparingly* here.", passthrough, { detail: "more-detail" });
includes(punctuatedEmphasis, '<del>*carefully*</del><ins>*sparingly*</ins>', "emphasis after punctuation changes as atomic nodes");

// 16) fence recognition respects containers and indentation.
const deceptiveFenceOld = "```rust\n    ```\nlet first = 1;\n```";
const deceptiveFenceNew = "```rust\n    ```\nlet first = 1;\nlet second = 2;\n```";
const deceptiveFence = renderWordDiff(deceptiveFenceOld, deceptiveFenceNew, marked.parse);
count(deceptiveFence, '<code class="language-rust">', 2, "indented fence-like code does not close its containing fence");
excludes(deceptiveFence, "<p>let second = 2;</p>", "content after an indented fence-like line stays code");
const quoteFenceOld = "> ```rust\n> let first = 1;\n> ```";
const quoteFenceNew = "> ```rust\n> let first = 1;\n> let second = 2;\n> ```";
const quoteFence = renderWordDiff(quoteFenceOld, quoteFenceNew, marked.parse);
count(quoteFence, '<code class="language-rust">', 2, "blockquote fences stay atomic before and after");
excludes(quoteFence, "<p>let second = 2;</p>", "blockquote code insertion never becomes prose");

// 17) indented code and reference links never take the raw inline-tag path.
const indentedCode = renderWordDiff("    let old = 1;", "    let new = 2;", marked.parse, { detail: "more-detail" });
excludes(indentedCode, '<div class="wb-mod">', "four-space code uses safe before and after blocks");
excludes(indentedCode, "&lt;del&gt;", "diff markup is never displayed literally inside code");
const referenceLink = renderWordDiff("Read [research][old].", "Read [research][new].", passthrough, { detail: "more-detail" });
excludes(referenceLink, '<div class="wb-mod">', "reference-link syntax uses safe before and after blocks");

// 18) valid indented and list-contained fences remain atomic.
const spacedFenceOld = "   ```rust\nlet first = 1;\n   ```";
const spacedFenceNew = "   ```rust\nlet first = 1;\nlet second = 2;\n   ```";
const spacedFence = renderWordDiff(spacedFenceOld, spacedFenceNew, marked.parse);
count(spacedFence, '<code class="language-rust">', 2, "one-to-three-space fences stay atomic");
excludes(spacedFence, "<p>let second = 2;</p>", "spaced fence content never becomes prose");
const listFenceOld = "- ```rust\n  let first = 1;\n  ```";
const listFenceNew = "- ```rust\n  let first = 1;\n  let second = 2;\n  ```";
const listFence = renderWordDiff(listFenceOld, listFenceNew, marked.parse);
excludes(listFence, "<p>let second = 2;</p>", "list-contained fence content never becomes prose");

// 19) compact blockquote markers are structural prefixes, including when nested.
const compactQuote = renderWordDiff("- >old nested text", "- new nested text", passthrough, { detail: "more-detail" });
excludes(compactQuote, '<div class="wb-mod">', "compact nested blockquote never receives inline syntax tags");

// 20) interior fence-looking code is not reinterpreted as a new container.
const literalListFenceOld = "```rust\n- ```\nlet old_name = 1;\n```";
const literalListFenceNew = "```rust\n- ```\nlet new_name = 1;\n```";
const literalListFence = renderWordDiff(literalListFenceOld, literalListFenceNew, marked.parse);
count(literalListFence, '<code class="language-rust">', 2, "literal list-plus-fence line does not close an outer fence");
excludes(literalListFence, "<p>let new_name = 1;</p>", "code after literal fence-looking content stays fenced");

// 21) repeated containers are owned by the Markdown lexer, not a handwritten
// fence recognizer.
const nestedFenceOld = "- - ```rust\n    let old_name = 1;\n    ```";
const nestedFenceNew = "- - ```rust\n    let new_name = 1;\n    ```";
const nestedFence = renderWordDiff(nestedFenceOld, nestedFenceNew, marked.parse);
count(nestedFence, '<code class="language-rust">', 2, "nested list fence remains an atomic before/after unit");
excludes(nestedFence, "<p>let new_name = 1;</p>", "nested fenced code never becomes prose");

// 22) one changed item in a flat list keeps one list and localizes the edit.
const flatListOld = "- unchanged first\n- save_group / forget_group\n- unchanged last";
const flatListNew = "- unchanged first\n- save_group / remove_group\n- unchanged last";
const flatList = renderWordDiff(flatListOld, flatListNew, marked.parse);
count(flatList, "<ul>", 1, "flat list is rendered once rather than split into fragments");
count(flatList, "<li>", 3, "all flat-list items remain in the same list");
includes(flatList, "<del>forget_group</del><ins>remove_group</ins>", "changed list item receives inline detail");

// 23) inline Markdown elsewhere in a paragraph must not promote a tiny change
// to a whole-paragraph replacement. This is the real Forks regression.
const forksOld = "**User's view.** You join “photos”, but two relays host it — `wss://relay.a` and `wss://relay.b` — set up independently.";
const forksNew = "You join “photos”, but two relays host it — `wss://relay.a` and `wss://relay.b` — set up independently.";
const forks = renderWordDiff(forksOld, forksNew, marked.parse);
count(forks, '<div class="wb-mod">', 1, "localized Forks edit stays in one paragraph");
includes(forks, "<del><strong>User&#39;s view.</strong></del> You join", "removed bold label alone is marked");
count(forks, '<code>wss://relay.', 2, "unchanged code spans retain their formatting");
excludes(forks, '<div class="wb-del">', "localized Forks edit has no whole old paragraph");
excludes(forks, '<div class="wb-ins">', "localized Forks edit has no whole new paragraph");

// 24) character references are complete source atoms, not word fragments.
const entities = renderWordDiff("A &amp; B remains.", "A &copy; B remains.", marked.parse, { detail: "more-detail" });
includes(entities, "<del>&amp;</del><ins>&copy;</ins>", "named entities are replaced atomically");
excludes(entities, "<del>amp</del>", "diff tags never enter an entity reference");
const numericEntities = renderWordDiff("A &#123; remains.", "A &#x7B; remains.", passthrough, { detail: "more-detail" });
includes(numericEntities, "<del>&#123;</del><ins>&#x7B;</ins>", "decimal and hexadecimal references stay atomic");
const uppercaseEntities = renderWordDiff("A &#X7B; remains.", "A &#X7C; remains.", passthrough, { detail: "more-detail" });
includes(uppercaseEntities, "<del>&#X7B;</del><ins>&#X7C;</ins>", "uppercase hexadecimal references stay atomic");

// 25) a rewritten sentence inside a stable paragraph uses sentence-level
// before/after in Adaptive, while More detail still offers the raw word view.
const storyOld = "You've been in photos for a long time. Then Alice and Bob fall out and each spins up their own relay — `wss://bob.relay.com` and `wss://alice.relay.com`. NIP-29 now sees two independent groups.";
const storyNew = "You've been in photos for a long time. Then Alice and Bob have a fight, so Alice forks off into a new relay — Bob keeps `wss://bob.relay.com`, Alice opens `wss://alice.relay.com`. NIP-29 now sees two independent groups.";
const calmStory = renderWordDiff(storyOld, storyNew, marked.parse);
count(calmStory, '<div class="wb-del">', 1, "rewritten sentence has one calm before block");
count(calmStory, '<div class="wb-ins">', 1, "rewritten sentence has one calm after block");
excludes(calmStory, "<del>", "Adaptive avoids word-level confetti inside a rewrite");
includes(calmStory, "You&#39;ve been in photos for a long time", "unchanged leading sentence remains context");
includes(calmStory, "NIP-29 now sees two independent groups", "unchanged trailing sentence remains context");
const detailedStory = renderWordDiff(storyOld, storyNew, marked.parse, { detail: "more-detail" });
includes(detailedStory, '<div class="wb-mod">', "More detail retains explicit word-level rewrite view");
includes(detailedStory, "<del>", "More detail exposes inner deletions on demand");

// 26) one difficult item must not promote an entire ordered list to two lists.
const questionsOld = [
  "1. **`ContactList::from_event`.** The operations half is built. Exporting `ContactList` is a vocabulary change needing approval. The README assumes it.",
  "2. **Query builder.** This item is unchanged.",
  "3. **Tag axis.** This item is also unchanged.",
].join("\n");
const questionsNew = [
  "1. **`ContactList::from_event`.** The operations half is built. Export `ContactList`. Vocabulary approved — this is implementation work, not a gate. The README assumes it.",
  "2. **Query builder.** This item is unchanged.",
  "3. **Tag axis.** This item is also unchanged.",
].join("\n");
const questions = renderWordDiff(questionsOld, questionsNew, marked.parse);
count(questions, "<ol", 1, "changed ordered list remains one list");
count(questions, "<li", 3, "changed ordered list keeps one row per logical item");
count(questions, "This item is unchanged", 1, "unchanged list item is not duplicated");
includes(questions, 'start="1"', "changed list retains its starting number");
includes(questions, "Vocabulary approved", "new content appears inside only the changed item");

// 27) rendering item bodies independently must retain task-list checkboxes.
const tasks = renderWordDiff(
  "- [x] already done\n- [ ] old task text",
  "- [x] already done\n- [ ] new task text",
  marked.parse,
);
count(tasks, 'type="checkbox"', 2, "task-list items retain checkbox inputs");
count(tasks, 'checked=""', 1, "checked task remains checked");
excludes(tasks, "[x] already done", "task marker is not rendered as literal text");
excludes(tasks, "[ ] new task text", "unchecked marker is not rendered as literal text");

// 28) repeated source markers still number ordered items sequentially.
const repeatedMarkers = renderWordDiff(
  "1. old text\n1. unchanged text",
  "1. new text\n1. unchanged text",
  marked.parse,
);
count(repeatedMarkers, "<li>", 2, "repeated markers keep two logical items");
excludes(repeatedMarkers, " value=", "source markers do not override sequential numbering");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
