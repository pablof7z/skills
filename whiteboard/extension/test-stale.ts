// Simulate a stale ctx after session replacement: make hasUI access throw, then
// trigger a watcher poke. The extension must NOT crash (guard catches it).
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
process.env.WHITEBOARD_PROJECT = "extstale";
const mod = await import("./index.ts");
const ext = mod.default;
const sent: string[] = [];
const handlers: Record<string, (e: any, ctx: any) => void> = {};
const mockPi: any = { on: (ev: string, h: any) => { handlers[ev] = h; }, registerCommand: () => {}, sendUserMessage: (t: string) => sent.push(t) };
// ctx whose hasUI getter throws (simulating staleness after replacement)
function makeCtx(stale: boolean) {
  const ui = { setStatus: () => {}, notify: () => {} };
  if (!stale) return { hasUI: false, ui };
  return { ui, get hasUI() { throw new Error("stale ctx"); } };
}
const ctx = makeCtx(false);
const ROOT = path.join(os.homedir(), "whiteboard");
const slug = "2026-08-stale-ctx-test";
const sessDir = path.join(ROOT, "extstale", slug);
fs.mkdirSync(sessDir, { recursive: true });
fs.writeFileSync(path.join(sessDir, "manifest.json"), JSON.stringify({ name: slug, status: "exploring", project: "extstale", createdAt: "2026-08-18T00:00:00Z" }));
fs.writeFileSync(path.join(sessDir, "document.json"), JSON.stringify({ version: 1, docId: "d", rev: 1, blocks: [{ name: "g", md: "## G" }], comments: [], hash: "h" }));
ext(mockPi);
await handlers["session_start"]({}, ctx);
console.log("session_start ok; baseline done. Now making ctx stale (hasUI throws)...");
// mutate the same ctx object the watcher captured: make hasUI throw
Object.defineProperty(ctx, "hasUI", { get() { throw new Error("stale ctx after replacement"); }, configurable: true });
// trigger a watcher event by writing a new actionable comment, then wait for debounce
const d = { version: 1, docId: "d", rev: 2, blocks: [{ name: "g", md: "## G" }], comments: [{ id: "c-stale", block: "g", author: "user", body: "stale poke test", at: new Date().toISOString(), resolved: false, replies: [] }], hash: "h2" };
fs.writeFileSync(path.join(sessDir, "document.json"), JSON.stringify(d));
await new Promise((r) => setTimeout(r, 1200));
console.log("poke fired without crashing. sent:", sent.length, "(wake still works via try/caught pi)");
if (handlers["session_shutdown"]) await handlers["session_shutdown"]({ reason: "quit" }, ctx);
fs.rmSync(path.join(ROOT, "extstale"), { recursive: true, force: true });
console.log("PASS: stale ctx did not crash pi");
process.exit(0);
