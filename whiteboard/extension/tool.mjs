// tool.mjs — the nine whiteboard tools the pi extension registers, exposed via
// pi's lazy/active tool pattern. Two loaders (`wb_new`, `wb_list`) are always
// active for a fresh agent; calling either unlocks the doc + mutation tools
// (`wb_use`, `wb_read`, `wb_note`, `wb_change_*`). Owning agents get the full
// set at session_start so an attributed-comment wake can reply immediately.
//
// typebox is resolved by jiti's alias to pi's bundled copy when loaded under pi.
// index.ts resolves it dynamically (so bare-node tests still load this module)
// and passes Type into registerWhiteboardTools; if Type is null the tools don't
// register. The CLI (`/wb`) stays the human escape hatch; this is the agent path.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { resolveSession } from "../cli/store.mjs";
import { loadDoc, DEFAULT_PATH } from "../cli/doc.mjs";
import { readJson, readMd, readMdAgent } from "../cli/blocks.mjs";
import {
  startChange, sendChange, discardChange, stageSubcommand,
  loadStaging, previewDoc,
} from "../cli/staging.mjs";
import { applyUnifiedDiff } from "../cli/patch.mjs";
import {
  attachCreate, attachReply, attachResolve, attachReopen,
  tagSet, tagClear, listAnnotations,
} from "../cli/annotations.mjs";
import { ATTACH_KINDS, TAG_KINDS } from "../cli/kinds.mjs";

const BLOCK_OPS = ["add", "edit", "move", "rename", "remove"];
// Tools that are inactive for a fresh agent and unlocked by wb_new/wb_list/wb_use.
const DOC_TOOLS = ["wb_use", "wb_read", "wb_note", "wb_change_start", "wb_change_block", "wb_change_finish", "wb_attach", "wb_tag"];

// Path to the wb CLI — source of truth for session lifecycle (new/list/use).
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(__dirname, "..", "cli", "main.mjs");
const execFileP = promisify(execFile);

async function runCli(args) {
  const { stdout } = await execFileP(process.execPath, [CLI, ...args], {
    cwd: process.cwd(), maxBuffer: 4 * 1024 * 1024, env: process.env,
  });
  return stdout.trim();
}

// The tool tracks the current session itself — no env reliance. Seeded by the
// extension at session_start (setCurrentSession) and updated by wb_new/wb_use.
let currentSession = null;
export function setCurrentSession(s) { currentSession = s || null; }
export function getCurrentSession() { return currentSession; }

// pi handle, stored at registration so the loader tools can manage the active set.
let piHandle = null;
function unlockDocTools() {
  if (!piHandle) return;
  try {
    const active = piHandle.getActiveTools();
    const added = DOC_TOOLS.filter((n) => !active.includes(n));
    if (added.length) piHandle.setActiveTools([...new Set([...active, ...added])]);
  } catch {} // best-effort; missing methods (tests) → no-op
}
const UNLOCK_MSG = `\ndoc + mutation tools now available: ${DOC_TOOLS.join(", ")}`;

// Map structured tool params to the (positional, flags) shape stageSubcommand
// expects, so the CLI's validation is reused verbatim.
function toStageArgs(sub, p) {
  const flags = {};
  if (p.path !== undefined) flags.path = p.path;
  if (p.before !== undefined) flags.before = p.before;
  if (p.after !== undefined) flags.after = p.after;
  if (p.exact !== undefined) flags.exact = p.exact;
  if (p.by !== undefined) flags.by = p.by;
  if (p.clear === true) flags.clear = true;
  if (p.text !== undefined) flags.text = p.text;
  else if (p.diff !== undefined) flags.diff = p.diff;
  switch (sub) {
    case "edit": return { pos: [p.block], flags };
    case "add": return { pos: [p.name || p.block], flags };
    case "move": return { pos: [p.block || p.name], flags };
    case "rename": return { pos: [p.block, p.name], flags };
    case "remove": return { pos: p.names && p.names.length ? p.names : [p.block], flags };
    default: throw new Error(`unknown artifact op "${sub}"`);
  }
}

