// Node self-test for the off-viewport edge-indicator partitioning logic.
// Run: node whiteboard/viewer/edge-indicators.test.mjs
import { partitionEdges } from "./edge-indicators.mjs";

let pass = 0, fail = 0;
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  want: ${e}\n  got:  ${a}`); }
}

const vh = 800;
const rect = (top, height) => ({ top, bottom: top + height, height });

eq(partitionEdges([], vh), { above: [], below: [] }, "no items -> nothing above or below");

eq(
  partitionEdges([rect(-50, 20)], vh),
  { above: [{ index: 0, y: -50 }], below: [] },
  "item fully above the viewport is 'above'",
);

eq(
  partitionEdges([rect(810, 20)], vh),
  { above: [], below: [{ index: 0, y: 810 }] },
  "item fully below the viewport is 'below'",
);

eq(
  partitionEdges([rect(400, 20)], vh),
  { above: [], below: [] },
  "item inside the viewport is neither above nor below",
);

eq(
  partitionEdges([rect(0, 0)], vh),
  { above: [], below: [] },
  "zero-height (detached/hidden) item is ignored",
);

// Nearest-to-viewport-first ordering: above sorts by y descending (closest
// to the top edge first), below sorts by y ascending (closest to the bottom
// edge first) — matches the prior await-edge behavior.
const multiAbove = partitionEdges([rect(-200, 20), rect(-20, 20), rect(-100, 20)], vh);
eq(multiAbove.above.map((e) => e.index), [1, 2, 0], "above items are ordered nearest-first");

const multiBelow = partitionEdges([rect(900, 20), rect(810, 20), rect(850, 20)], vh);
eq(multiBelow.below.map((e) => e.index), [1, 2, 0], "below items are ordered nearest-first");

if (fail) { console.error(`${fail} failed, ${pass} passed`); process.exit(1); }
console.log(`${pass} passed`);
