// tools.mjs — the 9 whiteboard tools, MCP-native: every tool but wb_new/wb_list
// takes an explicit `session_id` ("project/slug") on every call (no
// protocol-level or in-memory session — see server.mjs/README.md). Handlers
// are thin delegation to ../cli/*.mjs, mirroring ../extension/tool.mjs's
// grouped verbs but without pi's lazy-tool/current-session machinery.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { z } from "zod/v4";
import { resolveSession } from "../cli/store.mjs";
import { loadDoc, DEFAULT_PATH } from "../cli/doc.mjs";
import { readJson, readMdAgent } from "../cli/blocks.mjs";
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

// Resolve session_id ("project/slug") to a {project,slug,dir} (or an error) —
// every tool resolves fresh from disk; nothing is tracked between calls.
function getSession(session_id) {
  if (!session_id) return { error: "`session_id` is required" };
  let s;
  try { s = resolveSession({ session: session_id }); }
  catch (e) { return { error: `whiteboard: ${e.message}` }; }
  if (!fs.existsSync(path.join(s.dir, "manifest.json"))) {
    return { error: `no session "${s.project}/${s.slug}" — create it first with wb_new` };
  }
  return { s };
}

// Map structured tool params to the (positional, flags) shape stageSubcommand
// expects, so the CLI's validation is reused verbatim.
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