function txt(t) { return { content: [{ type: "text", text: String(t) }], details: {} }; }
function err(m) { return { content: [{ type: "text", text: String(m) }], isError: true, details: {} }; }

function piSid(ctx) { try { return ctx?.sessionManager?.getSessionId?.() || null; } catch { return null; } }

// Resolve the tracked current session to a {project,slug,dir} (or an error).
function getSession() {
  if (!currentSession) return { error: "no whiteboard session — create or claim one first: call wb_new or wb_use" };
  let s;
  try { s = resolveSession({ session: currentSession }); }
  catch (e) { return { error: `whiteboard: ${e.message}` }; }
  if (!fs.existsSync(path.join(s.dir, "manifest.json"))) {
    return { error: `no session "${s.project}/${s.slug}" — create it first: wb_new({ slug: "${s.slug}" })` };
  }
  return { s };
}

// ---- per-tool execute handlers ----

async function wb_new(_id, p) {
  if (!p.slug) return err("wb_new: `slug` is required");
  let out;
  try { out = await runCli(["new", p.slug]); }
  catch (e) { return err(`wb_new: ${e.message}`); }
  const m = out.match(/created\s+(\S+)/);
  if (m) setCurrentSession(m[1]);
  unlockDocTools();
  return txt(out + (m ? UNLOCK_MSG : ""));
}

async function wb_list(_id, p) {
  let out;
  try { out = await runCli(p.json ? ["list", "--json"] : ["list"]); }
  catch (e) { return err(`wb_list: ${e.message}`); }
  unlockDocTools();
  return txt(out);
}

async function wb_use(_id, p) {
  if (!p.slug) return err("wb_use: `slug` is required");
  let out;
  try { out = await runCli(["use", p.slug]); }
  catch (e) { return err(`wb_use: ${e.message}`); }
  const m = out.match(/using\s+(\S+)/);
  if (m) setCurrentSession(m[1]);
  unlockDocTools();
  return txt(out);
}

async function wb_read(_id, p) {
  const r = getSession(); if (r.error) return err(r.error);
  const doc = loadDoc(r.s.dir);
  if (!doc) return err(`no document in ${r.s.project}/${r.s.slug}`);
  if ((p.format || "md") === "json") return txt(readJson(doc));
  if (p.block) {
    const cand = doc.blocks.filter((b) => b.name === p.block && (!p.path || (b.path || DEFAULT_PATH) === p.path));
    if (!cand.length) return err(`no block "${p.block}"${p.path ? ` in ${p.path}` : ""}`);
    const fb = cand[0], fp = fb.path || DEFAULT_PATH;
    return txt(readMdAgent({ blocks: [fb], annotations: (doc.annotations || []).filter((a) => a.block === p.block && (a.path || DEFAULT_PATH) === fp), rev: doc.rev, updatedAt: doc.updatedAt }));
  }
  return txt(readMdAgent(doc, p.path));
}

async function wb_note(_id, p) {
  if (!p.text) return err("wb_note: `text` is required");
  const r = getSession(); if (r.error) return err(r.error);
  const f = path.join(r.s.dir, "notes.md");
  const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
  fs.appendFileSync(f, `\n- (${stamp}) ${String(p.text).replace(/\n/g, "\n  ")}\n`);
  return txt(`noted in ${r.s.project}/${r.s.slug}`);
}

async function wb_change_start(_id, p, _sig, _on, ctx) {
  if (!p.title) return err("wb_change_start: `title` is required");
  const r = getSession(); if (r.error) return err(r.error);
  try { return txt(startChange(r.s, { title: p.title, summary: p.summary, by: p.by, piSessionId: piSid(ctx) })); }
  catch (e) { return err(`wb_change_start: ${e.message}`); }
}

