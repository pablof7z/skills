// Node self-test for compact ToC peek decisions.
// Run: node whiteboard/viewer/toc-rail.test.mjs
import { TOC_COMPACT_MAX, isCompactWidth, peekClick } from "./toc-rail.mjs";

let pass = 0, fail = 0;
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) pass++;
  else { fail++; console.error(`FAIL ${msg}\n  want: ${e}\n  got:  ${a}`); }
}

eq(isCompactWidth(TOC_COMPACT_MAX), true, "threshold is compact");
eq(isCompactWidth(TOC_COMPACT_MAX + 1), false, "one pixel over is wide");
eq(isCompactWidth(800), true, "phone/narrow window is compact");
eq(isCompactWidth(1440), false, "desktop is wide");

eq(peekClick(false, false, true), { open: false, consume: false }, "wide: heading click jumps, no overlay");
eq(peekClick(true, false, true), { open: true, consume: true }, "collapsed peek swallows heading tap and opens");
eq(peekClick(true, false, false), { open: true, consume: true }, "collapsed peek tap on chrome opens");
eq(peekClick(true, true, true), { open: false, consume: false }, "open overlay: heading tap jumps and closes");
eq(peekClick(true, true, false), { open: true, consume: false }, "open overlay: chrome tap stays open");

if (fail) { console.error(`${fail} failed, ${pass} passed`); process.exit(1); }
console.log(`${pass} passed`);
