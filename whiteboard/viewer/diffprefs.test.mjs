import {
  DIFF_DETAIL_KEY, loadDiffDetail, normalizeDiffDetail, saveDiffDetail,
} from "./diffprefs.mjs";

let pass = 0, fail = 0;
function eq(actual, expected, msg) {
  if (actual === expected) pass++;
  else { fail++; console.error(`FAIL ${msg}: ${actual} !== ${expected}`); }
}

const values = new Map();
const storage = {
  getItem: (key) => values.get(key) ?? null,
  setItem: (key, value) => values.set(key, value),
};

eq(normalizeDiffDetail(null), "adaptive", "missing preference defaults to Adaptive");
eq(normalizeDiffDetail("word"), "adaptive", "invalid preference defaults to Adaptive");
eq(saveDiffDetail("more-detail", storage), "more-detail", "valid preference is saved");
eq(values.get(DIFF_DETAIL_KEY), "more-detail", "preference uses the stable storage key");
eq(loadDiffDetail(storage), "more-detail", "saved preference is restored");
eq(saveDiffDetail("unknown", storage), "adaptive", "invalid saved value is normalized");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