async function wb_change_block(_id, p, _sig, _on, ctx) {
  const op = p.op;
  if (!op) return err("wb_change_block: `op` is required");
  if (!BLOCK_OPS.includes(op)) return err(`wb_change_block: unknown op "${op}" (one of ${BLOCK_OPS.join(", ")})`);
  const r = getSession(); if (r.error) return err(r.error);
  try {
    if (op === "rename" && (!p.block || !p.name))
      return err("wb_change_block rename: `block` (old name) and `name` (new name) are required");
    // edit with inline diff: resolve the diff to new md in-process against the
    // WIP block (doc after already-staged ops), then stage as a text edit.
    if (op === "edit" && p.diff !== undefined) {
      if (!p.block) return err("wb_change_block edit: `block` is required");
      const stg = loadStaging(r.s);
      if (!stg) return err("no change in progress — start with wb_change_start");
      const block = previewDoc(r.s, stg.ops).blocks.find((b) => b.name === p.block && (b.path || DEFAULT_PATH) === (p.path || DEFAULT_PATH));
      if (!block) return err(`no block "${p.block}" in ${p.path || DEFAULT_PATH}`);
      const md = applyUnifiedDiff(block.md, String(p.diff));
      return txt(stageSubcommand(r.s, "edit", [p.block], { text: md, path: p.path }));
    }
    const { pos, flags } = toStageArgs(op, p);
    return txt(stageSubcommand(r.s, op, pos, flags));
  } catch (e) { return err(`wb_change_block: ${e.message}`); }
}

async function wb_attach(_id, p) {
  const op = p.op;
  if (!op) return err("wb_attach: `op` is required");
  const r = getSession(); if (r.error) return err(r.error);
  try {
    if (op === "list") return txt(listAnnotations(r.s, { block: p.block, path: p.path, tags: false, open: p.open }) + "\n");
    if (op === "reply") return txt(attachReply(r.s, p.id, { content: p.content, by: p.by }) + "\n");
    if (op === "resolve") return txt(attachResolve(r.s, p.id, { by: p.by }) + "\n");
    if (op === "reopen") return txt(attachReopen(r.s, p.id, { by: p.by }) + "\n");
    if (op === "attach") return txt(attachCreate(r.s, { block: p.block, on: p.on, kind: p.kind, content: p.content, by: p.by, path: p.path }) + "\n");
    return err(`wb_attach: unknown op "${op}" (attach|reply|resolve|reopen|list)`);
  } catch (e) { return err(`wb_attach: ${e.message}`); }
}

async function wb_tag(_id, p) {
  const op = p.op;
  if (!op) return err("wb_tag: `op` is required");
  const r = getSession(); if (r.error) return err(r.error);
  try {
    if (op === "list") return txt(listAnnotations(r.s, { block: p.block, path: p.path, tags: true }) + "\n");
    if (op === "set") return txt(tagSet(r.s, { block: p.block, on: p.on, kind: p.kind, content: p.content, by: p.by, path: p.path }) + "\n");
    if (op === "clear") return txt(tagClear(r.s, { block: p.block, on: p.on, kind: p.kind, by: p.by, path: p.path }) + "\n");
    return err(`wb_tag: unknown op "${op}" (set|clear|list)`);
  } catch (e) { return err(`wb_tag: ${e.message}`); }
}

async function wb_change_finish(_id, p, _sig, _on, ctx) {
  const op = p.op;
  if (!op) return err("wb_change_finish: `op` is required");
  const r = getSession(); if (r.error) return err(r.error);
  try {
    if (op === "commit") return txt(`change applied: ${JSON.stringify(sendChange(r.s, { piSessionId: piSid(ctx) }))}`);
    if (op === "abandon") return txt(discardChange(r.s));
    return err(`wb_change_finish: unknown op "${op}" (commit|abandon)`);
  } catch (e) { return err(`wb_change_finish: ${e.message}`); }
}

