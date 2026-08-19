// scan.mjs — pure actionable-item helpers over a block-doc session directory.
// Shared by `wb listen` (cli) and the pi extension's wake. No state: callers
// own dedupe (baseline ids, then fire on new ones).
//
// An annotation is "actionable" (needs an agent reply) when it is a thread (an
// attach kind: question/warning/objection/note — tags are never actionable),
// author==="user", not resolved, and no reply in replies[] has author==="agent".
// A chat message is actionable when it's a user message with no agent reply after it.

import fs from "node:fs";
import path from "node:path";
import { loadDoc } from "./doc.mjs";
import { isTagKind, isActionableKind } from "./kinds.mjs";

export function isActionable(c) {
  if (!c || isTagKind(c.kind) || !isActionableKind(c.kind)) return false; // tags + note are not replyable
  if (c.author !== "user") return false;
  if (c.resolved) return false;
  if (Array.isArray(c.replies) && c.replies.some((r) => r.author === "agent")) return false;
  return true;
}

export function actionableAnnotations(doc) {
  return (doc.annotations || []).filter(isActionable);
}
// Compat alias for callers that haven't migrated off `doc.comments` yet.
export const actionableComments = actionableAnnotations;

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

// All actionable items in a block-doc session: unanswered user threads + chat.
// Each item: { kind: "annotation"|"chat", id, block, text, anchor? }. `anchor` is
// the full highlighted span (annotation.selector.exact); always present now that
// every annotation is anchored (legacy block-level ones are reanchored to the H1).
export function actionableItems(dir) {
  const doc = loadDoc(dir);
  const out = [];
  for (const c of (doc?.annotations || [])) if (isActionable(c)) out.push({ kind: "annotation", id: c.id, block: c.block, text: c.body || "", ...(c.selector?.exact ? { anchor: c.selector.exact } : {}) });
  for (const it of chatActionable(dir)) out.push(it);
  return out;
}