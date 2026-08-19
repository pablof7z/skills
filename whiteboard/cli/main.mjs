#!/usr/bin/env node
// main.mjs — wb CLI entry point. The document is an append-only change log
// (changes/<rev>.json). The ONLY way to mutate it is a staging transaction via
// `wb change` (see staging.mjs): `wb change "<title>"` opens a staging area,
// `wb change <op> …` stages ops, `wb change send` commits them as one named
// change. `wb read` projects the fold. Session scope: --session / WB_SESSION /
// per-agent owners map (store.mjs).

import fs from "node:fs";
import path from "node:path";
import { resolveSession, claimSession, listSessions, sessionDir, projectFromCwd, slugify, stampOwner } from "./store.mjs";
import { readTagged, readMd, readJson } from "./blocks.mjs";
import { parseMarkdownToBlocks } from "./migrate.mjs";
import { loadDoc, appendChange, DEFAULT_PATH } from "./doc.mjs";
import { startChange, sendChange, discardChange, statusChange, stageSubcommand, isChangeSub } from "./staging.mjs";
import { attachCreate, attachReply, attachResolve, attachReopen, tagSet, tagClear, listAnnotations } from "./annotations.mjs";
import { actionableItems } from "./scan.mjs";

// Annotation ops that used to live under `wb change` — now direct writes under
// `wb attach` / `wb tag`. Listed so `wb change <op>` gives a redirect instead of
// silently starting a staging transaction named after the op.
const REMOVED_ANNOTATION_OPS = new Set(["comment", "reply", "resolve", "unresolve", "flag", "attention", "amend", "detach"]);

const HELP = `wb — whiteboard change-log document CLI
  wb new <slug> [--from <md-file>]        create a session (optionally seed from markdown)
  wb list [--json]                        list sessions for this project
  wb use <slug>                           claim a session for this agent (stamps manifest.owner)
  wb read [--md|--json] [--path P] [slug]   project the doc (default: tagged <name>…</name>)
  wb change "<title>" [--summary S]       START a staging transaction (one at a time)
  wb change send                          COMMIT staged ops as one change
  wb change status                        peek at staged ops
  wb change discard  (alias: kill)        abort the staging transaction
  wb note <text|--file>                   append to notes.md
  wb attach <block> --on "quote" --kind question|warning|objection|note --content T
                                          anchor a thread to a span (direct write)
  wb attach reply|resolve|reopen <id> [--content T]   thread lifecycle (direct)
  wb attach list [--block X] [--open]                list threads
  wb tag <block> --on "quote" --kind unverified|superseded|needs-attention|decided
                                          [--content T]   set a status tag (direct)
  wb tag <block> --on "quote" --kind K --clear       clear a tag (direct)
  wb tag list [--block X]                            list tags
  wb listen [--timeout 0]                 stream actionable items: emit one JSONL event for a new
                                          unanswered comment/chat, then exit 0 (idle→exit 2).
                                          Run as a background monitor; its completion wakes you.
                                          Baselines existing items so only NEW ones fire.

  Staging ops (run between \`wb change "<title>"\` and \`wb change send\`) — artifact only:
  wb change edit <block> (--file <f|-> | --text T | --diff <f|->)
  wb change add <name> [--before X|--after X] (--file <f|-> | --text T)
  wb change move <name> --before X|--after X
  wb change rename <old> <new>
  wb change remove <name> [name…]

  Annotations (questions/warnings/objections/notes + status tags) are NOT staged:
  use \`wb attach\` / \`wb tag\` directly. Every annotation is anchored (--on required).

The document = fold of changes/<rev>.json; artifact edits are staged \`wb change\` then \`wb change send\`; annotations are direct \`wb attach\`/\`wb tag\` writes.
Ops are intent: ids + annotation state are derived for you.
Scope: --session <project>/<slug> > WB_SESSION > per-agent owners map (~/.wb/owners.json).
A staging left open >5m auto-sends when you next start a new \`wb change "<title>"\`.`;