// Tool descriptions are the primary agent-facing surface (lazy tools carry no
// promptSnippet/promptGuidelines), so they spell out params + a short example.
const D = {
  wb_new: "Create a new whiteboard session and make it the current one. Unlocks the doc + mutation tools (wb_use/wb_read/wb_note/wb_change_*). params: { slug } (required; slugified). Example: wb_new({ slug: \"2026-08-feature-x\" }).",
  wb_list: "List whiteboard sessions for this project. Unlocks the doc + mutation tools. params: { json?: boolean } (default: plain lines). Example: wb_list({}).",
  wb_use: "Switch to (claim) an existing whiteboard session and make it current. Unlocks the doc + mutation tools. params: { slug } (required; \"project/slug\" or just \"slug\"). Example: wb_use({ slug: \"skills/2026-08-feature-x\" }).",
  wb_read: "Project the current session's block document. params: { format?: \"md\"|\"json\" (default md), path?: string, block?: string }. md = block bodies + an action-section (## Open threads — unresolved id·path·block·kind·author + replies; ## Tags — active status tags; ## Meta — rev/updatedAt). With no path and multiple files, emits a `## 📄 <path>` header per file (the file tree). json = full structured doc (blocks + annotations). `path` scopes to one file; `block` (with `path`) to one block. Example: wb_read({}) or wb_read({ path: \"references/pi.md\" }).",
  wb_note: "Append a timestamped line to the session's notes.md scratchpad. params: { text (required), by? }. Example: wb_note({ text: \"decided option E\" }).",
  wb_start: "Open a staging transaction (one at a time); stage ops with wb_change_block, then commit/abandon with wb_change_finish. Annotations (questions/warnings/objections/notes + status tags) are NOT staged — use wb_attach/wb_tag directly. params: { title (required), summary?, by? }. Example: wb_change_start({ title: \"refactor auth\" }).",
  wb_block: "Stage an ARTIFACT op on the current session's open transaction: add/edit/move/rename/remove a block. params: { op, path?, block?, name?, names?, text?, diff?, before?, after?, by? }. `path` is the file the block belongs to (default \"default.md\"); block names are unique within a path. op=add: name+text(+before?/after?+path?). op=edit: block+text(OR diff, unified diff applied in-process)+path?. op=move: block+before?/after?+path?. op=rename: block(old)+name(new)+path?. op=remove: block|names[]+path?. Examples: wb_change_block({ op:\"add\", path:\"references/pi.md\", name:\"examples\", text:\"# Examples\\n…\" }); wb_change_block({ op:\"edit\", block:\"goal\", diff:\"@@\\n- old\\n+ new\" }).",
  wb_attach: "Anchor a replyable thread to a span of a block, or work with an existing thread. NOT staged — a direct write. params: { op: \"attach\"|\"reply\"|\"resolve\"|\"reopen\"|\"list\", block?, on?, kind?, content?, id?, by?, path?, open? }. `on` is the anchor text within the block (REQUIRED for attach; the thread anchors to that span). `kind` (attach only): question|warning|objection|note. op=attach: block+on+kind+content(+by?+path?). op=reply: id+content(+by?). op=resolve/reopen: id. op=list: (+block?+path?+open?). Examples: wb_attach({ op:\"attach\", block:\"goal\", on:\"Build the thing.\", kind:\"question\", content:\"is this right?\" }); wb_attach({ op:\"reply\", id:\"c-abc\", content:\"noted\" }); wb_attach({ op:\"resolve\", id:\"c-abc\" }).",
  wb_tag: "Set or clear a short status tag anchored to a span of a block, or list tags. NOT staged — a direct write. params: { op: \"set\"|\"clear\"|\"list\", block?, on?, kind?, content?, by?, path? }. `on` is the anchor text within the block (REQUIRED for set/clear). `kind`: unverified|superseded|needs-attention|decided. op=set: block+on+kind(+content?+by?+path?) — idempotent (a second set of the same tag on the same span is a no-op). op=clear: block+on+kind(+by?+path?). op=list: (+block?+path?). Examples: wb_tag({ op:\"set\", block:\"opts\", on:\"- A\", kind:\"superseded\" }); wb_tag({ op:\"clear\", block:\"opts\", on:\"- A\", kind:\"superseded\" }).",
  wb_finish: "Commit or abandon the open staging transaction. params: { op: \"commit\"|\"abandon\" }. commit applies the staged ARTIFACT ops as one change (returns rev + op count); abandon discards them. Example: wb_change_finish({ op:\"commit\" }).",
};

