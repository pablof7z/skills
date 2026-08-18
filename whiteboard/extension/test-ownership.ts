// Two agents (two pi session ids). Session owned by agent-A. A new comment
// should wake ONLY agent-A's extension, not agent-B's.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
process.env.WHITEBOARD_PROJECT = "skills";
const mod = await import("./index.ts");
const ext = mod.default;
const ROOT = path.join(os.homedir(), "whiteboard");
const slug = "2026-08-ownership-wake-test";
const sessDir = path.join(ROOT, "skills", slug);
fs.mkdirSync(sessDir, { recursive: true });
fs.writeFileSync(path.join(sessDir, "manifest.json"), JSON.stringify({ name: slug, status: "exploring", project: "skills", createdAt: "2026-08-18T00:00:00Z", owner: "agent-A" }));
fs.writeFileSync(path.join(sessDir, "document.json"), JSON.stringify({ version: 1, docId: "d", rev: 1, blocks: [{ name: "goal", md: "## Goal" }], comments: [], hash: "h" }));

function makeAgent(sessionId: string) {
  const sent: string[] = [];
  const handlers: Record<string, (e: any, ctx: any) => void> = {};
  const pi: any = { on: (ev: string, h: any) => { handlers[ev] = h; }, registerCommand: () => {}, sendUserMessage: (t: string) => sent.push(t) };
  const ctx: any = { ui: { setStatus: () => {}, notify: () => {} }, get hasUI() { return true; }, sessionManager: { getSessionId: () => sessionId, getSessionFile: () => `/tmp/${sessionId}.json` } };
  ext(pi);
  return { pi, ctx, handlers, sent };
}
const A = makeAgent("agent-A");
const B = makeAgent("agent-B");
await A.handlers["session_start"]({}, A.ctx); // A owns the session
await B.handlers["session_start"]({}, B.ctx); // B does not
// add an actionable user comment, triggering both watchers
const d = { version: 1, docId: "d", rev: 2, blocks: [{ name: "goal", md: "## Goal" }], comments: [{ id: "c-own1", block: "goal", author: "user", body: "only A should see this", at: new Date().toISOString(), resolved: false, replies: [] }], hash: "h2" };
fs.writeFileSync(path.join(sessDir, "document.json"), JSON.stringify(d));
await new Promise((r) => setTimeout(r, 1200));
console.log("agent-A wakes:", A.sent.length, A.sent.length ? `-> ${A.sent[0].slice(0,40)}...` : "");
console.log("agent-B wakes:", B.sent.length, B.sent.length ? "-> UNEXPECTED" : "(none)");
await A.handlers["session_shutdown"]?.({ reason: "quit" }, A.ctx);
await B.handlers["session_shutdown"]?.({ reason: "quit" }, B.ctx);
fs.rmSync(sessDir, { recursive: true, force: true });
const ok = A.sent.length === 1 && B.sent.length === 0;
console.log(ok ? "PASS: only the owning agent woke; the other did not." : "FAIL");
process.exit(ok ? 0 : 1);
