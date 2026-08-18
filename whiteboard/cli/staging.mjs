// staging.mjs — the single mutation surface for `wb`: a staging transaction.
// `wb change "<title>"` opens a staging area in the session dir; `wb change <op>
// …` stages one op at a time, validated against the doc-as-it-would-be-after the
// already-staged ops; `wb change send` commits all staged ops as one named
// change. `wb change status` peeks; `wb change discard`/`kill` aborts. One
// staging per session (simple lock); starting a new change auto-sends any
// staging older than STALE_MS (lazy, daemon-free).
//
// Ops are intent: comment/reply/resolve/flag/amend/detach are built by the op
// builders in doc.mjs (id minting, flag set/clear → attach/detach), so the agent
// never hand-rolls ids or attachment state.
import fs from "node:fs";
import path from "node:path";
import {
  loadDoc, readChanges, appendChange, fold, validateOps, changeIdFor, selectorFor,
  attachOp, replyOp, resolveOp, detachOp, amendOp, flagOp,
} from "./doc.mjs";
import { slugify, agentName } from "./store.mjs";
import { applyUnifiedDiff } from "./patch.mjs";

const STAGING = ".staging.json";
export const STALE_MS = 5 * 60 * 1000; // 5 min
const SUB = new Set(["send", "discard", "status", "kill", "edit", "add", "move", "rename", "remove", "comment", "reply", "resolve", "unresolve", "flag", "attention", "amend", "detach"]);

export function isChangeSub(word) { return SUB.has(word); }

function stagingPath(session) { return path.join(session.dir, STAGING); }
export function loadStaging(session) {
  const f = stagingPath(session);
  if (!fs.existsSync(f)) return null;
  try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return null; }
}
function saveStaging(session, st) { fs.writeFileSync(stagingPath(session), JSON.stringify(st, null, 2) + "\n"); }
function clearStaging(session) { try { fs.unlinkSync(stagingPath(session)); } catch {} }

// The doc as it would be AFTER applying the staged ops (for per-op validation).
function previewDoc(session, stagedOps) {
  const changes = readChanges(session.dir);
  const max = changes.reduce((m, c) => Math.max(m, c.rev || 0), 0);
  return fold([...changes, { rev: max + 1, at: new Date().toISOString(), ops: stagedOps }]);
}

function readContent(flags, { optional = false } = {}) {
  if (flags.text !== undefined) return String(flags.text);
  if (flags.file) return fs.readFileSync(flags.file, "utf8");
  if (!process.stdin.isTTY) return fs.readFileSync(0, "utf8");
  if (optional) return null;
  throw new Error("no content: pass --text, --file, or pipe via stdin");
}

export function startChange(session, { title, summary, by }) {
  if (!title) throw new Error('usage: wb change "<title>" [--summary S]');
  const existing = loadStaging(session);
  let note = "";
  if (existing) {
    const age = Date.now() - new Date(existing.startedAt).getTime();
    if (age < STALE_MS) throw new Error(`a change is already in progress: "${existing.title}" (${existing.ops.length} ops, ${Math.floor(age / 60000)}m). Run \`wb change status\` to peek or \`wb change discard\` to abort.`);
    const ch = sendChange(session, { by: existing.by });
    note = `auto-sent stale change "${ch.title}" (rev ${ch.rev}). `;
  }
  saveStaging(session, { title, summary: summary || null, by: by || agentName(), ops: [], startedAt: new Date().toISOString() });
  return `${note}started "${title}". Stage ops with \`wb change <edit|add|move|rename|remove|comment|reply|resolve|unresolve|flag|attention|amend|detach>\`, then \`wb change send\`.`;
}

function stageOp(session, op) {
  const st = loadStaging(session);
  if (!st) throw new Error(`no change in progress — start with \`wb change "<title>"\`.`);
  validateOps(previewDoc(session, st.ops), [op]);
  st.ops.push(op);
  saveStaging(session, st);
  return st;
}

