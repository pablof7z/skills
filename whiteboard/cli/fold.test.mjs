// Node self-test for the fold projection: kinded annotations, legacy mapping,
// H1 reanchoring of block-level comments, rename reanchor, remove hide.
// Run: node whiteboard/cli/fold.test.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fold, readChanges, attachOp, replyOp, resolveOp, tagSetOp, tagClearOp, appendChange } from "./doc.mjs";

let pass = 0, fail = 0;
function ok(cond, msg) { if (cond) pass++; else { fail++; console.error(`FAIL ${msg}`); } }

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "wb-fold-"));
const dir = path.join(ROOT, "skills", "fold-test");
fs.mkdirSync(path.join(dir, "changes"), { recursive: true });
fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ name: "fold-test", status: "exploring", project: "skills", createdAt: new Date().toISOString() }));
const now = () => new Date().toISOString();
const A = (id, kind, block, extra = {}) => ({ op: "attach", id, kind, block, path: "default.md", by: "user", body: "b", at: now(), ...extra });

appendChange(dir, { id: "seed", title: "seed", ops: [
  { op: "add", name: "goal", md: "# Goal\nResolve identity model.", path: "default.md" },
  { op: "add", name: "opts", md: "# Options\n- A\n- B", path: "default.md" },
]});

// new kinds project as threads/tags with isTag
appendChange(dir, { id: "r1", title: "q", ops: [ attachOp("question", "goal", { body: "per-key?", selector: { exact: "Resolve identity model.", prefix: "", suffix: "" }, by: "user" }) ] });
appendChange(dir, { id: "r2", title: "tag", ops: [ tagSetOp({ attachments: [] }, "opts", "superseded", { selector: { exact: "- A", prefix: "", suffix: "" } }) ] });
let d = fold(readChanges(dir));
const q = d.annotations.find((a) => a.kind === "question");
const tg = d.annotations.find((a) => a.kind === "superseded");
ok(q && q.isTag === false, "question projects as thread");
ok(tg && tg.isTag === true, "superseded projects as tag");
ok(d.blocks.every((b) => !b.flags), "no block.flags field (tags derive from annotations)");

// reply + resolve on a thread
const qid = q.id;
appendChange(dir, { id: "r3", title: "reply+resolve", ops: [ replyOp(qid, "no, per-session", { by: "agent" }), resolveOp(qid, true) ] });
d = fold(readChanges(dir));
const q2 = d.annotations.find((a) => a.id === qid);
ok(q2.replies.length === 1 && q2.replies[0].author === "agent", "reply recorded");
ok(q2.resolved === true, "resolve reflected");
ok(d.annotations.every((a) => a.motivation === undefined), "no motivation field in projection");

// legacy: kind:"comment" -> note; null selector -> synthesized H1 anchor
appendChange(dir, { id: "r4", title: "legacy-comment", ops: [ A("c-leg", "comment", "goal", { selector: null, body: "old block comment" }) ] });
d = fold(readChanges(dir));
const leg = d.annotations.find((a) => a.id === "c-leg");
ok(leg && leg.kind === "note" && leg.isTag === false, "legacy comment -> note thread");
ok(leg.selector && leg.selector.exact === "Goal", "legacy block-level comment reanchored to H1");

// legacy: needs-attention + motivation highlighting -> needs-attention tag (no motivation)
appendChange(dir, { id: "r5", title: "legacy-attn", ops: [ A("c-attn", "needs-attention", "goal", { selector: { exact: "Resolve identity model." }, motivation: "highlighting", body: "look here" }) ] });
d = fold(readChanges(dir));
const attn = d.annotations.find((a) => a.id === "c-attn");
ok(attn && attn.kind === "needs-attention" && attn.isTag === true, "legacy attention -> needs-attention tag");
ok(attn.motivation === undefined, "motivation dropped from legacy attention");

// rename reanchors annotations to the new block name
appendChange(dir, { id: "r6", title: "rename", ops: [ { op: "rename", from: "goal", to: "objective", path: "default.md" } ] });
d = fold(readChanges(dir));
ok(d.blocks.some((b) => b.name === "objective") && !d.blocks.some((b) => b.name === "goal"), "rename applied");
ok(d.annotations.filter((a) => a.block === "objective").length >= 2, "annotations reanchored to renamed block");
ok(d.annotations.every((a) => a.block !== "goal"), "no annotation left on old name");

// remove hides annotations on the removed block (state removed -> not in projection)
appendChange(dir, { id: "r7", title: "remove", ops: [ { op: "remove", names: ["opts"], path: "default.md" } ] });
d = fold(readChanges(dir));
ok(!d.blocks.some((b) => b.name === "opts"), "block removed");
ok(!d.annotations.some((a) => a.block === "opts"), "tag on removed block hidden from projection");

// tag clear (detach) removes the tag from projection
const ttag = tagSetOp({ attachments: [] }, "objective", "decided", { selector: { exact: "Resolve identity model." } });
appendChange(dir, { id: "r8", title: "set-decided", ops: [ttag] });
d = fold(readChanges(dir));
ok(d.annotations.some((a) => a.kind === "decided" && a.block === "objective"), "decided tag set");
const existing = d.attachments.find((a) => a.kind === "decided" && a.block === "objective" && a.state === "active");
appendChange(dir, { id: "r9", title: "clear-decided", ops: [ tagClearOp({ attachments: d.attachments }, "objective", "decided", { selector: { exact: "Resolve identity model." } }) ] });
d = fold(readChanges(dir));
ok(!d.annotations.some((a) => a.kind === "decided" && a.block === "objective"), "decided tag cleared");

fs.rmSync(ROOT, { recursive: true, force: true });
if (fail) { console.error(`${fail} failed, ${pass} passed`); process.exit(1); }
console.log(`${pass} passed`);