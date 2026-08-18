#!/usr/bin/env node
// main.mjs — wb CLI entry point. The document is an append-only change log
// (changes/<rev>.json). The ONLY way to mutate it is a staging transaction via
// `wb change` (see staging.mjs): `wb change "<title>"` opens a staging area,
// `wb change <op> …` stages ops, `wb change send` commits them as one named
// change. `wb read` projects the fold. Session scope: --session / WB_SESSION /
// ~/.wb/current (store.mjs).

import fs from "node:fs";
import path from "node:path";
import { resolveSession, setCurrent, listSessions, sessionDir, projectFromCwd, slugify, stampOwner } from "./store.mjs";
import { readTagged, readMd, readJson } from "./blocks.mjs";
import { parseMarkdownToBlocks } from "./migrate.mjs";
import { loadDoc, appendChange } from "./doc.mjs";
import { startChange, sendChange, discardChange, statusChange, stageSubcommand, isChangeSub } from "./staging.mjs";

const HELP = `wb — whiteboard change-log document CLI
  wb new <slug> [--from <md-file>]        create a session (optionally seed from markdown)
  wb list [--json]                        list sessions for this project
  wb use <slug>                           set current session (claims it for this agent)
  wb read [--md|--json] [slug]            project the doc (default: tagged <name>…</name>)
  wb change "<title>" [--summary S]       START a staging transaction (one at a time)
  wb change send                          COMMIT staged ops as one change
  wb change status                        peek at staged ops
  wb change discard  (alias: kill)        abort the staging transaction
  wb note <text|--file>                   append to notes.md

  Staging ops (run between \`wb change "<title>"\` and \`wb change send\`):
  wb change edit <block> (--file <f|-> | --text T | --diff <f|->)
  wb change add <name> [--before X|--after X] (--file <f|-> | --text T)
  wb change move <name> --before X|--after X
  wb change rename <old> <new>
  wb change remove <name> [name…]
  wb change comment <block> (--text T|--file F) [--exact quote] [--by who]
  wb change reply <thread-id> (--text T|--file F) [--by who]
  wb change resolve <thread-id>   |   wb change unresolve <thread-id>
  wb change flag <block> <flag> [--clear] [--text reason]   set/clear a label (needs-attention|decided|…)
  wb change attention <block> (--text T)                   flag needs-attention + amber card
  wb change amend <thread-id> (--text T) [--exact quote] [--by who]
  wb change detach <thread-id>

The document = fold of changes/<rev>.json; every mutation is a staged \`wb change\` then \`wb change send\`.
Ops are intent: comment/reply/resolve/flag/amend/detach ids + attachment state are derived for you.
Scope: --session <project>/<slug> > WB_SESSION > ~/.wb/current (this project).
A staging left open >5m auto-sends when you next start a new \`wb change "<title>"\`.`;

function parse(argv) {
  const positional = [], flags = {};
  const BOOL = new Set(["json", "md", "help", "clear"]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") { positional.push(...argv.slice(i + 1)); break; }
    if (a.startsWith("--")) {
      const k = a.slice(2);
      if (BOOL.has(k)) { flags[k] = true; continue; }
      flags[k] = argv[++i];
    } else positional.push(a);
  }
  return { positional, flags };
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
        appendChange(dir, { id: "initial", title: "Initial import", ops });
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
    case "change": {
      const s = session();
      const first = rest[0];
      if (first === "send") { const ch = sendChange(s); return out(`change "${ch.title}" applied (rev ${ch.rev}, ${ch.ops.length} ops) → changes/${String(ch.rev).padStart(6, "0")}.json\n`); }
      if (first === "discard" || first === "kill") return out(discardChange(s) + "\n");
      if (first === "status") return out(statusChange(s) + "\n");
      if (first && isChangeSub(first)) return out(stageSubcommand(s, first, rest.slice(1), flags) + "\n");
      const title = flags.title || first;
      return out(startChange(s, { title, summary: flags.summary, by: flags.by }) + "\n");
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