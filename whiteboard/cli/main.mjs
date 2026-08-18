#!/usr/bin/env node
// main.mjs — wb CLI entry point. The document is an append-only change log
// (changes/<rev>.json); every mutation appends one change (one atomic file).
// `wb read` projects the fold; `wb change` appends N ops as a single named
// change. Session scope: --session / WB_SESSION / ~/.wb/current (store.mjs).

import fs from "node:fs";
import path from "node:path";
import {
  resolveSession, setCurrent, listSessions, sessionDir, projectFromCwd, slugify, stampOwner,
} from "./store.mjs";
import { readTagged, readMd, readJson } from "./blocks.mjs";
import { parseMarkdownToBlocks } from "./migrate.mjs";
import {
  loadDoc, appendChange, validateOps, changeIdFor, selectorFor,
  attachOp, replyOp, resolveOp, detachOp, amendOp,
} from "./doc.mjs";

const HELP = `wb — whiteboard change-log document CLI
  wb new <slug> [--from <md-file>]   create a session (optionally seed from markdown)
  wb list [--json]                   list sessions for this project
  wb use <slug>                      set current session (claims it for this agent)
  wb read [--md|--json] [slug]       project the doc (default: tagged <name>…</name>)
  wb write add <name> [--before X|--after X] [--text T|--file F|stdin]   add a block
  wb write edit <name> [--text T|--file F|stdin]                        replace a block
  wb write move <name> --before X|--after X     reorder a block
  wb write rename <old> <new>                    rename (cascades comments)
  wb write remove <name> [name…]                 delete block(s) + their comments
  wb flag <name> <flag> [--on|--off] [--text ...]   set/clear a label (needs-attention|decided|superseded|…)
  wb comment <name> <text|--file> [--by who] [--exact "..."]   attach a comment
  wb reply <id> <text> [--by who]        reply in a thread
  wb attention <name> [reason]                  attach a needs-attention label (+ card)
  wb resolve <id> [--unresolve]          resolve/unresolve an attachment
  wb detach <id>                         remove an attachment
  wb amend <id> [--text T] [--exact "..."]   edit an attachment's body or anchor
  wb note <text|--file>                          append to notes.md
  wb change "<title>" [--summary S] --ops -|--file F   apply a named batch of ops as one change
     ops (JSON array): {op:"add"|"edit"|"move"|"rename"|"remove"|"comment"|"reply"|"resolve"|"attention"|"flag", ...}
The document = fold of changes/<rev>.json; each mutation appends one change.
Scope: --session <project>/<slug> > WB_SESSION > ~/.wb/current (this project).
Content: --text > --file > stdin (when piped). Default --by is "agent".`;

function parse(argv) {
  const positional = [], flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") { positional.push(...argv.slice(i + 1)); break; }
    if (a.startsWith("--")) {
      const k = a.slice(2);
      if (["json", "md", "on", "off", "unresolve", "help", "h"].includes(k)) { flags[k] = true; continue; }
      flags[k] = argv[++i];
    } else positional.push(a);
  }
  return { positional, flags };
}

function readContent(flags, { allowStdin = true } = {}) {
  if (flags.text !== undefined) return String(flags.text);
  if (flags.file) return fs.readFileSync(flags.file, "utf8");
  if (allowStdin && !process.stdin.isTTY) return fs.readFileSync(0, "utf8");
  throw new Error("no content: pass --text, --file, or pipe via stdin");
}

// Read a JSON array of ops for `wb change`.
function readOps(flags) {
  let raw;
  if (flags.ops !== undefined) raw = flags.ops === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(flags.ops, "utf8");
  else if (flags.file) raw = fs.readFileSync(flags.file, "utf8");
  else if (!process.stdin.isTTY) raw = fs.readFileSync(0, "utf8");
  else throw new Error("no ops: pass --ops -|--ops <file>|--file <file>, or pipe JSON on stdin");
  const ops = JSON.parse(raw);
  if (!Array.isArray(ops) || ops.length === 0) throw new Error("ops must be a non-empty JSON array");
  return ops;
}

function out(obj) { process.stdout.write(typeof obj === "string" ? obj : JSON.stringify(obj, null, 2) + "\n"); }

// Load the folded doc for a session (validates the session has a document).
function docFor(session) {
  const doc = loadDoc(session.dir);
  if (!doc) throw new Error(`no document in ${session.dir} — run \`wb new\` first`);
  return doc;
}

// Append one change (validating ops against the current fold first so a bad op
// aborts before anything is written). Returns the written change.
function applyChange(session, { id, title, by, summary, ops }) {
  const doc = docFor(session);
  validateOps(doc, ops);
  return appendChange(session.dir, { id, by, summary, ops, title });
}

