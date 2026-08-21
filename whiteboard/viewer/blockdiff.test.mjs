// Node self-test for revision review picker labels.
// Run: node whiteboard/viewer/blockdiff.test.mjs
import { buildPickerOptions, latestBlockRevision, reviewBaseline } from "./blockdiff.mjs";

let pass = 0, fail = 0;
function ok(condition, msg) { if (condition) pass++; else { fail++; console.error(`FAIL ${msg}`); } }

const options = buildPickerOptions([{ rev: 2, changes: 1, blocks: 0, at: new Date().toISOString() }], 2, 0);
ok(options[0].meta.includes("to annotations"), "picker identifies annotation-only revisions");
ok(options[0].value === "current" && options[0].labels.includes("Current"), "current rev row carries the current sentinel value + Current label");
ok(!options.some((o) => o.group === "shortcut"), "no separate shortcut group rows");
const lv = buildPickerOptions([{ rev: 2, changes: 1, blocks: 0, at: new Date().toISOString() }, { rev: 1, title: "older", changes: 1, blocks: 0, at: new Date().toISOString() }], 2, 1);
ok(lv.find((o) => Number(o.value) === 1)?.labels.includes("Last viewed"), "viewed (non-current) rev is labeled Last viewed");
ok(lv.find((o) => o.value === "current")?.labels.includes("Current") && !lv.find((o) => o.value === "current").labels.includes("Last viewed"), "current row labeled Current only");
ok(latestBlockRevision([
  { rev: 3, blocks: 1 }, { rev: 4, blocks: 0 }, { rev: 5, blocks: 2 },
], 4) === 3, "annotation-only revisions do not advance the suppressed block revision");
ok(latestBlockRevision([{ rev: 3, blocks: 1 }, { rev: 5, blocks: 2 }], 5) === 5,
  "a newer document mutation advances the suppressed block revision");
const coalesced = [{ rev: 1, blocks: 0 }, { rev: 2, blocks: 1 }, { rev: 3, blocks: 0 }];
const unviewedBaseline = reviewBaseline(coalesced, 3, 0);
ok(unviewedBaseline === 1, "a never-reviewed session uses its oldest available baseline");
ok(coalesced.some((revision) => revision.rev > unviewedBaseline && revision.rev <= 3 && revision.blocks > 0),
  "a coalesced annotation refresh cannot mask the preceding document edit");


console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
