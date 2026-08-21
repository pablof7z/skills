// Whiteboard MCP tools. Stateful document operations take an explicit
// session_id, keeping the Streamable HTTP transport stateless.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { z } from "zod/v4";
import { resolveSession } from "../cli/store.mjs";
import { loadDoc, DEFAULT_PATH } from "../cli/doc.mjs";
import { readJson, readMdAgent } from "../cli/blocks.mjs";
import { diffRevisions } from "../cli/revision-diff.mjs";
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
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(__dirname, "..", "cli", "main.mjs");
const execFileP = promisify(execFile);

async function runCli(args) {
  const { stdout } = await execFileP(process.execPath, [CLI, ...args], {
    cwd: process.cwd(), maxBuffer: 4 * 1024 * 1024, env: process.env,
  });
  return stdout.trim();
}

function ok(text) { return { content: [{ type: "text", text: String(text) }] }; }
function fail(message) { return { content: [{ type: "text", text: String(message) }], isError: true }; }

function getSession(session_id) {
  if (!session_id) return { error: "`session_id` is required" };
  let s;
  try { s = resolveSession({ session: session_id }); }
  catch (error) { return { error: `whiteboard: ${error.message}` }; }
  if (!fs.existsSync(path.join(s.dir, "manifest.json"))) {
    return { error: `no session "${s.project}/${s.slug}" — create it first with wb_new` };
  }
  return { s };
}

function toStageArgs(sub, p) {
  const flags = {};
  if (p.path !== undefined) flags.path = p.path;
  if (p.before !== undefined) flags.before = p.before;
  if (p.after !== undefined) flags.after = p.after;
  if (p.by !== undefined) flags.by = p.by;
  if (p.text !== undefined) flags.text = p.text;
  switch (sub) {
    case "edit": return { pos: [p.block], flags };
    case "add": return { pos: [p.name || p.block], flags };
    case "move": return { pos: [p.block || p.name], flags };
    case "rename": return { pos: [p.block, p.name], flags };
    case "remove": return { pos: p.names && p.names.length ? p.names : [p.block], flags };
    default: throw new Error(`unknown artifact op "${sub}"`);
  }
}

