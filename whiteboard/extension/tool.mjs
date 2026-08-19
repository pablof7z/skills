// tool.mjs — the single `whiteboard` tool the pi extension registers. Wraps the
// block-document surface the `wb` CLI exposes (read / staging / note) so the
// LLM mutates the doc via a tool call instead of shelling out. The CLI stays
// the human escape hatch (`/wb`); this is the agent path.
//
// typebox is resolved by jiti's alias to pi's bundled copy when the extension
// is loaded under pi. index.ts does the static `import { Type } from "typebox"`
// (the canonical pattern from pi's docs/examples) and passes Type in here, so
// this module stays harness-agnostic and never does its own typebox resolution.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { resolveSession } from "../cli/store.mjs";
import { loadDoc } from "../cli/doc.mjs";
import { readTagged, readMd, readJson } from "../cli/blocks.mjs";
import {
  startChange, sendChange, discardChange, statusChange, stageSubcommand, isChangeSub,
} from "../cli/staging.mjs";

const SUBS = [
  "start", "send", "discard", "status",
  "edit", "add", "move", "rename", "remove",
  "comment", "reply", "resolve", "unresolve", "flag", "attention", "amend", "detach",
];

const SESSION_SUBS = ["new", "list", "use"];

// Path to the wb CLI — source of truth for session lifecycle (new/list/use).
// The tool shells out to it rather than duplicating manifest/owner/claim logic.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(__dirname, "..", "cli", "main.mjs");
const execFileP = promisify(execFile);

async function runCli(args) {
  const { stdout } = await execFileP(process.execPath, [CLI, ...args], {
    cwd: process.cwd(), maxBuffer: 4 * 1024 * 1024, env: process.env,
  });
  return stdout.trim();
}

// Build the (positional, flags) shape stageSubcommand expects from structured
// tool params. One place to map, so the CLI's validation is reused verbatim.
function toStageArgs(sub, p) {
  const flags = {};
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
    case "comment": case "attention": return { pos: [p.block], flags };
    case "flag": return { pos: [p.block, p.flag], flags };
    case "reply": case "amend": case "detach":
    case "resolve": case "unresolve":
      return { pos: [p.threadId], flags };
    default: throw new Error(`unknown change sub "${sub}"`);
  }
}

function txt(t) { return { content: [{ type: "text", text: String(t) }], details: {} }; }
function err(m) { return { content: [{ type: "text", text: String(m) }], isError: true, details: {} }; }

// Session lifecycle (new/list/use) — wrap the wb CLI, which owns manifest
// creation, owner stamping, claiming, and markdown-seed import.
async function runSessionOp(p) {
  const sub = p.sub;
  if (sub === "new") {
    if (!p.name) return err("whiteboard session new: `name` (slug) is required");
    const args = ["new", p.name];
    if (p.from) args.push("--from", p.from);
    return txt(await runCli(args));
  }
  if (sub === "list") {
    const args = ["list"];
    if (p.json) args.push("--json");
    return txt(await runCli(args));
  }
  if (sub === "use") {
    if (!p.name) return err("whiteboard session use: `name` (slug) is required");
    return txt(await runCli(["use", p.name]));
  }
  return err(`whiteboard session: unknown sub "${sub}"`);
}

async function execute(_toolCallId, p, _signal, _onUpdate, _ctx) {
  try {
    if (p.action === "session") return await runSessionOp(p);
  } catch (e) { return err(`whiteboard: ${e.message}`); }
  let s;
  try { s = resolveSession({ session: p.session }); }
  catch (e) { return err(`whiteboard: ${e.message}`); }
  try {
    if (p.action === "note") {
      if (!p.text) return err("whiteboard note: `text` is required");
      const f = path.join(s.dir, "notes.md");
      const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
      fs.appendFileSync(f, `\n- (${stamp}) ${String(p.text).replace(/\n/g, "\n  ")}\n`);
      return txt(`noted in ${s.project}/${s.slug}`);
    }
    if (p.action === "read") {
      const doc = loadDoc(s.dir);
      if (!doc) return err(`no document in ${s.project}/${s.slug}`);
      const fmt = p.format || "tagged";
      return txt(fmt === "json" ? readJson(doc) : fmt === "md" ? readMd(doc) : readTagged(doc));
    }
    if (p.action === "change") {
      const sub = p.sub;
      if (!sub) return err("whiteboard change: `sub` is required");
      if (sub === "start") {
        if (!p.title) return err("whiteboard change start: `title` is required");
        return txt(startChange(s, { title: p.title, summary: p.summary, by: p.by }));
      }
      if (sub === "send") return txt(`change applied: ${JSON.stringify(sendChange(s))}`);
      if (sub === "discard") return txt(discardChange(s));
      if (sub === "status") return txt(statusChange(s));
      if (!isChangeSub(sub)) return err(`unknown change sub "${sub}"`);
      const { pos, flags } = toStageArgs(sub, p);
      return txt(stageSubcommand(s, sub, pos, flags));
    }
    return err(`whiteboard: unknown action "${p.action}"`);
  } catch (e) { return err(`whiteboard: ${e.message}`); }
}

export function registerWhiteboardTool(pi, Type) {
  pi.registerTool({
    name: "whiteboard",
    label: "Whiteboard",
    description:
      "Drive a whiteboard session: read/mutate the block document, append notes, and manage " +
      "session lifecycle. Actions: `read` (project the doc), `change` (open/send/discard a staging " +
      "transaction or stage one op), `note` (append to notes.md), `session` (sub `new`/`list`/`use` — " +
      "create, list, or claim a session). For read/change/note the session resolves from `session` arg, " +
      "else WB_SESSION, else the per-agent owners map; `session` ops run via the wb CLI (project from " +
      "WB_SESSION or cwd). Mutations are staged then committed with `change` `sub: send`.",
    parameters: Type.Object({
      session: Type.Optional(Type.String({ description: '"project/slug" override; else WB_SESSION / owners map' })),
      action: Type.Union([Type.Literal("read"), Type.Literal("change"), Type.Literal("note"), Type.Literal("session")]),
      format: Type.Optional(Type.Union([Type.Literal("tagged"), Type.Literal("md"), Type.Literal("json")])),
      sub: Type.Optional(Type.Union([...SUBS, ...SESSION_SUBS].map((s) => Type.Literal(s)))),
      title: Type.Optional(Type.String()),
      summary: Type.Optional(Type.String()),
      block: Type.Optional(Type.String()),
      name: Type.Optional(Type.String()),
      names: Type.Optional(Type.Array(Type.String())),
      before: Type.Optional(Type.String()),
      after: Type.Optional(Type.String()),
      text: Type.Optional(Type.String()),
      diff: Type.Optional(Type.String()),
      exact: Type.Optional(Type.String()),
      threadId: Type.Optional(Type.String()),
      flag: Type.Optional(Type.String()),
      clear: Type.Optional(Type.Boolean()),
      by: Type.Optional(Type.String()),
      from: Type.Optional(Type.String({ description: "session new: seed the document from a markdown file" })),
      json: Type.Optional(Type.Boolean({ description: "session list: return JSON instead of plain lines" })),
    }),
    execute,
  });
}