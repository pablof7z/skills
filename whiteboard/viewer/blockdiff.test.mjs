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

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
