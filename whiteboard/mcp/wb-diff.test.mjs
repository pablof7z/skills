// Regression: MCP wb_diff delegates to the shared revision-diff engine.

import assert from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "wb-mcp-diff-test-"));
process.env.WHITEBOARD_ROOT = root;
const dir = path.join(root, "testproj", "versions");
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ name: "versions", project: "testproj" }));

try {
  const { appendChange } = await import("../cli/doc.mjs");
  appendChange(dir, { id: "seed", title: "seed", ops: [{ op: "add", name: "goal", md: "# Goal\nold", path: "default.md" }] });
  appendChange(dir, { id: "edit", title: "edit", ops: [{ op: "edit", name: "goal", md: "# Goal\nnew", path: "default.md" }] });

  const { registerTools } = await import("./tools.mjs");
  const tools = {};
  registerTools({ registerTool: (name, _definition, execute) => { tools[name] = execute; } });
  assert.ok(tools.wb_diff, "MCP registers wb_diff");

  const result = await tools.wb_diff({ session_id: "testproj/versions", before: 1, after: "current" });
  assert.equal(result.isError, undefined);
  assert.match(result.content[0].text, /diff --git a\/rev-1\/default\.md b\/rev-2\/default\.md/);
  assert.match(result.content[0].text, /-old/);
  assert.match(result.content[0].text, /\+new/);
  console.log("MCP wb_diff: passed");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
