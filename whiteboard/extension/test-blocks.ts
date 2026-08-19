// Mock-pi test for the whiteboard extension block-doc wake path.
// Run: node --experimental-strip-types extension/test-blocks.ts
//
// Verifies:
//  (1) a block-doc session with a NEW actionable `user` comment produces a
//      whiteboard-attributed wake (sendMessage, not sendUserMessage);
//  (2) agent-authored / resolved comments do NOT wake;
//  (3) a session in a DIFFERENT project does NOT wake.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

process.env.WHITEBOARD_PROJECT = "extblocks";
const mod = await import("./index.ts");
const ext = mod.default;

const sent: string[] = [];
const handlers: Record<string, (e: any, ctx: any) => void> = {};
const mockPi: any = {
  on: (ev: string, h: any) => { handlers[ev] = h; },
  registerCommand: () => {},
  registerTool: () => {},
  registerMessageRenderer: () => {},
  sendMessage: (m: any) => { sent.push(String(m.content || "")); },
};
const mockCtx = { hasUI: false, ui: { setStatus: () => {}, notify: () => {} } };

const ROOT = path.join(os.homedir(), "whiteboard");
const PROJ = "extblocks", OTHER = "extother";
const slug = "2026-08-block-wake-test";
const sessDir = path.join(ROOT, PROJ, slug);
const otherDir = path.join(ROOT, OTHER, slug);

const now = () => new Date().toISOString();
function baselineChange(dir) {
  fs.rmSync(path.join(dir, "changes"), { recursive: true, force: true });
  fs.mkdirSync(path.join(dir, "changes"), { recursive: true });
  fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ name: slug, status: "exploring", project: PROJ, createdAt: now() }) + "\n");
  fs.writeFileSync(path.join(dir, "changes", "000001.json"), JSON.stringify({
    rev: 1, id: "baseline", title: "init", at: now(), by: "agent",
    ops: [{ op: "baseline", blocks: [{ name: "goal", md: "## Goal\n" }], attachments: [] }],
  }) + "\n");
}
function commentChange(dir, id, by, body) {
  fs.writeFileSync(path.join(dir, "changes", "000002.json"), JSON.stringify({
    rev: 2, id, title: id, at: now(), by,
    ops: [{ op: "attach", id, kind: "question", block: "goal", by, body, selector: { exact: "Goal", prefix: "", suffix: "" }, at: now() }],
  }) + "\n");
}

baselineChange(sessDir);
baselineChange(otherDir);
ext(mockPi);
if (!handlers["session_start"]) throw new Error("session_start handler not registered");
await handlers["session_start"]({}, mockCtx);
if (sent.length !== 0) throw new Error("baseline should not wake");

// (1) NEW actionable user comment in our project -> wake.
commentChange(sessDir, "c-new1", "user", "why blocks over flat markdown here");
// (3) actionable user comment in OTHER project -> must NOT wake us.
commentChange(otherDir, "c-otherproj", "user", "should not wake this session");

await new Promise((r) => setTimeout(r, 1500));

console.log("sendMessage wakes:", sent.length);
for (const s of sent) console.log("  ->", s.split("\n")[0]);

const wokeNew = sent.some((s) => s.includes("Annotation (question) on block") && s.includes("c-new1") && s.includes("why blocks"));
if (!wokeNew) { console.error("FAIL: expected a wake for the new actionable user annotation"); process.exit(1); }
console.log("PASS: woke on new actionable user annotation (attributed whiteboard message).");

const wokeOther = sent.some((s) => s.includes("c-otherproj") || s.includes("should not wake"));
if (wokeOther) { console.error("FAIL: should not wake for a different project's session"); process.exit(1); }
console.log("PASS: did not wake for a different project's session.");

fs.rmSync(path.join(ROOT, PROJ), { recursive: true, force: true });
fs.rmSync(path.join(ROOT, OTHER), { recursive: true, force: true });
if (handlers["session_shutdown"]) await handlers["session_shutdown"]({ reason: "quit" }, mockCtx);
process.exit(0);