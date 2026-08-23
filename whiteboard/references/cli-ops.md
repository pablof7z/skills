# Agent Notes CLI operations (`pad`)

Brief how-to for the `pad` CLI — the portable way to drive a whiteboard session from any harness. Run `pad help` for the full reference. Install it from [pablof7z/agentnotes](https://github.com/pablof7z/agentnotes) (`git clone`, `npm install --workspaces`, `npm link`); it then lives on PATH as `pad`.

Three surfaces, kept deliberately apart:

- **`pad change` — the artifact.** Block edits, staged into one atomic revision. Annotations are *not* staged here.
- **`pad attach` / `pad tag` — annotations.** Meta-discussion about the document (questions/warnings/objections/notes + status tags), written directly, one command each.
- **`pad note` / `pad notes` — your private meta-notes log.** Free text, append-only, no schema — not part of the artifact.

Every annotation is **anchored** to a text span (`--on` required). There are no block-level annotations — if you mean a whole block, anchor to its heading.

## Sessions

```bash
pad new <slug> [--from <md-file>]   # create (optionally seed from a markdown doc)
pad use <slug>                      # claim an existing session for this agent
pad list [--json]                   # list this project's sessions
```

`pad new`/`pad use` stamp `manifest.owner` and record this agent in the per-agent owners map, so later `pad` calls resolve the session automatically.

## Read

```bash
pad read [--md|--json]              # default: tagged <name>…</name>; --md = plain markdown; --json = tree
```

## Compare revisions

```bash
pad diff <before-rev> <after-rev> [--path P]
```

Returns a read-only unified diff of artifact document content. Revisions are
`0`, an existing revision number, or `current`; `--path` narrows a multi-file
document to one path. Attachments and tags have their own lifecycle, so they
are not part of this document-content comparison.

## Mutate the artifact — one staging transaction

Open a change, stage ops, commit. One staging transaction at a time per session; a staging left open >5 min auto-sends when you next start a new one. Artifact ops only — annotation ops moved to `pad attach`/`pad tag` (running them under `pad change` prints a redirect).

```bash
pad change "<title>" [--summary S]          # start
pad change send                             # commit (one rev, one title)
pad change discard                          # abort
pad change status                           # peek at staged ops
```

Stage ops (between start and send):

```bash
pad change add <name> [--before X|--after X] --text T | --file f | -   # add a block
pad change edit <block> --text T | --diff f | -                        # replace a block's markdown
pad change move <name> --before X|--after X                            # reorder
pad change rename <old> <new>                                          # rename (cascades annotations)
pad change remove <name> [name…]                                       # delete block(s)
```

Block names are lowercase slugs (`[a-z0-9-]`), unique within a path. Pass `--by <name>` (or set `AGENT_NAME`) to record the author.

## Annotations — direct writes (not staged)

Two verbs sharing one storage primitive (an `attach` op with a `kind`); `kind` drives color in the viewer. `--on` is mandatory for create/set/clear.

**`pad attach` — replyable threads** (kinds: `question` | `warning` | `objection` | `note`):

```bash
pad attach <block> --on "quote" --kind question|warning|objection|note --content T [--by who] [--path P]
pad attach reply <id> --content T [--by who]
pad attach resolve <id>
pad attach reopen <id>
pad attach list [--block X] [--path P] [--open]
```

`note` is a non-action side comment (does not wake the agent); `question`/`warning`/`objection` from a user with no agent reply are actionable.

**`pad tag` — short status tags** (kinds: `unverified` | `superseded` | `needs-attention` | `decided`):

```bash
pad tag <block> --on "quote" --kind <tag-kind> [--content T] [--by who] [--path P]   # set (idempotent)
pad tag <block> --on "quote" --kind <tag-kind> --clear [--by who] [--path P]         # clear
pad tag list [--block X] [--path P]
```

A typical first seed:

```bash
pad new 2026-08-nmp-relay-identity-model
pad change "seed session"
pad change add goal --text "# Goal\nResolve how NMP relay identity is modeled."
pad change add constraints --text "# Constraints\n- Must survive key rotation."
pad change send
pad attach goal --on "Resolve how NMP relay identity is modeled." --kind question --content "Per-key or per-session identity?" --by user
```

## Meta-Notes

A private, append-only, free-text log — never touch the raw file path, only these two commands (pi/MCP: `pad_meta_notes_add`/`pad_meta_notes_view`). Write terse: the fact, no narration, no filler — a non-blocking warning comes back if an entry runs long or reads like prose (see references/note-schema-and-examples.md).

```bash
pad note "trail entry"             # append (append-only; do not rewrite)
pad note --file f                  # append from a file
pad notes                          # print the full meta-notes log
```

If several `pad change send`/`pad apply` calls land with no `pad note` between them, the 3rd (and every one after, until you log one) prints a reminder — the trail is going cold, log why.

## Detect new annotations/chat (portable)

```bash
pad listen [--session <project>/<slug>] [--timeout 0]
```

Baselines existing actionable items, then prints one JSONL event and exits `0` as soon as a NEW actionable item lands (an unresolved human thread — `question`/`warning`/`objection` — with no agent reply, or a human chat with no agent chat reply). `note` threads and tags are not actionable. `--timeout N` exits `2` with `{"kind":"idle"}` after N seconds. Run it as a background monitor; wire its completion to wake you, handle the item, then relaunch.

Event shapes (`text` is the full human text, untruncated; `anchor` is the full highlighted span — always present now that every annotation is anchored):
```json
{"kind":"annotation","id":"c-…","block":"goal","session":"proj/slug","text":"…","anchor":"…"}
{"kind":"chat","id":"…","block":null,"session":"proj/slug","text":"…"}
```

Reply to an annotation with `pad attach reply …` then `pad attach resolve …`. Reply to chat by writing an agent chat message file into the session's `chat/` dir (`{id, role:"agent", text, created}`); there is no `pad chat` command.

## Scope

`--session <project>/<slug>` → `PAD_SESSION` env → per-agent owners map (`~/.pad/owners.json`, keyed by `PI_SESSION_ID` or the stable agent-harness pid). Concurrent agents each resolve to their own session — no clobber.