export function sendChange(session, { by } = {}) {
  const st = loadStaging(session);
  if (!st) throw new Error('no change in progress — start with `wb change "<title>"`.');
  if (!st.ops.length) throw new Error("no ops staged — add some with `wb change <edit|add|…>` before `wb change send`.");
  const doc = loadDoc(session.dir);
  if (!doc) throw new Error(`no document in ${session.dir}`);
  validateOps(doc, st.ops); // re-check against the live doc in case a change landed meanwhile
  const ch = appendChange(session.dir, { id: changeIdFor(st.title), title: st.title, by: by || st.by || agentName(), summary: st.summary, ops: st.ops });
  clearStaging(session);
  return ch;
}

export function discardChange(session) {
  if (!loadStaging(session)) return "no staging to discard.";
  clearStaging(session);
  return "staging discarded.";
}

export function statusChange(session) {
  const st = loadStaging(session);
  if (!st) return "no change in progress.";
  const ageMin = Math.max(0, Math.floor((Date.now() - new Date(st.startedAt).getTime()) / 60000));
  const lines = [`change "${st.title}" — ${st.ops.length} op(s), open ${ageMin}m${st.summary ? " · " + st.summary : ""}`];
  for (const o of st.ops) lines.push(`  - ${summarizeOp(o)}`);
  if (Date.now() - new Date(st.startedAt).getTime() > STALE_MS) lines.push("  (stale — will auto-send when you next start a `wb change \"<title>\"`)");
  return lines.join("\n");
}

function summarizeOp(o) {
  switch (o.op) {
    case "add": return `add ${o.name}`;
    case "edit": return `edit ${o.name}`;
    case "move": return `move ${o.name} ${o.before ? "before " + o.before : o.after ? "after " + o.after : "(position?)"}`;
    case "rename": return `rename ${o.from}→${o.to}`;
    case "remove": return `remove ${(o.names || []).join(", ") || o.name}`;
    case "attach": return `${o.kind} on ${o.block} (${o.id})`;
    case "reply": return `reply on ${o.to} (${o.id})`;
    case "resolve": return `${o.unresolved ? "unresolve" : "resolve"} ${o.id}`;
    case "detach": return `detach ${o.id}`;
    case "amend": return `amend ${o.id}`;
    default: return o.op;
  }
}

