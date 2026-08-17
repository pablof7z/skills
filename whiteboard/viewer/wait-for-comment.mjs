#!/usr/bin/env node
// Whiteboard comment watcher for the agent.
//
// Watches <session-dir>/comments/ and exits (printing the new comment's
// annotation id) as soon as a NEW top-level human comment appears that has no
// agent reply yet. The agent runs this via a background monitor; when it exits,
// the onDone prompt wakes the agent so it can read the comment and write a
// reply annotation file. Then the agent relaunches this watcher for the next
// comment.
//
// Usage: node wait-for-comment.mjs <session-dir> [--timeout 0]
//   --timeout <sec>   if > 0, exit with code 2 ("idle") after that many seconds
//                     with no new comment. Default 0 = wait forever.
//
// Exit codes: 0 = new actionable comment found (id printed on stdout);
//             2 = timeout elapsed with no new comment.

import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const positional = [];
let timeout = 0;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--timeout") timeout = Number(args[++i]);
  else if (a.startsWith("--timeout=")) timeout = Number(a.slice(10));
  else if (a === "--help" || a === "-h") {
    console.log("Usage: wait-for-comment.mjs <session-dir> [--timeout 0]");
    process.exit(0);
  } else positional.push(a);
}
const sessionDir = positional[0];
if (!sessionDir) {
  console.error("Error: session directory is required.");
  process.exit(2);
}

const COMMENTS = path.join(sessionDir, "comments");

function readComments() {
  if (!fs.existsSync(COMMENTS)) return [];
  return fs.readdirSync(COMMENTS)
    .filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(COMMENTS, f), "utf8")); } catch { return null; } })
    .filter(Boolean);
}

function isTopLevel(a) {
  return a && a.motivation !== "replying" && !(a.target && a.target.id);
}
function isUser(a) {
  const n = String((a.creator && a.creator.name) || "").toLowerCase();
  return n !== "agent";
}
function replyIds(annos) {
  return new Set(annos.filter((a) => a.motivation === "replying" && a.target && a.target.id).map((a) => a.target.id));
}

// Baseline: ids of comments that existed at start, so we only fire on NEW ones.
const baseline = new Set(readComments().map((a) => a.id));
const deadline = timeout > 0 ? Date.now() + timeout * 1000 : 0;

function scan() {
  const annos = readComments();
  const replied = replyIds(annos);
  for (const a of annos) {
    if (!isTopLevel(a) || !isUser(a)) continue;
    if (baseline.has(a.id)) continue;
    if (replied.has(a.id)) continue;
    return a;
  }
  return null;
}

function tick() {
  const found = scan();
  if (found) {
    process.stdout.write(found.id + "\n");
    process.exit(0);
  }
  if (deadline && Date.now() > deadline) {
    process.stdout.write("idle\n");
    process.exit(2);
  }
}

// Poll at 1s (robust across platforms; fs.watch is flaky for this use case).
setInterval(tick, 1000);
tick();