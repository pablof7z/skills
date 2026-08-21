// Standalone test for the wb_apply tool: applies an array of ops atomically,
// and verifies a failing op leaves the doc untouched (all-or-nothing).
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const ROOT = path.join(os.tmpdir(), "wb-apply-test-" + process.pid);
fs.rmSync(ROOT, { recursive: true, force: true });
const DIR = path.join(ROOT, "testproj", "wbapply-test");
fs.mkdirSync(DIR, { recursive: true });
fs.writeFileSync(path.join(DIR, "manifest.json"), JSON.stringify({ name: "wbapply-test", status: "exploring", project: "testproj", createdAt: new Date().toISOString(), owner: null }));
// ROOT is read at module load in store.mjs, so the env must be set BEFORE import.
process.env.WHITEBOARD_ROOT = ROOT;
const { registerWhiteboardTools, setCurrentSession } = await import("../extension/tool.mjs");
const { loadDoc, appendChange } = await import("../cli/doc.mjs");
// seed an initial block so the doc exists
appendChange(DIR, { id: "seed", title: "seed", ops: [{ op: "add", name: "intro", md: "# Intro\noriginal", path: "default.md" }] });
setCurrentSession("testproj/wbapply-test");

// Mock typebox (only shape matters for registration) + a capturing pi.
const Type = {
  Object: (props, o) => ({ kind: "object", props, ...(o || {}) }),
  Optional: (t) => ({ kind: "optional", of: t }),
  Union: (arr, o) => ({ kind: "union", of: arr, ...(o || {}) }),
  Literal: (s) => ({ kind: "literal", val: s }),
  String: (d) => ({ kind: "string", ...(d || {}) }),
  Number: (d) => ({ kind: "number", ...(d || {}) }),
  Array: (t, d) => ({ kind: "array", of: t, ...(d || {}) }),
  Boolean: (d) => ({ kind: "boolean", ...(d || {}) }),
};
const tools = {};
const pi = { registerTool: (t) => { tools[t.name] = t; }, getActiveTools: () => [], setActiveTools: () => {} };
registerWhiteboardTools(pi, Type);
const apply = (params) => tools.wb_apply.execute(null, params, null, null, { sessionManager: { getSessionId: () => "test-sid" } });

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; } else { fail++; console.log("  FAIL:", m); } };

// 1) valid multi-op apply succeeds as one change
let r = await apply({ title: "ok change", ops: [
  { op: "add", name: "goal", text: "# Goal\nbuild it" },
  { op: "edit", block: "intro", text: "# Intro\nedited" },
] });
ok(!r.isError, "1 success (no error): " + JSON.stringify(r.content?.[0]?.text));
let doc = loadDoc(DIR);
ok(doc.blocks.length === 2, "1 has 2 blocks, got " + doc.blocks.length);
ok(doc.blocks.find((b) => b.name === "goal"), "1 goal added");
ok(doc.blocks.find((b) => b.name === "intro").md.includes("edited"), "1 intro edited");
const revAfter1 = doc.rev;

// 2) all-or-nothing: an invalid op in the array rejects the WHOLE change
r = await apply({ title: "bad change", ops: [
  { op: "add", name: "ghost", text: "# Ghost" },
  { op: "edit", block: "nope-not-here", text: "x" }, // invalid — no such block
] });
ok(r.isError, "2 rejected (error): " + JSON.stringify(r.content?.[0]?.text));
doc = loadDoc(DIR);
ok(doc.blocks.length === 2, "2 no blocks added (ghost NOT created), got " + doc.blocks.length);
ok(!doc.blocks.find((b) => b.name === "ghost"), "2 ghost not present");
ok(doc.rev === revAfter1, "2 rev unchanged (" + doc.rev + " vs " + revAfter1 + ")");

// 3) edit-by-diff can patch a block added earlier in the same apply (WIP order)
r = await apply({ title: "diff chain", ops: [
  { op: "add", name: "notes", text: "# Notes\nold line" },
  { op: "edit", block: "notes", diff: "@@ -2,1 +2,1 @@\n-old line\n+new line" },
] });
ok(!r.isError, "3 success: " + JSON.stringify(r.content?.[0]?.text));
doc = loadDoc(DIR);
const notes = doc.blocks.find((b) => b.name === "notes");
ok(notes && notes.md.includes("new line") && !notes.md.includes("old line"), "3 diff applied to added block: " + (notes ? notes.md : "no notes block"));

// 4) unknown op rejected, nothing written
const revBefore4 = loadDoc(DIR).rev;
r = await apply({ title: "bad op", ops: [{ op: "explode", name: "x", text: "y" }] });
ok(r.isError, "4 rejected unknown op");
ok(loadDoc(DIR).rev === revBefore4, "4 rev unchanged");

// 5) malformed diff in an edit op: rejected, doc unchanged, rev unchanged
const revBefore5 = loadDoc(DIR).rev;
r = await apply({ title: "malformed diff", ops: [
  { op: "edit", block: "intro", diff: "@@ -\n-x\n+y" },
] });
ok(r.isError, "5 rejected (malformed diff): " + JSON.stringify(r.content?.[0]?.text));
ok(loadDoc(DIR).rev === revBefore5, "5 rev unchanged");
ok(loadDoc(DIR).blocks.find((b) => b.name === "intro").md.includes("edited"), "5 intro content unchanged");

console.log(`\n${pass} passed, ${fail} failed`);
fs.rmSync(ROOT, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