// Dispatch `wb change <sub> …` — build one intent op and stage it.
export function stageSubcommand(session, sub, positional, flags) {
  const by = flags.by || agentName();
  const want = (n, usage) => { if (positional.length < n) throw new Error(usage); };
  switch (sub) {
    case "edit": {
      want(1, "usage: wb change edit <block> (--file <f|-> | --text T | --diff <f|->)");
      const [name] = positional;
      let md;
      if (flags.diff !== undefined) {
        if (flags.text !== undefined || flags.file) throw new Error("pass either --diff or --file/--text, not both");
        const diff = flags.diff === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(flags.diff, "utf8");
        const block = previewDoc(session, loadStaging(session).ops).blocks.find((b) => b.name === name);
        if (!block) throw new Error(`no block "${name}"`);
        md = applyUnifiedDiff(block.md, diff);
      } else md = readContent(flags);
      return `edit ${name} accepted (${stageOp(session, { op: "edit", name, md }).ops.length} staged). \`wb change send\` when done.`;
    }
    case "add": {
      want(1, "usage: wb change add <name> [--before X|--after X] (--file <f|-> | --text T)");
      return `add ${positional[0]} accepted (${stageOp(session, { op: "add", name: slugify(positional[0]), md: readContent(flags), before: flags.before, after: flags.after }).ops.length} staged).`;
    }
    case "move": {
      want(1, "usage: wb change move <name> --before X|--after X");
      if (!flags.before && !flags.after) throw new Error("move needs --before or --after");
      return `move ${positional[0]} accepted (${stageOp(session, { op: "move", name: positional[0], before: flags.before, after: flags.after }).ops.length} staged).`;
    }
    case "rename": {
      want(2, "usage: wb change rename <old> <new>");
      const [from, to] = positional;
      return `rename ${from}→${to} accepted (${stageOp(session, { op: "rename", from, to: slugify(to) }).ops.length} staged).`;
    }
    case "remove": {
      want(1, "usage: wb change remove <name> [name…]");
      return `remove ${positional.join(", ")} accepted (${stageOp(session, { op: "remove", names: positional }).ops.length} staged).`;
    }
    case "comment": {
      want(1, "usage: wb change comment <block> (--text T|--file F) [--exact quote] [--by who]");
      const [name] = positional;
      const body = readContent(flags);
      const doc = previewDoc(session, loadStaging(session).ops);
      const block = doc.blocks.find((b) => b.name === name);
      let selector = null;
      if (flags.exact) { if (!block) throw new Error(`no block "${name}"`); selector = selectorFor(block.md, flags.exact); }
      const op = attachOp("comment", name, { body, by, selector });
      return `comment ${op.id} on ${name} accepted (${stageOp(session, op).ops.length} staged).`;
    }
    case "reply": {
      want(1, "usage: wb change reply <thread-id> (--text T|--file F) [--by who]");
      const op = replyOp(positional[0], readContent(flags), { by });
      return `reply ${op.id} on ${positional[0]} accepted (${stageOp(session, op).ops.length} staged).`;
    }
    case "resolve": { want(1, "usage: wb change resolve <thread-id>"); return `resolve ${positional[0]} accepted (${stageOp(session, resolveOp(positional[0], true)).ops.length} staged).`; }
    case "unresolve": { want(1, "usage: wb change unresolve <thread-id>"); return `unresolve ${positional[0]} accepted (${stageOp(session, resolveOp(positional[0], false)).ops.length} staged).`; }
    case "flag": {
      want(2, "usage: wb change flag <block> <flag> [--clear] [--text reason] [--by who]");
      const [name, flag] = positional;
      const op = flagOp(previewDoc(session, loadStaging(session).ops), name, flag, { value: !flags.clear, body: flags.text || null, by });
      if (!op) return `${flag} ${flags.clear ? "not set" : "already set"} on ${name} — nothing staged (${loadStaging(session).ops.length} staged).`;
      return `${flags.clear ? "clear" : "set"} ${flag} on ${name} accepted (${stageOp(session, op).ops.length} staged).`;
    }
    case "attention": {
      want(1, "usage: wb change attention <block> (--text T) [--by who]");
      const op = attachOp("needs-attention", positional[0], { body: readContent(flags, { optional: true }) || "Needs your attention.", motivation: "highlighting", by });
      return `attention ${op.id} on ${positional[0]} accepted (${stageOp(session, op).ops.length} staged).`;
    }
    case "amend": {
      want(1, "usage: wb change amend <thread-id> (--text T) [--exact quote] [--by who]");
      const [id] = positional;
      const doc = previewDoc(session, loadStaging(session).ops);
      const a = doc.attachments.find((x) => x.id === id);
      if (!a) throw new Error(`no attachment "${id}"`);
      let selector, body;
      if (flags.text !== undefined) body = flags.text;
      if (flags.exact !== undefined) { const block = doc.blocks.find((b) => b.name === a.block); if (!block) throw new Error(`no block "${a.block}"`); selector = selectorFor(block.md, flags.exact); }
      if (body === undefined && selector === undefined) throw new Error("amend needs --text and/or --exact");
      return `amend ${id} accepted (${stageOp(session, amendOp(id, { body, selector })).ops.length} staged).`;
    }
    case "detach": { want(1, "usage: wb change detach <thread-id>"); return `detach ${positional[0]} accepted (${stageOp(session, detachOp(positional[0])).ops.length} staged).`; }
    default: throw new Error(`unknown change op "${sub}"`);
  }
}