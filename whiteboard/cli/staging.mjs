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
  loadDoc, readChanges, appendChange, fold, validateOps, validateOpsInOrder, changeIdFor,
  DEFAULT_PATH,
} from "./doc.mjs";
import { slugify, agentName, provenance } from "./store.mjs";
import { applyUnifiedDiff } from "./patch.mjs";

const STAGING = ".staging.json";
export const STALE_MS = 5 * 60 * 1000; // 5 min
// `wb change` is artifact-only: block edits staged as one atomic revision.
// Annotations (attach/tag and their lifecycle) are direct one-command writes via
// `wb attach` / `wb tag` (see annotations.mjs) — not staged here.
const SUB = new Set(["send", "discard", "status", "kill", "edit", "add", "move", "rename", "remove"]);

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
export function previewDoc(session, stagedOps) {
  const changes = readChanges(session.dir);
  const max = changes.reduce((m, c) => Math.max(m, c.rev || 0), 0);
  return fold([...changes, { rev: max + 1, at: new Date().toISOString(), ops: stagedOps }]);
}

// Resolve a unified diff against a WIP block: find it by (name,path), throw if
// missing, and apply the diff. Shared by apply.mjs, stageSubcommand's edit-diff
// branch, and the extension's wb_change_block edit-diff branch.
export function resolveEditDiff(blocks, name, fpath, diff) {
  const block = blocks.find((b) => b.name === name && (b.path || DEFAULT_PATH) === fpath);
  if (!block) throw new Error(`no block "${name}" in ${fpath}`);
  return applyUnifiedDiff(block.md, diff);
}

function readContent(flags, { optional = false } = {}) {
  if (flags.text !== undefined) return String(flags.text);
  if (flags.file) return fs.readFileSync(flags.file, "utf8");
  if (!process.stdin.isTTY) return fs.readFileSync(0, "utf8");
  if (optional) return null;
  throw new Error("no content: pass --text, --file, or pipe via stdin");
}

export function startChange(session, { title, summary, by, piSessionId }) {
  if (!title) throw new Error('usage: wb change "<title>" [--summary S]');
  const existing = loadStaging(session);
  let note = "";
  if (existing) {
    const age = Date.now() - new Date(existing.startedAt).getTime();
    if (age < STALE_MS) throw new Error(`a change is already in progress: "${existing.title}" (${existing.ops.length} ops, ${Math.floor(age / 60000)}m). Run \`wb change status\` to peek or \`wb change discard\` to abort.`);
    const ch = sendChange(session, { by: existing.by, piSessionId: existing.piSessionId });
    note = `auto-sent stale change "${ch.title}" (rev ${ch.rev}). `;
  }
  saveStaging(session, { title, summary: summary || null, by: by || agentName(), ops: [], startedAt: new Date().toISOString(), piSessionId: piSessionId || null });
  return `${note}started "${title}". Stage ops with \`wb change <edit|add|move|rename|remove>\`, then \`wb change send\`.`;
}

function stageOp(session, op) {
  const st = loadStaging(session);
  if (!st) throw new Error(`no change in progress — start with \`wb change "<title>"\`.`);
  validateOps(previewDoc(session, st.ops), [op]);
  st.ops.push(op);
  saveStaging(session, st);
  return st;
}

export function sendChange(session, { by, piSessionId } = {}) {
  const st = loadStaging(session);
  if (!st) throw new Error('no change in progress — start with `wb change "<title>"`.');
  if (!st.ops.length) throw new Error("no ops staged — add some with `wb change <edit|add|…>` before `wb change send`.");
  const doc = loadDoc(session.dir);
  if (!doc) throw new Error(`no document in ${session.dir}`);
  validateOpsInOrder(doc, st.ops); // re-check against the live doc, walking ops in WIP order so an op can reference one added earlier in the same tx
  // Populate via.piSessionId from the harness (the extension process has no
  // PI_SESSION_ID env); keep all other provenance fields from this process.
  const pid = piSessionId ?? st.piSessionId ?? null;
  const via = pid ? { ...provenance(), piSessionId: pid } : undefined;
  const ch = appendChange(session.dir, { id: changeIdFor(st.title), title: st.title, by: by || st.by || agentName(), summary: st.summary, ops: st.ops, via });
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
  const fpath = flags.path || DEFAULT_PATH; // the file path this op targets (default default.md)
  const want = (n, usage) => { if (positional.length < n) throw new Error(usage); };
  switch (sub) {
    case "edit": {
      want(1, "usage: wb change edit <block> (--file <f|-> | --text T | --diff <f|->) [--path P]");
      const [name] = positional;
      let md;
      if (flags.diff !== undefined) {
        if (flags.text !== undefined || flags.file) throw new Error("pass either --diff or --file/--text, not both");
        const diff = flags.diff === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(flags.diff, "utf8");
        md = resolveEditDiff(previewDoc(session, loadStaging(session).ops).blocks, name, fpath, diff);
      } else md = readContent(flags);
      return `edit ${name} accepted (${stageOp(session, { op: "edit", name, md, path: fpath }).ops.length} staged). \`wb change send\` when done.`;
    }
    case "add": {
      want(1, "usage: wb change add <name> [--before X|--after X] (--file <f|-> | --text T)");
      return `add ${positional[0]} accepted (${stageOp(session, { op: "add", name: slugify(positional[0]), md: readContent(flags), before: flags.before, after: flags.after, path: fpath }).ops.length} staged).`;
    }
    case "move": {
      want(1, "usage: wb change move <name> --before X|--after X [--path P]");
      if (!flags.before && !flags.after) throw new Error("move needs --before or --after");
      return `move ${positional[0]} accepted (${stageOp(session, { op: "move", name: positional[0], before: flags.before, after: flags.after, path: fpath }).ops.length} staged).`;
    }
    case "rename": {
      want(2, "usage: wb change rename <old> <new> [--path P]");
      const [from, to] = positional;
      if (!from || !to) throw new Error("rename needs <old> and <new> block names (both required)");
      return `rename ${from}→${to} accepted (${stageOp(session, { op: "rename", from, to: slugify(to), path: fpath }).ops.length} staged).`;
    }
    case "remove": {
      want(1, "usage: wb change remove <name> [name…] [--path P]");
      return `remove ${positional.join(", ")} accepted (${stageOp(session, { op: "remove", names: positional, path: fpath }).ops.length} staged).`;
    }
    default: throw new Error(`unknown change op "${sub}" — annotation ops live under \`wb attach\`/\`wb tag\`, not \`wb change\``);
  }
}