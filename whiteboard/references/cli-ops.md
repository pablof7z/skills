# Agent Notes CLI operations (`agentnotes`)

Brief how-to for the `agentnotes` CLI — the portable way to drive a whiteboard session from any harness. Run `agentnotes help` for the full reference. Install it from [pablof7z/agentnotes](https://github.com/pablof7z/agentnotes) (`git clone`, `npm install --workspaces`, `npm link`); it then lives on PATH as `agentnotes`.

Two mutation surfaces, kept deliberately apart:

- **`agentnotes change` — the artifact.** Block edits, staged into one atomic revision. Annotations are *not* staged here.
- **`agentnotes attach` / `agentnotes tag` — annotations.** Meta-discussion about the document (questions/warnings/objections/notes + status tags), written directly, one command each, like `agentnotes note`.

Every annotation is **anchored** to a text span (`--on` required). There are no block-level annotations — if you mean a whole block, anchor to its heading.

## Sessions

```bash
agentnotes new <slug> [--from <md-file>]   # create (optionally seed from a markdown doc)
agentnotes use <slug>                      # claim an existing session for this agent
agentnotes list [--json]                   # list this project's sessions
```

`agentnotes new`/`agentnotes use` stamp `manifest.owner` and record this agent in the per-agent owners map, so later `agentnotes` calls resolve the session automatically.

## Read

```bash
agentnotes read [--md|--json]              # default: tagged <name>…</name>; --md = plain markdown; --json = tree
```

## Compare revisions

```bash
agentnotes diff <before-rev> <after-rev> [--path P]
```

Returns a read-only unified diff of artifact document content. Revisions are
`0`, an existing revision number, or `current`; `--path` narrows a multi-file
document to one path. Attachments and tags have their own lifecycle, so they
are not part of this document-content comparison.

## Mutate the artifact — one staging transaction

Open a change, stage ops, commit. One staging transaction at a time per session; a staging left open >5 min auto-sends when you next start a new one. Artifact ops only — annotation ops moved to `agentnotes attach`/`agentnotes tag` (running them under `agentnotes change` prints a redirect).

```bash
agentnotes change "<title>" [--summary S]          # start
agentnotes change send                             # commit (one rev, one title)
agentnotes change discard                          # abort
agentnotes change status                           # peek at staged ops
```

Stage ops (between start and send):

```bash
agentnotes change add <name> [--before X|--after X] --text T | --file f | -   # add a block
agentnotes change edit <block> --text T | --diff f | -                        # replace a block's markdown
agentnotes change move <name> --before X|--after X                            # reorder
agentnotes change rename <old> <new>                                          # rename (cascades annotations)
agentnotes change remove <name> [name…]                                       # delete block(s)
```

Block names are lowercase slugs (`[a-z0-9-]`), unique within a path. Pass `--by <name>` (or set `AGENT_NAME`) to record the author.

## Annotations — direct writes (not staged)

Two verbs sharing one storage primitive (an `attach` op with a `kind`); `kind` drives color in the viewer. `--on` is mandatory for create/set/clear.

**`agentnotes attach` — replyable threads** (kinds: `question` | `warning` | `objection` | `note`):

```bash
agentnotes attach <block> --on "quote" --kind question|warning|objection|note --content T [--by who] [--path P]
agentnotes attach reply <id> --content T [--by who]
agentnotes attach resolve <id>
agentnotes attach reopen <id>
agentnotes attach list [--block X] [--path P] [--open]
```

`note` is a non-action side comment (does not wake the agent); `question`/`warning`/`objection` from a user with no agent reply are actionable.

**`agentnotes tag` — short status tags** (kinds: `unverified` | `superseded` | `needs-attention` | `decided`):

```bash
agentnotes tag <block> --on "quote" --kind <tag-kind> [--content T] [--by who] [--path P]   # set (idempotent)
agentnotes tag <block> --on "quote" --kind <tag-kind> --clear [--by who] [--path P]         # clear
agentnotes tag list [--block X] [--path P]
```

A typical first seed:

```bash
agentnotes new 2026-08-nmp-relay-identity-model
agentnotes change "seed session"
agentnotes change add goal --text "# Goal\nResolve how NMP relay identity is modeled."
agentnotes change add constraints --text "# Constraints\n- Must survive key rotation."
agentnotes change send
agentnotes attach goal --on "Resolve how NMP relay identity is modeled." --kind question --content "Per-key or per-session identity?" --by user
```

## Notes

```bash
agentnotes note "trail entry"             # append to notes.md (append-only; do not rewrite)
agentnotes note --file f                  # append from a file
```

## Detect new annotations/chat (portable)

```bash
agentnotes listen [--session <project>/<slug>] [--timeout 0]
```

Baselines existing actionable items, then prints one JSONL event and exits `0` as soon as a NEW actionable item lands (an unresolved human thread — `question`/`warning`/`objection` — with no agent reply, or a human chat with no agent chat reply). `note` threads and tags are not actionable. `--timeout N` exits `2` with `{"kind":"idle"}` after N seconds. Run it as a background monitor; wire its completion to wake you, handle the item, then relaunch.

Event shapes (`text` is the full human text, untruncated; `anchor` is the full highlighted span — always present now that every annotation is anchored):
```json
{"kind":"annotation","id":"c-…","block":"goal","session":"proj/slug","text":"…","anchor":"…"}
{"kind":"chat","id":"…","block":null,"session":"proj/slug","text":"…"}
```

Reply to an annotation with `agentnotes attach reply …` then `agentnotes attach resolve …`. Reply to chat by writing an agent chat message file into the session's `chat/` dir (`{id, role:"agent", text, created}`); there is no `agentnotes chat` command.

## Scope

`--session <project>/<slug>` → `AGENTNOTES_SESSION` env → per-agent owners map (`~/.agentnotes/owners.json`, keyed by `PI_SESSION_ID` or the stable agent-harness pid). Concurrent agents each resolve to their own session — no clobber.