export function registerTools(server) {
  server.registerTool(
    "wb_new",
    { title: "Whiteboard new", description: "Create a session and return its session_id.", inputSchema: z.object({ slug: z.string().describe("session slug") }) },
    async ({ slug }) => {
      let out;
      try { out = await runCli(["new", slug]); }
      catch (error) { return fail(`wb_new: ${error.message}`); }
      const match = out.match(/created\s+(\S+)/);
      if (!match) return fail(`wb_new: unexpected CLI output: ${out}`);
      const session_id = match[1];
      const viewer_url = `http://127.0.0.1:${process.env.WHITEBOARD_PORT || "4318"}/session/${session_id}`;
      return ok(JSON.stringify({ session_id, viewer_url }, null, 2));
    },
  );

  server.registerTool(
    "wb_list",
    { title: "Whiteboard list", description: "List session slugs for the current project.", inputSchema: z.object({ json: z.boolean().optional() }) },
    async ({ json }) => {
      try { return ok(await runCli(json ? ["list", "--json"] : ["list"])); }
      catch (error) { return fail(`wb_list: ${error.message}`); }
    },
  );

  server.registerTool(
    "wb_read",
    {
      title: "Whiteboard read",
      description: "Project a session's block document as markdown or JSON.",
      inputSchema: z.object({
        session_id: z.string(), format: z.enum(["md", "json"]).optional(), path: z.string().optional(), block: z.string().optional(),
      }),
    },
    async ({ session_id, format, path: p, block }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      const doc = loadDoc(r.s.dir);
      if (!doc) return fail(`no document in ${r.s.project}/${r.s.slug}`);
      if ((format || "md") === "json") return ok(readJson(doc));
      if (block) {
        const cand = doc.blocks.filter((item) => item.name === block && (!p || (item.path || DEFAULT_PATH) === p));
        if (!cand.length) return fail(`no block "${block}"${p ? ` in ${p}` : ""}`);
        const item = cand[0], file = item.path || DEFAULT_PATH;
        return ok(readMdAgent({ blocks: [item], annotations: (doc.annotations || []).filter((a) => a.block === block && (a.path || DEFAULT_PATH) === file), rev: doc.rev, updatedAt: doc.updatedAt }));
      }
      return ok(readMdAgent(doc, p));
    },
  );

  server.registerTool(
    "wb_diff",
    {
      title: "Whiteboard diff",
      description: "Read-only unified artifact diff between two document revisions. A revision is 0, an existing revision, or current.",
      inputSchema: z.object({ session_id: z.string(), before: z.union([z.number().int().nonnegative(), z.literal("current")]), after: z.union([z.number().int().nonnegative(), z.literal("current")]), path: z.string().optional() }),
    },
    async ({ session_id, before, after, path: requestedPath }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      try { return ok(diffRevisions(r.s.dir, { before, after, path: requestedPath })); }
      catch (error) { return fail(`wb_diff: ${error.message}`); }
    },
  );

  server.registerTool(
    "wb_note",
    { title: "Whiteboard note", description: "Append a timestamped line to a session's notes scratchpad.", inputSchema: z.object({ session_id: z.string(), text: z.string(), by: z.string().optional() }) },
    async ({ session_id, text }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      const file = path.join(r.s.dir, "notes.md");
      const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
      fs.appendFileSync(file, `\n- (${stamp}) ${String(text).replace(/\n/g, "\n  ")}\n`);
      return ok(`noted in ${r.s.project}/${r.s.slug}`);
    },
  );

  server.registerTool(
    "wb_change_start",
    { title: "Whiteboard change start", description: "Open a staging transaction.", inputSchema: z.object({ session_id: z.string(), title: z.string(), summary: z.string().optional(), by: z.string().optional() }) },
    async ({ session_id, title, summary, by }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      try { return ok(startChange(r.s, { title, summary, by })); }
      catch (error) { return fail(`wb_change_start: ${error.message}`); }
    },
  );

  server.registerTool(
    "wb_change_block",
    {
      title: "Whiteboard change block",
      description: "Stage an add, edit, move, rename, or remove block operation.",
      inputSchema: z.object({
        session_id: z.string(), op: z.enum(BLOCK_OPS), path: z.string().optional(), block: z.string().optional(), name: z.string().optional(),
        names: z.array(z.string()).optional(), text: z.string().optional(), diff: z.string().optional(), before: z.string().optional(), after: z.string().optional(), by: z.string().optional(),
      }),
    },
    async (p) => {
      const { session_id, op } = p;
      const r = getSession(session_id); if (r.error) return fail(r.error);
      try {
        if (op === "rename" && (!p.block || !p.name)) return fail("wb_change_block rename: `block` and `name` are required");
        if (op === "edit" && p.diff !== undefined) {
          if (!p.block) return fail("wb_change_block edit: `block` is required");
          const staging = loadStaging(r.s);
          if (!staging) return fail("no change in progress — start with wb_change_start");
          const block = previewDoc(r.s, staging.ops).blocks.find((item) => item.name === p.block && (item.path || DEFAULT_PATH) === (p.path || DEFAULT_PATH));
          if (!block) return fail(`no block "${p.block}" in ${p.path || DEFAULT_PATH}`);
          return ok(stageSubcommand(r.s, "edit", [p.block], { text: applyUnifiedDiff(block.md, String(p.diff)), path: p.path }));
        }
        const { pos, flags } = toStageArgs(op, p);
        return ok(stageSubcommand(r.s, op, pos, flags));
      } catch (error) { return fail(`wb_change_block: ${error.message}`); }
    },
  );

  server.registerTool(
    "wb_change_finish",
    { title: "Whiteboard change finish", description: "Commit or abandon the open staging transaction.", inputSchema: z.object({ session_id: z.string(), op: z.enum(["commit", "abandon"]) }) },
    async ({ session_id, op }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      try { return ok(op === "commit" ? `change applied: ${JSON.stringify(sendChange(r.s))}` : discardChange(r.s)); }
      catch (error) { return fail(`wb_change_finish: ${error.message}`); }
    },
  );

  server.registerTool(
    "wb_attach",
    {
      title: "Whiteboard attach",
      description: "Create, reply to, resolve, reopen, or list an anchored thread.",
      inputSchema: z.object({
        session_id: z.string(), op: z.enum(["attach", "reply", "resolve", "reopen", "list"]), block: z.string().optional(), on: z.string().optional(),
        kind: z.enum(ATTACH_KINDS).optional(), content: z.string().optional(), id: z.string().optional(), by: z.string().optional(), path: z.string().optional(), open: z.boolean().optional(),
      }),
    },
    async (p) => {
      const r = getSession(p.session_id); if (r.error) return fail(r.error);
      try {
        if (p.op === "list") return ok(listAnnotations(r.s, { block: p.block, path: p.path, tags: false, open: p.open }));
        if (p.op === "reply") return ok(attachReply(r.s, p.id, { content: p.content, by: p.by }));
        if (p.op === "resolve") return ok(attachResolve(r.s, p.id, { by: p.by }));
        if (p.op === "reopen") return ok(attachReopen(r.s, p.id, { by: p.by }));
        return ok(attachCreate(r.s, { block: p.block, on: p.on, kind: p.kind, content: p.content, by: p.by, path: p.path }));
      } catch (error) { return fail(`wb_attach: ${error.message}`); }
    },
  );

  server.registerTool(
    "wb_tag",
    {
      title: "Whiteboard tag",
      description: "Set, clear, or list a status tag anchored to a block span.",
      inputSchema: z.object({
        session_id: z.string(), op: z.enum(["set", "clear", "list"]), block: z.string().optional(), on: z.string().optional(), kind: z.enum(TAG_KINDS).optional(), content: z.string().optional(), by: z.string().optional(), path: z.string().optional(),
      }),
    },
    async (p) => {
      const r = getSession(p.session_id); if (r.error) return fail(r.error);
      try {
        if (p.op === "list") return ok(listAnnotations(r.s, { block: p.block, path: p.path, tags: true }));
        if (p.op === "set") return ok(tagSet(r.s, { block: p.block, on: p.on, kind: p.kind, content: p.content, by: p.by, path: p.path }));
        return ok(tagClear(r.s, { block: p.block, on: p.on, kind: p.kind, by: p.by, path: p.path }));
      } catch (error) { return fail(`wb_tag: ${error.message}`); }
    },
  );
}
