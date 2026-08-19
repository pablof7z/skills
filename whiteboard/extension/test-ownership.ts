// Two agents (two pi session ids). Session owned by agent-A. A new actionable
// user comment should wake ONLY agent-A's extension, not agent-B's.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

process.env.WHITEBOARD_PROJECT = "skills";
const mod = await import("./index.ts");
const ext = mod.default;
const ROOT = path.join(os.homedir(), "whiteboard");
const slug = "2026-08-ownership-wake-test";
const sessDir = path.join(ROOT, "skills", slug);
const now = () => new Date().toISOString();

fs.mkdirSync(path.join(sessDir, "changes"), { recursive: true });
fs.writeFileSync(path.join(sessDir, "manifest.json"), JSON.stringify({ name: slug, status: "exploring", project: "skills", createdAt: now(), owner: "agent-A" }));
fs.writeFileSync(path.join(sessDir, "changes", "000001.json"), JSON.stringify({
  rev: 1, id: "baseline", title: "init", at: now(), by: "agent",
  ops: [{ op: "baseline", blocks: [{ name: "goal", md: "## Goal" }], attachments: [] }],
}));

function makeAgent(sessionId: string) {
  const sent: string[] = [];
  const handlers: Record<string, (e: any, ctx: any) => void> = {};
  const pi: any = {
    on: (ev: string, h: any) => { handlers[ev] = h; },
    registerCommand: () => {}, registerTool: () => {}, registerMessageRenderer: () => {},
    sendMessage: (m: any) => sent.push(String(m.content || "")),
  };
  const ctx: any = { ui: { setStatus: () => {}, notify: () => {} }, get hasUI() { return true; }, sessionManager: { getSessionId: () => sessionId, getSessionFile: () => `/tmp/${sessionId}.json` } };
  ext(pi);
  return { pi, ctx, handlers, sent };
}
const A = makeAgent("agent-A");
const B = makeAgent("agent-B");
await A.handlers["session_start"]({}, A.ctx); // A owns the session
await B.handlers["session_start"]({}, B.ctx); // B does not
// add an actionable user comment, triggering both watchers
fs.writeFileSync(path.join(sessDir, "changes", "000002.json"), JSON.stringify({
  rev: 2, id: "c-own1", title: "c-own1", at: now(), by: "user",
  ops: [{ op: "attach", id: "c-own1", kind: "comment", block: "goal", by: "user", body: "only A should see this", selector: null, motivation: null, at: now() }],
}));
await new Promise((r) => setTimeout(r, 1200));
console.log("agent-A wakes:", A.sent.length, A.sent.length ? `-> ${A.sent[0].slice(0, 40)}...` : "");
console.log("agent-B wakes:", B.sent.length, B.sent.length ? "-> UNEXPECTED" : "(none)");
await A.handlers["session_shutdown"]?.({ reason: "quit" }, A.ctx);
await B.handlers["session_shutdown"]?.({ reason: "quit" }, B.ctx);
fs.rmSync(sessDir, { recursive: true, force: true });
const ok = A.sent.length === 1 && B.sent.length === 0;
console.log(ok ? "PASS: only the owning agent woke; the other did not." : "FAIL");
process.exit(ok ? 0 : 1);