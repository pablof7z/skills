// End-to-end CLI and Pi-tool regression for revision diffs.

import assert from "node:assert";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "wb-diff-test-"));
process.env.WHITEBOARD_ROOT = root;
const dir = path.join(root, "testproj", "versions");
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ name: "versions", project: "testproj" }));

try {
  const { appendChange } = await import("../cli/doc.mjs");
  appendChange(dir, { id: "seed", title: "seed", ops: [{ op: "add", name: "goal", md: "# Goal\nold", path: "default.md" }] });
  appendChange(dir, { id: "revise", title: "revise", ops: [
    { op: "edit", name: "goal", md: "# Goal\nnew", path: "default.md" },
    { op: "add", name: "notes", md: "# Notes\nadded", path: "references/notes.md" },
  ] });

  const here = path.dirname(fileURLToPath(import.meta.url));
  const cli = path.join(here, "..", "cli", "main.mjs");
  const command = (args) => execFileSync(process.execPath, [cli, ...args], { encoding: "utf8", env: process.env });
  const full = command(["diff", "1", "2", "--session", "testproj/versions"]);
  assert.match(full, /diff --git a\/rev-1\/default\.md b\/rev-2\/default\.md/);
  assert.match(full, /-old/);
  assert.match(full, /\+new/);
  assert.match(full, /references\/notes\.md/);
  assert.match(full, /new file mode/);
  const scoped = command(["diff", "1", "2", "--path", "default.md", "--session", "testproj/versions"]);
  assert.doesNotMatch(scoped, /references\/notes\.md/);

  const { activateInitialTools, registerWhiteboardTools, setCurrentSession } = await import("./tool.mjs");
  const Type = {
    Object: (shape) => ({ shape }), String: () => ({}), Number: () => ({}), Boolean: () => ({}),
    Optional: (value) => value, Union: (values) => values, Literal: (value) => value, Array: (value) => [value],
  };
  const tools = {}, pi = { active: ["shell"], registerTool: (tool) => { tools[tool.name] = tool; }, getActiveTools: () => pi.active, setActiveTools: (names) => { pi.active = names; } };
  registerWhiteboardTools(pi, Type);
  activateInitialTools(pi, false);
  assert.deepEqual(pi.active, ["shell", "wb_new", "wb_list"]);
  activateInitialTools(pi, true);
  assert.ok(pi.active.includes("wb_diff"), "wb_diff is active for a session-owning Pi agent");
  setCurrentSession("testproj/versions");
  const result = await tools.wb_diff.execute(null, { before: 1, after: "current" }, null, null, {});
  assert.equal(result.isError, undefined);
  assert.match(result.content[0].text, /-old/);
  assert.match(result.content[0].text, /\+new/);
  assert.ok(tools.wb_diff, "Pi registers wb_diff");
  console.log("wb diff CLI and Pi tool: passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
