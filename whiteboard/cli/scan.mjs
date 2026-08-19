// scan.mjs — pure actionable-item helpers over a block-doc session directory.
// Shared by `wb listen` (cli) and the pi extension's wake. No state: callers
// own dedupe (baseline ids, then fire on new ones).
//
// A comment is "actionable" (needs an agent reply) when author==="user",
// resolved===false, and no reply in replies[] has author==="agent". A chat
// message is actionable when it's a user message with no agent reply after it.

import fs from "node:fs";
import path from "node:path";
import { loadDoc } from "./doc.mjs";

export function isActionable(c) {
  if (!c || c.author !== "user") return false;
  if (c.resolved) return false;
  if (Array.isArray(c.replies) && c.replies.some((r) => r.author === "agent")) return false;
  return true;
}

export function actionableComments(doc) {
  return (doc.comments || []).filter(isActionable);
}

function readChat(dir) {
  const d = path.join(dir, "chat");
  if (!fs.existsSync(d)) return [];
  return fs.readdirSync(d).filter((f) => f.endsWith(".json"))
    .map((f) => { try { return JSON.parse(fs.readFileSync(path.join(d, f), "utf8")); } catch { return null; } }).filter(Boolean);
}

export function chatActionable(dir) {
  const msgs = readChat(dir).sort((a, b) => (a.created || "").localeCompare(b.created || ""));
  const out = [];
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    if (m.role !== "user") continue;
    const hasAgentAfter = msgs.slice(i + 1).some((x) => x.role === "agent" && (x.created || "") >= (m.created || ""));
    if (!hasAgentAfter) out.push({ kind: "chat", id: m.id, block: null, text: m.text || "" });
  }
  return out;
}

// All actionable items in a block-doc session: unanswered user comments + chat.
// Each item: { kind: "comment"|"chat", id, block, text }.
export function actionableItems(dir) {
  const doc = loadDoc(dir);
  const out = [];
  for (const c of (doc?.comments || [])) if (isActionable(c)) out.push({ kind: "comment", id: c.id, block: c.block, text: c.body || "" });
  for (const it of chatActionable(dir)) out.push(it);
  return out;
}