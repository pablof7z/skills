import { threadIsPinned } from "./annotationview.mjs";
import { highlightsMatchSelector, selectorSignature } from "./highlights.mjs";

let passed = 0, failed = 0;
function ok(condition, label) {
  if (condition) passed++;
  else { failed++; console.error(`FAIL ${label}`); }
}

globalThis.document = { activeElement: null };
const inactiveNode = { contains: () => false, querySelector: () => ({ value: "" }) };
ok(threadIsPinned({ activeId: "thread-1" }, { id: "thread-1" }, inactiveNode),
  "an active thread stays pinned when remotely resolved without a draft");
ok(!threadIsPinned({ activeId: "thread-2" }, { id: "thread-1" }, inactiveNode),
  "an inactive resolved thread can fold into its pill");
ok(selectorSignature({ exact: "old", prefix: "a", suffix: "b" }, "question") !==
  selectorSignature({ exact: "new", prefix: "a", suffix: "b" }, "question"),
"selector amendments invalidate the previous highlight signature");
const oldSignature = selectorSignature({ exact: "old" }, "question");
ok(!highlightsMatchSelector([{ dataset: { selectorSignature: oldSignature } }],
  selectorSignature({ exact: "new" }, "question")),
"an amended selector cannot reuse its stale rendered mark");

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