export function registerWhiteboardTools(pi, Type) {
  if (!Type) return; // bare-node (tests): typebox not installed → tools don't register
  piHandle = pi;
  const opt = (T) => Type.Optional(T);
  const lit = (s) => Type.Literal(s);
  pi.registerTool({
    name: "wb_new", label: "Whiteboard new", description: D.wb_new,
    parameters: Type.Object({ slug: Type.String({ description: "session slug; slugified to [a-z0-9-]" }) }),
    execute: wb_new,
  });
  pi.registerTool({
    name: "wb_list", label: "Whiteboard list", description: D.wb_list,
    parameters: Type.Object({ json: opt(Type.Boolean({ description: "return JSON array instead of plain lines" })) }),
    execute: wb_list,
  });
  pi.registerTool({
    name: "wb_use", label: "Whiteboard use", description: D.wb_use,
    parameters: Type.Object({ slug: Type.String({ description: '"project/slug" or just "slug" (project from cwd)' }) }),
    execute: wb_use,
  });
  pi.registerTool({
    name: "wb_read", label: "Whiteboard read", description: D.wb_read,
    parameters: Type.Object({
      format: opt(Type.Union([lit("md"), lit("json")])),
      path: opt(Type.String({ description: "scope to one file path (default \"default.md\")" })),
      block: opt(Type.String({ description: "filter to one block within the path (md only)" })),
    }),
    execute: wb_read,
  });
  pi.registerTool({
    name: "wb_note", label: "Whiteboard note", description: D.wb_note,
    parameters: Type.Object({ text: Type.String(), by: opt(Type.String()) }),
    execute: wb_note,
  });
  pi.registerTool({
    name: "wb_change_start", label: "Whiteboard change start", description: D.wb_start,
    parameters: Type.Object({ title: Type.String(), summary: opt(Type.String()), by: opt(Type.String()) }),
    execute: wb_change_start,
  });
  pi.registerTool({
    name: "wb_change_block", label: "Whiteboard change block", description: D.wb_block,
    parameters: Type.Object({
      op: Type.Union(BLOCK_OPS.map(lit)),
      path: opt(Type.String({ description: "file path the block belongs to (default \"default.md\")" })),
      block: opt(Type.String()), name: opt(Type.String()), names: opt(Type.Array(Type.String())),
      text: opt(Type.String()), diff: opt(Type.String()),
      before: opt(Type.String()), after: opt(Type.String()), by: opt(Type.String()),
    }),
    execute: wb_change_block,
  });
  pi.registerTool({
    name: "wb_attach", label: "Whiteboard attach", description: D.wb_attach,
    parameters: Type.Object({
      op: Type.Union([lit("attach"), lit("reply"), lit("resolve"), lit("reopen"), lit("list")]),
      block: opt(Type.String()), on: opt(Type.String({ description: "anchor text within the block (required for attach)" })),
      kind: opt(Type.Union(ATTACH_KINDS.map(lit))), content: opt(Type.String()), id: opt(Type.String()),
      by: opt(Type.String()), path: opt(Type.String()), open: opt(Type.Boolean()),
    }),
    execute: wb_attach,
  });
  pi.registerTool({
    name: "wb_tag", label: "Whiteboard tag", description: D.wb_tag,
    parameters: Type.Object({
      op: Type.Union([lit("set"), lit("clear"), lit("list")]),
      block: opt(Type.String()), on: opt(Type.String({ description: "anchor text within the block (required for set/clear)" })),
      kind: opt(Type.Union(TAG_KINDS.map(lit))), content: opt(Type.String()),
      by: opt(Type.String()), path: opt(Type.String()),
    }),
    execute: wb_tag,
  });
  pi.registerTool({
    name: "wb_change_finish", label: "Whiteboard change finish", description: D.wb_finish,
    parameters: Type.Object({ op: Type.Union([lit("commit"), lit("abandon")]) }),
    execute: wb_change_finish,
  });
}