async function main() {
  const { positional, flags } = parse(process.argv.slice(2));
  const [cmd, ...rest] = positional;
  const session = () => resolveSession({ session: flags.session });

  switch (cmd) {
    case undefined:
    case "help":
    case "-h":
    case "--help":
      return out(HELP + `\n  current project: ${projectFromCwd()}\n`);
    case "new": {
      const slug = slugify(rest[0]);
      if (!slug) throw new Error("usage: wb new <slug> [--from <md-file>]");
      let project;
      if (flags.session) project = flags.session.includes("/") ? flags.session.split("/")[0] : projectFromCwd();
      else if (process.env.WB_SESSION) project = process.env.WB_SESSION.includes("/") ? process.env.WB_SESSION.split("/")[0] : projectFromCwd();
      else project = projectFromCwd();
      const dir = sessionDir(project, slug);
      if (fs.existsSync(path.join(dir, "changes")) || fs.existsSync(path.join(dir, "document.json"))) throw new Error(`session ${project}/${slug} already exists`);
      fs.mkdirSync(path.join(dir, "changes"), { recursive: true });
      fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({
        name: slug, status: "exploring", project, createdAt: new Date().toISOString(),
        ...(process.env.WB_OWNER ? { owner: process.env.WB_OWNER } : {}),
      }, null, 2) + "\n");
      if (flags.from) {
        const md = fs.readFileSync(flags.from, "utf8");
        const blocks = parseMarkdownToBlocks(md);
        const ops = blocks.map((b) => ({ op: "add", name: b.name, md: b.md }));
        appendChange(dir, { id: "initial", title: "Initial import", by: "agent", ops });
      }
      setCurrent(project, slug);
      stampOwner(dir, process.env.WB_OWNER);
      return out(`created ${project}/${slug} → ${dir}\n`);
    }
    case "list": {
      const project = flags.session ? flags.session.split("/")[0] : projectFromCwd();
      const sessions = listSessions(project);
      return flags.json ? out(sessions) : out(sessions.map((s) => `${project}/${s}`).join("\n") + "\n");
    }
    case "use": {
      const slug = rest[0];
      if (!slug) throw new Error("usage: wb use <slug>");
      const project = projectFromCwd();
      setCurrent(project, slugify(slug));
      stampOwner(sessionDir(project, slugify(slug)), process.env.WB_OWNER);
      return out(`using ${project}/${slugify(slug)}\n`);
    }
    case "read": {
      const s = session();
      const doc = loadDoc(s.dir);
      if (!doc) throw new Error(`no document in ${s.dir}`);
      if (flags.json) return out(readJson(doc));
      if (flags.md) return out(readMd(doc));
      return out(readTagged(doc));
    }
    case "write": {
      const [op, name, ...more] = rest;
      const by = flags.by || "agent";
      const s = session();
      let ops, title;
      if (op === "add") { const n = slugify(name); ops = [{ op: "add", name: n, md: readContent(flags), before: flags.before, after: flags.after }]; title = `add ${n}`; }
      else if (op === "edit") { ops = [{ op: "edit", name, md: readContent(flags) }]; title = `edit ${name}`; }
      else if (op === "move") { ops = [{ op: "move", name, before: flags.before, after: flags.after }]; title = `move ${name}`; }
      else if (op === "rename") { const to = slugify(more[0]); ops = [{ op: "rename", from: name, to }]; title = `rename ${name}→${to}`; }
      else if (op === "remove") { ops = [{ op: "remove", names: [name, ...more] }]; title = `remove ${[name, ...more].join(", ")}`; }
      else throw new Error(`wb write <add|edit|move|rename|remove> …\n\n${HELP}`);
      const ch = applyChange(s, { by, ops, title });
      return out(`${title} (rev ${ch.rev})\n`);
    }
    case "flag": {
      const [name, flag] = rest;
      const by = flags.by || "agent";
      const s = session();
      const doc = docFor(s);
      const existing = doc.attachments.find((a) => a.block === name && a.kind === flag && a.state === "active");
      if (flags.off) {
        if (!existing) return out(`${flag} not set on ${name}\n`);
        const ch = appendChange(s.dir, { title: `clear ${flag} on ${name}`, by, ops: [detachOp(existing.id)] });
        return out(`cleared ${flag} on ${name} (rev ${ch.rev})\n`);
      }
      if (existing) return out(`${flag} already set on ${name}\n`);
      const op = attachOp(flag, name, { body: flags.text || null, by });
      const ch = appendChange(s.dir, { title: `set ${flag} on ${name}`, by, ops: [op] });
      return out(`set ${flag} on ${name} (rev ${ch.rev})\n`);
    }
    case "comment": {
      const [name] = rest;
      const body = flags.text !== undefined ? flags.text : (flags.file ? fs.readFileSync(flags.file, "utf8") : rest.slice(1).join(" "));
      if (!body) throw new Error("usage: wb comment <name> <text|--file> [--by who] [--exact …]");
      const by = flags.by || "agent";
      const s = session();
      const doc = docFor(s);
      let selector = null;
      if (flags.exact) {
        const b = doc.blocks.find((x) => x.name === name);
        if (!b) throw new Error(`no block "${name}"`);
        selector = selectorFor(b.md, flags.exact);
      }
      const op = attachOp("comment", name, { body, by, selector });
      validateOps(doc, [op]);
      const ch = appendChange(s.dir, { title: `comment on ${name}`, by, ops: [op] });
      return out(`${op.id} (rev ${ch.rev})\n`);
    }
    case "reply": {
      const [id] = rest;
      const body = flags.text !== undefined ? flags.text : rest.slice(1).join(" ");
      const by = flags.by || "agent";
      const op = replyOp(id, body, { by });
      const ch = applyChange(session(), { title: `reply to ${id}`, by, ops: [op] });
      return out(`${op.id} (rev ${ch.rev})\n`);
    }
    case "attention": {
      const [name] = rest;
      const reason = flags.text !== undefined ? flags.text : rest.slice(1).join(" ");
      const by = flags.by || "agent";
      const op = attachOp("needs-attention", name, { body: reason || "Needs your attention.", motivation: "highlighting", by });
      const ch = applyChange(session(), { title: `attention on ${name}`, by, ops: [op] });
      return out(`${op.id} (rev ${ch.rev})\n`);
    }
    case "resolve": {
      const [id] = rest;
      const resolved = !flags.unresolve;
      const op = resolveOp(id, resolved);
      const ch = applyChange(session(), { title: `${resolved ? "resolve" : "unresolve"} ${id}`, by: flags.by || "agent", ops: [op] });
      return out(`${resolved ? "resolved" : "unresolved"} ${id} (rev ${ch.rev})\n`);
    }
    case "detach": {
      const [id] = rest;
      const ch = applyChange(session(), { title: `detach ${id}`, by: flags.by || "agent", ops: [detachOp(id)] });
      return out(`detached ${id} (rev ${ch.rev})\n`);
    }
    case "amend": {
      const [id] = rest;
      const s = session();
      const doc = docFor(s);
      const a = doc.attachments.find((x) => x.id === id);
      if (!a) throw new Error(`no attachment "${id}"`);
      let selector, body;
      if (flags.text !== undefined) body = flags.text;
      if (flags.exact !== undefined) { const b = doc.blocks.find((x) => x.name === a.block); if (!b) throw new Error(`no block "${a.block}"`); selector = selectorFor(b.md, flags.exact); }
      if (body === undefined && selector === undefined) throw new Error("usage: wb amend <id> [--text T] [--exact …]");
      const ch = appendChange(s.dir, { title: `amend ${id}`, by: flags.by || "agent", ops: [amendOp(id, { body, selector })] });
      return out(`amended ${id} (rev ${ch.rev})\n`);
    }
    case "change": {
      const title = flags.title || rest[0];
      if (!title) throw new Error('usage: wb change "<title>" [--summary S] --ops -|--file F');
      const ops = readOps(flags);
      const ch = applyChange(session(), { id: changeIdFor(title), title, by: flags.by || "agent", summary: flags.summary || null, ops });
      return out(`change "${title}" applied (rev ${ch.rev}, ${ops.length} ops) → changes/${String(ch.rev).padStart(6, "0")}.json\n`);
    }
    case "note": {
      const s = session();
      const body = flags.text !== undefined ? flags.text : (flags.file ? fs.readFileSync(flags.file, "utf8") : rest.join(" "));
      if (!body) throw new Error("usage: wb note <text|--file>");
      const f = path.join(s.dir, "notes.md");
      const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
      fs.appendFileSync(f, `\n- (${stamp}) ${body.replace(/\n/g, "\n  ")}\n`);
      return out(`noted\n`);
    }
    default:
      throw new Error(`unknown command "${cmd}"\n\n${HELP}`);
  }
}

main().catch((e) => {
  process.stderr.write(`wb: ${e.message}\n`);
  process.exit(typeof e.code === "number" ? e.code : 1);
});