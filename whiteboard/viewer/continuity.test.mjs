import { buildBlockPlan } from "./continuity.mjs";

let passed = 0, failed = 0;
function equal(actual, expected, label) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) { passed++; return; }
  failed++; console.error(`FAIL ${label}\n  expected ${JSON.stringify(expected)}\n  actual   ${JSON.stringify(actual)}`);
}
const block = (name, md, path = "default.md") => ({ name, md, path });

const initial = buildBlockPlan(null, { blocks: [block("a", "A"), block("b", "B")] });
equal(initial.map(({ key, kind }) => [key, kind]), [
  ["default.md\u0000a", "same"], ["default.md\u0000b", "same"],
], "initial render has no synthetic additions");

const before = { blocks: [block("a", "A"), block("gone", "old"), block("b", "B"), block("tail", "old tail")] };
const after = { blocks: [block("a", "A changed"), block("new", "new"), block("b", "B")] };
const changed = buildBlockPlan(before, after);
equal(changed.map(({ block: item, kind }) => [item.name, kind]), [
  ["a", "changed"], ["new", "added"], ["gone", "removed"], ["b", "same"], ["tail", "removed"],
], "changed, added, and removed blocks stay in document context");

const paths = buildBlockPlan(
  { blocks: [block("one", "old", "a.md"), block("two", "same", "b.md")] },
  { blocks: [block("one", "new", "a.md"), block("two", "same", "b.md")] },
  "b.md",
);
equal(paths.map(({ block: item, kind }) => [item.name, kind]), [["two", "same"]], "only the active file is reconciled");

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
