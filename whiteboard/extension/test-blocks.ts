// Mock-pi test for the whiteboard extension block-doc wake path.
// Run: node --experimental-strip-types extension/test-blocks.mjs
//
// Verifies:
//  (1) a block-doc session with a NEW actionable `user` comment in
//      document.json produces a wake;
//  (2) a document.json with only `agent`-authored / resolved comments does NOT
//      wake;
//  (3) a block-doc session in a DIFFERENT project does NOT wake.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

// Force the test session's project to match this pi session's project scoping.
process.env.WHITEBOARD_PROJECT = "extblocks";
const mod = await import("./index.ts");
const ext = mod.default;

const sent: string[] = [];
const handlers: Record<string, (e: any, ctx: any) => void> = {};
const mockPi: any = {
  on: (ev: string, h: any) => { handlers[ev] = h; },
  registerCommand: () => {},
  sendUserMessage: (text: string) => { sent.push(text); },
};
const mockCtx = { hasUI: false, ui: { setStatus: () => {}, notify: () => {} } };

const ROOT = path.join(os.homedir(), "whiteboard");
const PROJ = "extblocks";
const OTHER = "extother";
const slug = "2026-08-block-wake-test";
const sessDir = path.join(ROOT, PROJ, slug);
const otherDir = path.join(ROOT, OTHER, slug);

function writeDoc(dir, doc) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "document.json"), JSON.stringify(doc, null, 2) + "\n");
  // manifest so the dir is recognized as a session
  fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({
    name: slug, status: "exploring", project: PROJ, createdAt: "2026-08-17T00:00:00Z",
  }) + "\n");
}

function freshDoc(rev = 1) {
  return { version: 1, docId: "deliverable", rev, blocks: [{ name: "goal", md: "## Goal\n" }], comments: [], hash: "abc123" };
}

// Seed an initial doc (no actionable comments) before session_start so the
// rev/comment-id baseline is taken against it.
writeDoc(sessDir, freshDoc(1));
writeDoc(otherDir, freshDoc(1));

ext(mockPi);
if (!handlers["session_start"]) throw new Error("session_start handler not registered");
await handlers["session_start"]({}, mockCtx);
console.log("session_start ran; baseline taken. sent so far:", sent.length);
if (sent.length !== 0) throw new Error("baseline should not wake");

// (1) NEW actionable user comment in our project -> wake.
const d1 = freshDoc(2);
d1.comments.push({ id: "c-new1", block: "goal", author: "user", body: "why blocks over flat markdown here", at: new Date().toISOString(), resolved: false, replies: [] });
writeDoc(sessDir, d1);
// (2) agent-authored + resolved comments -> no wake. Add to OTHER project so we
// also exercise cross-project scoping for the non-actionable case.
const dOther = freshDoc(2);
dOther.comments.push({ id: "c-agent", block: "goal", author: "agent", body: "agent note", at: new Date().toISOString(), resolved: false, replies: [] });
dOther.comments.push({ id: "c-resolved", block: "goal", author: "user", body: "resolved q", at: new Date().toISOString(), resolved: true, replies: [] });
writeDoc(otherDir, dOther);
// (3) an actionable user comment in OTHER project -> must NOT wake us.
const dOther2 = freshDoc(3);
dOther2.comments.push({ id: "c-otherproj", block: "goal", author: "user", body: "should not wake this session", at: new Date().toISOString(), resolved: false, replies: [] });
writeDoc(otherDir, dOther2);

// Wait for the 400ms debounce + scan.
await new Promise((r) => setTimeout(r, 1500));

console.log("sendUserMessage calls:", sent.length);
for (const s of sent) console.log("  ->", s.split("\n")[0]);

const wokeNew = sent.some((s) => s.includes("New comment on block") && s.includes("c-new1") && s.includes("why blocks"));
if (!wokeNew) { console.error("FAIL: expected a wake for the new actionable user comment"); process.exit(1); }
console.log("PASS: woke on new actionable user comment.");

const wokeAgent = sent.some((s) => s.includes("c-agent"));
const wokeResolved = sent.some((s) => s.includes("c-resolved"));
if (wokeAgent || wokeResolved) { console.error("FAIL: should not wake for agent/resolved comments"); process.exit(1); }
console.log("PASS: did not wake for agent/resolved comments.");

const wokeOther = sent.some((s) => s.includes("c-otherproj") || s.includes("should not wake"));
if (wokeOther) { console.error("FAIL: should not wake for a different project's session"); process.exit(1); }
console.log("PASS: did not wake for a different project's session.");

// Cleanup.
fs.rmSync(path.join(ROOT, PROJ), { recursive: true, force: true });
fs.rmSync(path.join(ROOT, OTHER), { recursive: true, force: true });

if (handlers["session_shutdown"]) await handlers["session_shutdown"]({ reason: "quit" }, mockCtx);
process.exit(0);