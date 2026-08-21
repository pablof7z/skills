// Node self-test for the unified-diff applier in patch.mjs.
// Run: node whiteboard/cli/patch.test.mjs
import assert from "node:assert";
import { applyUnifiedDiff } from "./patch.mjs";

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) pass++;
  else { fail++; console.error(`FAIL ${msg}`); }
}

// (a) valid single-hunk diff applies
{
  const text = "line1\nline2\nline3";
  const diff = "@@ -2,1 +2,1 @@\n-line2\n+LINE2";
  const out = applyUnifiedDiff(text, diff);
  ok(out === "line1\nLINE2\nline3", "valid single-hunk diff applies: " + JSON.stringify(out));
}

// (b) a diff with a context offset still applies (findAnchor's fuzz window)
{
  const text = "a\nb\nc\nd\ne";
  // hunk claims oldStart 1 but the real match is at line 3 ("c")
  const diff = "@@ -1,1 +1,1 @@\n-c\n+C";
  const out = applyUnifiedDiff(text, diff);
  ok(out === "a\nb\nC\nd\ne", "context-offset diff still applies: " + JSON.stringify(out));
}

// (c) a malformed hunk header throws
{
  assert.throws(() => applyUnifiedDiff("a\nb", "@@ -\n-a\n+A"), /malformed hunk header/, "malformed hunk header throws");
  pass++;
}

// (d) a diff that yields zero hunks throws
{
  assert.throws(() => applyUnifiedDiff("a\nb", "not a diff at all\njust text"), /diff produced no hunks/, "zero-hunk diff throws");
  pass++;
}

// (e) a hunk whose context does not match throws the existing error
{
  assert.throws(
    () => applyUnifiedDiff("a\nb\nc", "@@ -1,1 +1,1 @@\n-zzz\n+Z"),
    /did not apply \(context not found\)/,
    "unmatched context throws"
  );
  pass++;
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
