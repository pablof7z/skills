#!/usr/bin/env node
// Whiteboard inbox watcher for the agent.
//
// Watches <session-dir>/comments/ and <session-dir>/chat/ and exits as soon as
// there is a NEW actionable item the agent must respond to:
//   - a top-level human comment with no agent reply, or
//   - a human chat message with no agent chat reply after it.
// Prints a token on stdout identifying the item:
//   comment:<urn:uuid>   -> reply by writing a reply annotation file in comments/
//   chat:<urn:uuid>      -> reply by writing an agent chat message file in chat/
// The agent runs this via a background monitor; its onDone prompt wakes the
// agent. Then the agent responds and relaunches this watcher for the next item.
//
// Usage: node wait-for-comment.mjs <session-dir> [--timeout 0]
//   --timeout <sec>   if > 0, exit code 2 ("idle") after that many seconds with
//                     no new actionable item. Default 0 = wait forever.
// Exit codes: 0 = actionable item found (token on stdout); 2 = timeout/idle.

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
const CHAT = path.join(sessionDir, "chat");

function readJsonDir(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")); } catch { return null; } })
    .filter(Boolean);
}

function isTopLevelComment(a) {
  return a && a.motivation !== "replying" && !(a.target && a.target.id);
}
function isUser(a) {
  return String((a.creator && a.creator.name) || "").toLowerCase() !== "agent";
}
function repliedCommentIds(annos) {
  return new Set(annos.filter((a) => a.motivation === "replying" && a.target && a.target.id).map((a) => a.target.id));
}

// Baseline ids present at start so we only fire on NEW items.
const baseComments = new Set(readJsonDir(COMMENTS).map((a) => a.id));
const baseChat = new Set(readJsonDir(CHAT).map((m) => m.id));
const deadline = timeout > 0 ? Date.now() + timeout * 1000 : 0;

function scan() {
  // Comments: new top-level human comment with no reply.
  const annos = readJsonDir(COMMENTS);
  const replied = repliedCommentIds(annos);
  for (const a of annos) {
    if (!isTopLevelComment(a) || !isUser(a)) continue;
    if (baseComments.has(a.id)) continue;
    if (replied.has(a.id)) continue;
    return { kind: "comment", id: a.id };
  }
  // Chat: new human message with no agent message after it.
  const msgs = readJsonDir(CHAT).sort((a, b) => (a.created || "").localeCompare(b.created || ""));
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    if (m.role !== "user" || baseChat.has(m.id)) continue;
    const hasAgentAfter = msgs.slice(i + 1).some((x) => x.role === "agent" && (x.created || "") >= (m.created || ""));
    if (!hasAgentAfter) return { kind: "chat", id: m.id };
  }
  return null;
}

function tick() {
  const found = scan();
  if (found) {
    process.stdout.write(`${found.kind}:${found.id}\n`);
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