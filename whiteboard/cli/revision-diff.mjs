// Read-only unified diffs between two folded Whiteboard document revisions.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { DEFAULT_PATH, fold, readChanges } from "./doc.mjs";
import { readMd } from "./blocks.mjs";

const MAX_DIFF_BYTES = 64 * 1024 * 1024;

function parseRevision(value, name, changes) {
  if (value === undefined || value === null) {
    throw new Error(`usage: wb diff <before-rev> <after-rev> [--path P] (${name} missing)`);
  }
  const current = changes.length ? changes.at(-1).rev : 0;
  if (value === "current") return current;
  const text = String(value);
  if (!/^(0|[1-9]\d*)$/.test(text)) {
    throw new Error(`${name} revision must be a non-negative integer or "current"`);
  }
  const rev = Number(text);
  if (rev !== 0 && !changes.some((change) => change.rev === rev)) {
    throw new Error(`revision ${rev} does not exist`);
  }
  return rev;
}

function documentAt(changes, rev) {
  return fold(changes.filter((change) => change.rev <= rev));
}

function pathsFor(before, after, requested) {
  if (requested !== undefined) {
    const path = String(requested);
    if (!path) throw new Error("--path must not be empty");
    return [path];
  }
  const paths = [];
  for (const block of [...before.blocks, ...after.blocks]) {
    const path = block.path || DEFAULT_PATH;
    if (!paths.includes(path)) paths.push(path);
  }
  return paths.length ? paths : [DEFAULT_PATH];
}

function label(rev, file) {
  return `/rev-${rev}/${String(file).replace(/[\r\n]/g, "�")}`;
}

function diffText(before, after, beforeLabel, afterLabel, beforeExists, afterExists) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "wb-revision-diff-"));
  const beforeFile = path.join(temp, "before.md");
  const afterFile = path.join(temp, "after.md");
  try {
    fs.writeFileSync(beforeFile, before);
    fs.writeFileSync(afterFile, after);
    const result = spawnSync("git", ["diff", "--no-index", "--no-ext-diff", "--", beforeExists ? beforeFile : "/dev/null", afterExists ? afterFile : "/dev/null"], {
      encoding: "utf8", maxBuffer: MAX_DIFF_BYTES,
    });
    if (result.error) throw new Error(`could not run git diff: ${result.error.message}`);
    if (result.status !== 0 && result.status !== 1) {
      throw new Error(result.stderr.trim() || "git diff failed");
    }
    return result.stdout.replaceAll(beforeFile, beforeLabel).replaceAll(afterFile, afterLabel);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

// Compare artifact content only. Attachments have independent lifecycle state;
// they are intentionally not folded into a document-content diff.
export function diffRevisions(dir, { before: beforeInput, after: afterInput, path: requestedPath } = {}) {
  const changes = readChanges(dir);
  const beforeRev = parseRevision(beforeInput, "before", changes);
  const afterRev = parseRevision(afterInput, "after", changes);
  const before = documentAt(changes, beforeRev);
  const after = documentAt(changes, afterRev);
  const diffs = [];
  for (const file of pathsFor(before, after, requestedPath)) {
    const beforeExists = before.blocks.some((block) => (block.path || DEFAULT_PATH) === file);
    const afterExists = after.blocks.some((block) => (block.path || DEFAULT_PATH) === file);
    const patch = diffText(
      readMd(before, file), readMd(after, file), label(beforeRev, file), label(afterRev, file), beforeExists, afterExists,
    );
    if (patch) diffs.push(patch);
  }
  if (!diffs.length) {
    const scoped = requestedPath === undefined ? "" : ` in ${requestedPath}`;
    return `no document differences between rev ${beforeRev} and rev ${afterRev}${scoped}\n`;
  }
  return diffs.join("");
}
