// Mock-pi test for the whiteboard extension wake path.
// Run: node --experimental-strip-types extension/test-wake.mjs
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

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

ext(mockPi);
if (!handlers["session_start"]) throw new Error("session_start handler not registered");
await handlers["session_start"]({}, mockCtx);
console.log("session_start ran; baseline taken.");

// Create a fresh session + post a NEW user chat (after baseline, so it should wake).
const sd = path.join(os.homedir(), "whiteboard", "exttest", "2026-08-wake-test");
fs.mkdirSync(path.join(sd, "chat"), { recursive: true });
fs.mkdirSync(path.join(sd, "comments"), { recursive: true });
fs.writeFileSync(path.join(sd, "manifest.json"), JSON.stringify({ name: "wake test", status: "exploring", project: "exttest", createdAt: "2026-08-17T00:00:00Z" }));
fs.writeFileSync(path.join(sd, "deliverable.md"), "# Wake test\n");
const msg = { id: "urn:uuid:waketest-1", role: "user", text: "please explain the open questions", created: new Date().toISOString() };
fs.writeFileSync(path.join(sd, "chat", `${Date.now()}-waketest.json`), JSON.stringify(msg));

// Wait for the 400ms debounce + scan.
await new Promise((r) => setTimeout(r, 1500));

console.log("sendUserMessage calls:", sent.length);
for (const s of sent) console.log("  ->", s.split("\n")[0]);
if (!sent.some((s) => s.includes("chat") && s.includes("explain the open questions"))) {
  console.error("FAIL: expected a chat wake message");
  process.exit(1);
}
console.log("PASS: extension woke the agent on a new chat message.");

// Cleanup the test session.
fs.rmSync(path.join(os.homedir(), "whiteboard", "exttest"), { recursive: true, force: true });

// Shutdown to close the watcher.
if (handlers["session_shutdown"]) await handlers["session_shutdown"]({ reason: "quit" }, mockCtx);
process.exit(0);