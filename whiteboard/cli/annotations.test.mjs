// Node self-test for the direct annotation commands (wb attach / wb tag).
// Run: node whiteboard/cli/annotations.test.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  attachCreate, attachReply, attachResolve, attachReopen, tagSet, tagClear, listAnnotations,
} from "./annotations.mjs";
import { appendChange } from "./doc.mjs";
import { isActionable } from "./scan.mjs";

let pass = 0, fail = 0;
function ok(cond, msg) { if (cond) pass++; else { fail++; console.error(`FAIL ${msg}`); } }
function expectThrow(fn, msg) { try { fn(); fail++; console.error(`FAIL ${msg} (did not throw)`); } catch (e) { pass++; } }

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "wb-ann-"));
process.env.WHITEBOARD_ROOT = ROOT;
const dir = path.join(ROOT, "skills", "ann-test");
fs.mkdirSync(path.join(dir, "changes"), { recursive: true });
fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ name: "ann-test", status: "exploring", project: "skills", createdAt: new Date().toISOString() }));
const session = { project: "skills", slug: "ann-test", dir };
appendChange(dir, { id: "seed", title: "seed", ops: [
  { op: "add", name: "goal", md: "# Goal\nBuild the thing.\n- option A\n- option B", path: "default.md" },
] });

// --- attach: kind validation + --on required + content required ---
expectThrow(() => attachCreate(session, { block: "goal", on: "Build the thing.", kind: "query", content: "x" }), "bad attach kind rejected");
expectThrow(() => attachCreate(session, { block: "goal", kind: "question", content: "x" }), "missing --on rejected");
expectThrow(() => attachCreate(session, { block: "goal", on: "Build the thing.", kind: "question" }), "missing --content rejected");
expectThrow(() => attachCreate(session, { block: "nope", on: "x", kind: "question", content: "x" }), "bad block rejected");
expectThrow(() => attachCreate(session, { block: "goal", on: "missing quote", kind: "question", content: "x" }), "anchor not found rejected");

// --- attach create + reply + resolve + reopen lifecycle ---
const r1 = attachCreate(session, { block: "goal", on: "Build the thing.", kind: "question", content: "is this right?", by: "user" });
ok(r1.includes("question") && r1.includes("rev"), "attach create returns kind + rev");
const id = r1.match(/(c-[0-9a-f]+)/)[1];
const r2 = attachReply(session, id, { content: "yes, looks fine", by: "agent" });
ok(r2.includes("reply"), "attach reply");
attachResolve(session, id);
const { loadDoc } = await import("./doc.mjs");
let doc = loadDoc(dir);
let th = doc.annotations.find((a) => a.id === id);
ok(th.resolved === true, "attach resolve marks resolved");
attachReopen(session, id);
doc = loadDoc(dir);
th = doc.annotations.find((a) => a.id === id);
ok(th.resolved === false, "attach reopen clears resolved");
ok(th.replies.length === 1 && th.replies[0].author === "agent", "reply recorded");

// --- note is NOT actionable; question IS ---
ok(isActionable(th) === false, "question with an agent reply is not actionable");
const noteRes = attachCreate(session, { block: "goal", on: "Build the thing.", kind: "note", content: "fyi", by: "user" });
const noteId = noteRes.match(/(c-[0-9a-f]+)/)[1];
doc = loadDoc(dir);
const note = doc.annotations.find((a) => a.id === noteId);
ok(isActionable(note) === false, "note is never actionable");

// --- tag: idempotent set + clear + kind validation ---
const t1 = tagSet(session, { block: "goal", on: "- option A", kind: "superseded" });
ok(t1.includes("superseded"), "tag set");
const t2 = tagSet(session, { block: "goal", on: "- option A", kind: "superseded" });
ok(t2.includes("nothing to do"), "tag set idempotent");
const t3 = tagSet(session, { block: "goal", on: "- option B", kind: "unverified", content: "check this" });
ok(t3.includes("unverified"), "tag set with body");
// same kind, different span -> NOT idempotent (different anchor)
const t4 = tagSet(session, { block: "goal", on: "Build the thing.", kind: "superseded" });
ok(t4.includes("rev"), "same tag kind on a different span is a new tag");
// clear
const c1 = tagClear(session, { block: "goal", on: "- option A", kind: "superseded" });
ok(c1.includes("cleared"), "tag clear");
const c2 = tagClear(session, { block: "goal", on: "- option A", kind: "superseded" });
ok(c2.includes("nothing to clear"), "tag clear idempotent");
expectThrow(() => tagSet(session, { block: "goal", on: "x", kind: "question" }), "tag rejects attach kind");
expectThrow(() => tagSet(session, { block: "goal", kind: "superseded" }), "tag requires --on");

// --- list ---
const listed = listAnnotations(session, {});
ok(listed.split("\n").length >= 3, "listAnnotations returns rows");

fs.rmSync(ROOT, { recursive: true, force: true });
if (fail) { console.error(`${fail} failed, ${pass} passed`); process.exit(1); }
console.log(`${pass} passed`);