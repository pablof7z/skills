// Node self-test for document-diff empty states.
// Run: node whiteboard/viewer/blockdiff.test.mjs
import { buildPickerOptions, renderBlockDiff } from "./blockdiff.mjs";

let pass = 0, fail = 0;
function ok(condition, msg) { if (condition) pass++; else { fail++; console.error(`FAIL ${msg}`); } }

const before = { blocks: [{ name: "goal", md: "# Goal" }], annotations: [] };
const after = { blocks: [{ name: "goal", md: "# Goal" }], annotations: [{ id: "c-1", kind: "question" }] };
const annotationOnly = renderBlockDiff({ beforeDoc: before, afterDoc: after, renderMarkdown: (md) => md });
ok(annotationOnly.includes("1 annotation changed; document blocks did not."), "annotation-only range is explained");

const edited = renderBlockDiff({ beforeDoc: before, afterDoc: { ...after, blocks: [{ name: "goal", md: "# Revised" }] }, renderMarkdown: (md) => md });
ok(!edited.includes("No document blocks changed"), "block changes retain the normal diff");

const plainBefore = { blocks: [{ name: "goal", md: "Release Monday." }], annotations: [] };
const plainAfter = { blocks: [{ name: "goal", md: "Release Tuesday." }], annotations: [] };
const broad = renderBlockDiff({ beforeDoc: plainBefore, afterDoc: plainAfter, renderMarkdown: (md) => md, detail: "before-after" });
ok(broad.includes('class="wb-del"') && broad.includes('class="wb-ins"'), "detail preference reaches edited blocks");
ok(!broad.includes('class="wb-mod"'), "before-after preference disables inline rendering");

const options = buildPickerOptions([{ rev: 2, changes: 1, blocks: 0, at: new Date().toISOString() }], 2, 0);
ok(options[0].meta.includes("to annotations"), "picker identifies annotation-only revisions");
ok(options[0].value === "current" && options[0].labels.includes("Current"), "current rev row carries the current sentinel value + Current label");
ok(!options.some((o) => o.group === "shortcut"), "no separate shortcut group rows");
const lv = buildPickerOptions([{ rev: 2, changes: 1, blocks: 0, at: new Date().toISOString() }, { rev: 1, title: "older", changes: 1, blocks: 0, at: new Date().toISOString() }], 2, 1);
ok(lv.find((o) => Number(o.value) === 1)?.labels.includes("Last viewed"), "viewed (non-current) rev is labeled Last viewed");
ok(lv.find((o) => o.value === "current")?.labels.includes("Current") && !lv.find((o) => o.value === "current").labels.includes("Last viewed"), "current row labeled Current only");

// Full-file diff: unchanged blocks are rendered as context, not skipped.
const multiBefore = { blocks: [{ name: "goal", md: "# Goal" }, { name: "notes", md: "static text" }], annotations: [] };
const multiAfter = { blocks: [{ name: "goal", md: "# Goal Revised" }, { name: "notes", md: "static text" }], annotations: [] };
const full = renderBlockDiff({ beforeDoc: multiBefore, afterDoc: multiAfter, renderMarkdown: (md) => md });
ok(full.includes("static text"), "unchanged block's markdown is present in the full-file diff");
ok(full.includes('class="block wb-same"'), "unchanged block is marked wb-same, not diff-colored");
ok(full.includes('class="block wb-changed"'), "changed block still gets the wb-changed wrapper");
ok(full.includes('block-md wb-diff'), "changed block still produces word-diff markup");

// Added / removed blocks around a full-file diff.
const addRemoveBefore = { blocks: [{ name: "old-only", md: "gone" }], annotations: [] };
const addRemoveAfter = { blocks: [{ name: "new-only", md: "fresh" }], annotations: [] };
const addRemove = renderBlockDiff({ beforeDoc: addRemoveBefore, afterDoc: addRemoveAfter, renderMarkdown: (md) => md });
ok(addRemove.includes("wb-added") && addRemove.includes("new-only"), "added block gets wb-added");
ok(addRemove.includes("wb-removed") && addRemove.includes("old-only"), "removed-before block is appended with wb-removed");

// No changed/added/removed blocks at all: still the empty-diff message, not
// a "full file" of only-unchanged blocks.
const identicalBefore = { blocks: [{ name: "goal", md: "# Goal" }], annotations: [] };
const identicalAfter = { blocks: [{ name: "goal", md: "# Goal" }], annotations: [] };
const identical = renderBlockDiff({ beforeDoc: identicalBefore, afterDoc: identicalAfter, renderMarkdown: (md) => md });
ok(identical.includes("No document blocks changed"), "identical before/after still returns the empty-diff message");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
