// tool.mjs — the single `whiteboard` tool the pi extension registers. Wraps the
// block-document surface the `wb` CLI exposes (read / staging / note) so the
// LLM mutates the doc via a tool call instead of shelling out. The CLI stays
// the human escape hatch (`/wb`); this is the agent path.
//
// typebox is only resolvable inside pi's runtime, so registration is deferred
// to registerWhiteboardTool(pi), which requires typebox lazily and no-ops under
// bare-node tests.

import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { resolveSession } from "../cli/store.mjs";
import { loadDoc } from "../cli/doc.mjs";
import { readTagged, readMd, readJson } from "../cli/blocks.mjs";
import {
  startChange, sendChange, discardChange, statusChange, stageSubcommand, isChangeSub,
} from "../cli/staging.mjs";

const require_ = createRequire(import.meta.url);

const SUBS = [
  "start", "send", "discard", "status",
  "edit", "add", "move", "rename", "remove",
  "comment", "reply", "resolve", "unresolve", "flag", "attention", "amend", "detach",
];

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

function execute(_toolCallId, p, _signal, _onUpdate, _ctx) {
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

export function registerWhiteboardTool(pi) {
  let Type;
  try { Type = require_("typebox"); } catch { return; } // not in pi runtime
  pi.registerTool({
    name: "whiteboard",
    label: "Whiteboard",
    description:
      "Mutate or read the current whiteboard block document. One tool, three actions: " +
      "`read` (project the doc), `change` (open/send/discard a staging transaction or stage one op), " +
      "`note` (append to notes.md). Session resolves from `session` arg, else WB_SESSION, else the " +
      "per-agent owners map. All mutations are staged then committed with `change` `sub: send`.",
    parameters: Type.Object({
      session: Type.Optional(Type.String({ description: '"project/slug" override; else WB_SESSION / owners map' })),
      action: Type.Union([Type.Literal("read"), Type.Literal("change"), Type.Literal("note")]),
      format: Type.Optional(Type.Union([Type.Literal("tagged"), Type.Literal("md"), Type.Literal("json")])),
      sub: Type.Optional(Type.Union(SUBS.map((s) => Type.Literal(s)))),
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
    }),
    execute,
  });
}