function parse(argv) {
  const positional = [], flags = {};
  const BOOL = new Set(["json", "md", "help", "clear", "open"]);
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

// Resolve annotation content from --content (primary), --text (alias), --file, or stdin.
function readAttachContent(flags, { optional = false } = {}) {
  if (flags.content !== undefined) return String(flags.content);
  if (flags.text !== undefined) return String(flags.text);
  if (flags.file) return fs.readFileSync(flags.file, "utf8");
  if (!process.stdin.isTTY) return fs.readFileSync(0, "utf8");
  if (optional) return null;
  throw new Error("no content: pass --content, --file, or pipe via stdin");
}

// `wb new`/`wb use` record this agent's session in the per-agent owners map and
// stamp manifest.owner. They can't set WB_SESSION (a child can't mutate parent
// env), so they print the explicit --session value too — but later `wb` calls
// with no --session auto-resolve via the owners map (keyed by PI_SESSION_ID or
// the stable agent-harness pid, so concurrent agents never clobber each other).
function printSessionHint(project, slug) {
  const target = `${project}/${slug}`;
  process.stderr.write(`for subsequent commands: --session ${target}  (or: export WB_SESSION=${target})\n`);
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
        const ops = blocks.map((b) => ({ op: "add", name: b.name, md: b.md, path: flags.path || DEFAULT_PATH }));
        appendChange(dir, { id: "initial", title: "Initial import", ops });
      }
      stampOwner(dir, process.env.WB_OWNER);
      claimSession(project, slug);
      printSessionHint(project, slug);
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
      stampOwner(sessionDir(project, slugify(slug)), process.env.WB_OWNER);
      claimSession(project, slugify(slug));
      printSessionHint(project, slugify(slug));
      return out(`using ${project}/${slugify(slug)}\n`);
    }
    case "read": {
      const s = session();
      const doc = loadDoc(s.dir);
      if (!doc) throw new Error(`no document in ${s.dir}`);
      if (flags.json) return out(readJson(doc));
      if (flags.md) return out(readMd(doc, flags.path));
      return out(readTagged(doc, flags.path));
    }
    case "change": {
      const s = session();
      const first = rest[0];
      if (first === "send") { const ch = sendChange(s); return out(`change "${ch.title}" applied (rev ${ch.rev}, ${ch.ops.length} ops) → changes/${String(ch.rev).padStart(6, "0")}.json\n`); }
      if (first === "discard" || first === "kill") return out(discardChange(s) + "\n");
      if (first === "status") return out(statusChange(s) + "\n");
      if (REMOVED_ANNOTATION_OPS.has(first)) throw new Error(`\`wb change ${first}\` moved: annotation ops are direct writes under \`wb attach\` / \`wb tag\`, not staged via \`wb change\`.`);
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
    case "attach": {
      const s = session();
      const sub = rest[0];
      const ATTACH_SUB = new Set(["reply", "resolve", "reopen", "list"]);
      if (sub === "list") return out(listAnnotations(s, { block: flags.block, path: flags.path, tags: false, open: flags.open }) + "\n");
      if (ATTACH_SUB.has(sub)) {
        const id = rest[1];
        if (sub === "reply") return out(attachReply(s, id, { content: readAttachContent(flags), by: flags.by }) + "\n");
        if (sub === "resolve") return out(attachResolve(s, id, { by: flags.by }) + "\n");
        if (sub === "reopen") return out(attachReopen(s, id, { by: flags.by }) + "\n");
      }
      // create: wb attach <block> --on --kind --content
      return out(attachCreate(s, { block: sub, on: flags.on, kind: flags.kind, content: readAttachContent(flags), by: flags.by, path: flags.path }) + "\n");
    }
    case "tag": {
      const s = session();
      const sub = rest[0];
      if (sub === "list") return out(listAnnotations(s, { block: flags.block, path: flags.path, tags: true }) + "\n");
      // set or clear: wb tag <block> --on --kind [--content] [--clear]
      const opts = { block: sub, on: flags.on, kind: flags.kind, content: readAttachContent(flags, { optional: true }), by: flags.by, path: flags.path };
      return out((flags.clear ? tagClear(s, opts) : tagSet(s, opts)) + "\n");
    }
    case "listen": {
      const s = session();
      let timeout = 0;
      if (flags.timeout !== undefined) timeout = Number(flags.timeout);
      const where = `${s.project}/${s.slug}`;
      const baseline = new Set(actionableItems(s.dir).map((it) => `${it.kind}:${it.id}`));
      const deadline = timeout > 0 ? Date.now() + timeout * 1000 : 0;
      const tick = () => {
        for (const it of actionableItems(s.dir)) {
          const key = `${it.kind}:${it.id}`;
          if (baseline.has(key)) continue;
          const evt = { kind: it.kind, id: it.id, block: it.block || null, session: where, text: it.text || "" };
          if (it.anchor) evt.anchor = it.anchor;
          process.stdout.write(JSON.stringify(evt) + "\n");
          process.exit(0);
        }
        if (deadline && Date.now() > deadline) { process.stdout.write(JSON.stringify({ kind: "idle", session: where }) + "\n"); process.exit(2); }
      };
      setInterval(tick, 1000);
      tick();
      return; // unreachable; tick exits
    }
    default:
      throw new Error(`unknown command "${cmd}"\n\n${HELP}`);
  }
}

main().catch((e) => {
  process.stderr.write(`wb: ${e.message}\n`);
  process.exit(typeof e.code === "number" ? e.code : 1);
});