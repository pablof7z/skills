#!/usr/bin/env node
// main.mjs — wb CLI entry point. Dispatches to store/blocks/annotations/migrate.
// `wb read` defaults to the tagged <name>…</name> projection; --md plain, --json raw.
// Mutations go through `wb write …` and the comment/flag family. Session scope is
// resolved from --session / WB_SESSION / ~/.wb/current (see store.mjs).

import fs from "node:fs";
import path from "node:path";
import {
  resolveSession, loadDoc, saveDoc, newDoc, setCurrent, listSessions,
  sessionDir, projectFromCwd, slugify, stampOwner,
} from "./store.mjs";
import {
  readTagged, readMd, readJson, writeAdd, writeEdit, writeMove,
  writeRename, writeRemove, setFlag,
} from "./blocks.mjs";
import {
  addComment, addReply, resolveComment, markAttention,
} from "./annotations.mjs";
import { parseMarkdownToBlocks } from "./migrate.mjs";

const HELP = `wb — whiteboard block document CLI
  wb new <slug> [--from <md-file>]   create a session (migrate markdown if --from)
  wb list [--json]                   list sessions for this project
  wb use <slug>                      set current session
  wb read [--md|--json] [slug]       project the doc (default: tagged <name>…</name>)
  wb write add <name> [--before X|--after X] [--text T|--file F|stdin]   add a block
  wb write edit <name> [--text T|--file F|stdin]                         replace a block
  wb write move <name> --before X|--after X     reorder a block
  wb write rename <old> <new>                    rename (cascades comments)
  wb write remove <name> [name…]                 delete block(s) + their comments
  wb flag <name> <flag> [--on|--off]             set/clear needs-attention|decided|superseded
  wb comment <name> <text|--file> [--by who] [--exact "..."]   attach a comment
  wb reply <comment-id> <text> [--by who]        reply in a thread
  wb attention <name> [reason]                  flag needs-attention + comment
  wb resolve <comment-id> [--unresolve]          resolve/unresolve a comment
  wb note <text|--file>                          append to notes.md
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

function withDoc(session, fn) {
  const { dir } = session;
  const doc = loadDoc(dir);
  if (!doc) throw new Error(`no document.json in ${dir} — run \`wb new\` or migrate first`);
  const out = fn(doc);
  saveDoc(dir, doc);
  return out;
}

function out(obj) { process.stdout.write(typeof obj === "string" ? obj : JSON.stringify(obj, null, 2) + "\n"); }

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
      if (fs.existsSync(path.join(dir, "document.json"))) throw new Error(`session ${project}/${slug} already exists`);
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({
        name: slug, status: "exploring", project, createdAt: new Date().toISOString(),
        ...(process.env.WB_OWNER ? { owner: process.env.WB_OWNER } : {}),
      }, null, 2) + "\n");
      const doc = newDoc();
      if (flags.from) {
        const md = fs.readFileSync(flags.from, "utf8");
        doc.blocks = parseMarkdownToBlocks(md);
      }
      saveDoc(dir, doc);
      setCurrent(project, slugify(slug));
      return out(`created ${project}/${slugify(slug)} → ${dir}\n`);
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
      if (!doc) throw new Error(`no document.json in ${s.dir}`);
      if (flags.json) return out(readJson(doc));
      if (flags.md) return out(readMd(doc));
      return out(readTagged(doc));
    }
    case "write": {
      const [op, name, ...more] = rest;
      if (op === "add") return out(withDoc(session(), (d) => writeAdd(d, slugify(name), readContent(flags), { before: flags.before, after: flags.after })?.name) + "\n");
      if (op === "edit") return out(withDoc(session(), (d) => writeEdit(d, name, readContent(flags)) && `edited ${name}\n`));
      if (op === "move") return out(withDoc(session(), (d) => writeMove(d, name, { before: flags.before, after: flags.after }) && `moved ${name}\n`));
      if (op === "rename") return out(withDoc(session(), (d) => writeRename(d, name, more[0]) && `renamed ${name} → ${more[0]}\n`));
      if (op === "remove") return out(withDoc(session(), (d) => writeRemove(d, [name, ...more]) && `removed ${[name, ...more].join(", ")}\n`));
      throw new Error(`wb write <add|edit|move|rename|remove> …\n\n${HELP}`);
    }
    case "flag": {
      const [name, flag] = rest;
      const on = flags.off ? false : true;
      return out(withDoc(session(), (d) => setFlag(d, name, flag, on) && `${on ? "set" : "cleared"} ${flag} on ${name}\n`));
    }
    case "comment": {
      const [name] = rest;
      const body = flags.text !== undefined ? flags.text : (flags.file ? fs.readFileSync(flags.file, "utf8") : rest.slice(1).join(" "));
      if (!body) throw new Error("usage: wb comment <name> <text|--file> [--by who] [--exact …]");
      return out(withDoc(session(), (d) => addComment(d, name, body, { by: flags.by || "agent", exact: flags.exact }).id) + "\n");
    }
    case "reply": {
      const [id] = rest;
      const body = flags.text !== undefined ? flags.text : rest.slice(1).join(" ");
      return out(withDoc(session(), (d) => addReply(d, id, body, { by: flags.by || "agent" }).id) + "\n");
    }
    case "attention": {
      const [name] = rest;
      const reason = flags.text !== undefined ? flags.text : rest.slice(1).join(" ");
      return out(withDoc(session(), (d) => markAttention(d, name, reason, { by: flags.by || "agent" }).id) + "\n");
    }
    case "resolve": {
      const [id] = rest;
      const resolved = !flags.unresolve;
      return out(withDoc(session(), (d) => resolveComment(d, id, resolved) && `${resolved ? "resolved" : "unresolved"} ${id}\n`));
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