export function registerTools(server, _ctx) {
  server.registerTool(
    "wb_new",
    { title: "Whiteboard new", description: "Create a new whiteboard session. Returns session_id (\"project/slug\") + the viewer URL — pass session_id to every other wb_* tool.", inputSchema: z.object({ slug: z.string().describe("session slug; slugified to [a-z0-9-]") }) },
    async ({ slug }) => {
      let out;
      try { out = await runCli(["new", slug]); }
      catch (e) { return fail(`wb_new: ${e.message}`); }
      const m = out.match(/created\s+(\S+)/);
      if (!m) return fail(`wb_new: unexpected CLI output: ${out}`);
      const session_id = m[1];
      const viewerUrl = `http://127.0.0.1:${process.env.WHITEBOARD_PORT || "4318"}/session/${session_id}`;
      return ok(JSON.stringify({ session_id, viewer_url: viewerUrl }, null, 2));
    },
  );

  server.registerTool(
    "wb_list",
    { title: "Whiteboard list", description: "List whiteboard session slugs for the current project (server's cwd).", inputSchema: z.object({ json: z.boolean().optional().describe("return a JSON array instead of plain lines") }) },
    async ({ json }) => {
      try { return ok(await runCli(json ? ["list", "--json"] : ["list"])); }
      catch (e) { return fail(`wb_list: ${e.message}`); }
    },
  );

  server.registerTool(
    "wb_read",
    {
      title: "Whiteboard read",
      description: "Project a session's block document. md = block bodies + open threads/tags/meta; json = full structured doc.",
      inputSchema: z.object({
        session_id: z.string(),
        format: z.enum(["md", "json"]).optional(),
        path: z.string().optional().describe("scope to one file path (default \"default.md\")"),
        block: z.string().optional().describe("filter to one block within the path (md only)"),
      }),
    },
    async ({ session_id, format, path: p, block }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      const doc = loadDoc(r.s.dir);
      if (!doc) return fail(`no document in ${r.s.project}/${r.s.slug}`);
      if ((format || "md") === "json") return ok(readJson(doc));
      if (block) {
        const cand = doc.blocks.filter((b) => b.name === block && (!p || (b.path || DEFAULT_PATH) === p));
        if (!cand.length) return fail(`no block "${block}"${p ? ` in ${p}` : ""}`);
        const fb = cand[0], fp = fb.path || DEFAULT_PATH;
        return ok(readMdAgent({ blocks: [fb], annotations: (doc.annotations || []).filter((a) => a.block === block && (a.path || DEFAULT_PATH) === fp), rev: doc.rev, updatedAt: doc.updatedAt }));
      }
      return ok(readMdAgent(doc, p));
    },
  );

  server.registerTool(
    "wb_note",
    { title: "Whiteboard note", description: "Append a timestamped line to the session's notes.md scratchpad.", inputSchema: z.object({ session_id: z.string(), text: z.string(), by: z.string().optional() }) },
    async ({ session_id, text }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      const f = path.join(r.s.dir, "notes.md");
      const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
      fs.appendFileSync(f, `\n- (${stamp}) ${String(text).replace(/\n/g, "\n  ")}\n`);
      return ok(`noted in ${r.s.project}/${r.s.slug}`);
    },
  );

  server.registerTool(
    "wb_change_start",
    { title: "Whiteboard change start", description: "Open a staging transaction (one at a time). Stage ops with wb_change_block, then commit/abandon with wb_change_finish.", inputSchema: z.object({ session_id: z.string(), title: z.string(), summary: z.string().optional(), by: z.string().optional() }) },
    async ({ session_id, title, summary, by }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      try { return ok(startChange(r.s, { title, summary, by })); }
      catch (e) { return fail(`wb_change_start: ${e.message}`); }
    },
  );

  server.registerTool(
    "wb_change_block",
    {
      title: "Whiteboard change block",
      description: "Stage an artifact op on the open transaction: add/edit/move/rename/remove a block.",
      inputSchema: z.object({
        session_id: z.string(), op: z.enum(BLOCK_OPS),
        path: z.string().optional(), block: z.string().optional(), name: z.string().optional(),
        names: z.array(z.string()).optional(), text: z.string().optional(), diff: z.string().optional(),
        before: z.string().optional(), after: z.string().optional(), by: z.string().optional(),
      }),
    },
    async (p) => {
      const { session_id, op } = p;
      const r = getSession(session_id); if (r.error) return fail(r.error);
      try {
        if (op === "rename" && (!p.block || !p.name)) return fail("wb_change_block rename: `block` (old name) and `name` (new name) are required");
        if (op === "edit" && p.diff !== undefined) {
          if (!p.block) return fail("wb_change_block edit: `block` is required");
          const stg = loadStaging(r.s);
          if (!stg) return fail("no change in progress — start with wb_change_start");
          const block = previewDoc(r.s, stg.ops).blocks.find((b) => b.name === p.block && (b.path || DEFAULT_PATH) === (p.path || DEFAULT_PATH));
          if (!block) return fail(`no block "${p.block}" in ${p.path || DEFAULT_PATH}`);
          const md = applyUnifiedDiff(block.md, String(p.diff));
          return ok(stageSubcommand(r.s, "edit", [p.block], { text: md, path: p.path }));
        }
        const { pos, flags } = toStageArgs(op, p);
        return ok(stageSubcommand(r.s, op, pos, flags));
      } catch (e) { return fail(`wb_change_block: ${e.message}`); }
    },
  );

  server.registerTool(
    "wb_change_finish",
    { title: "Whiteboard change finish", description: "Commit or abandon the open staging transaction.", inputSchema: z.object({ session_id: z.string(), op: z.enum(["commit", "abandon"]) }) },
    async ({ session_id, op }) => {
      const r = getSession(session_id); if (r.error) return fail(r.error);
      try {
        if (op === "commit") return ok(`change applied: ${JSON.stringify(sendChange(r.s))}`);
        return ok(discardChange(r.s));
      } catch (e) { return fail(`wb_change_finish: ${e.message}`); }
    },
  );

  server.registerTool(
    "wb_attach",
    {
      title: "Whiteboard attach",
      description: "Anchor a replyable thread to a span of a block, or work with an existing thread. Direct write (not staged).",
      inputSchema: z.object({
        session_id: z.string(), op: z.enum(["attach", "reply", "resolve", "reopen", "list"]),
        block: z.string().optional(), on: z.string().optional().describe("anchor text within the block (required for attach)"),
        kind: z.enum(ATTACH_KINDS).optional(), content: z.string().optional(), id: z.string().optional(),
        by: z.string().optional(), path: z.string().optional(), open: z.boolean().optional(),
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
      } catch (e) { return fail(`wb_attach: ${e.message}`); }
    },
  );

  server.registerTool(
    "wb_tag",
    {
      title: "Whiteboard tag",
      description: "Set or clear a short status tag anchored to a span of a block, or list tags. Direct write (not staged).",
      inputSchema: z.object({
        session_id: z.string(), op: z.enum(["set", "clear", "list"]),
        block: z.string().optional(), on: z.string().optional().describe("anchor text within the block (required for set/clear)"),
        kind: z.enum(TAG_KINDS).optional(), content: z.string().optional(),
        by: z.string().optional(), path: z.string().optional(),
      }),
    },
    async (p) => {
      const r = getSession(p.session_id); if (r.error) return fail(r.error);
      try {
        if (p.op === "list") return ok(listAnnotations(r.s, { block: p.block, path: p.path, tags: true }));
        if (p.op === "set") return ok(tagSet(r.s, { block: p.block, on: p.on, kind: p.kind, content: p.content, by: p.by, path: p.path }));
        return ok(tagClear(r.s, { block: p.block, on: p.on, kind: p.kind, by: p.by, path: p.path }));
      } catch (e) { return fail(`wb_tag: ${e.message}`); }
    },
  );
}
