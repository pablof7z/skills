# Whiteboard CLI operations (`wb`)

Brief how-to for the `wb` CLI — the portable way to drive a whiteboard session from any harness. Run `wb help` for the full reference. `wb` is on PATH (`~/.local/bin/wb`); if not, invoke `<skill-dir>/whiteboard/bin/wb` or `node <skill-dir>/whiteboard/cli/main.mjs …`.

Two mutation surfaces, kept deliberately apart:

- **`wb change` — the artifact.** Block edits, staged into one atomic revision. Annotations are *not* staged here.
- **`wb attach` / `wb tag` — annotations.** Meta-discussion about the document (questions/warnings/objections/notes + status tags), written directly, one command each, like `wb note`.

Every annotation is **anchored** to a text span (`--on` required). There are no block-level annotations — if you mean a whole block, anchor to its heading.

## Sessions

```bash
wb new <slug> [--from <md-file>]   # create (optionally seed from a markdown doc)
wb use <slug>                      # claim an existing session for this agent
wb list [--json]                   # list this project's sessions
```

`wb new`/`wb use` stamp `manifest.owner` and record this agent in the per-agent owners map, so later `wb` calls resolve the session automatically.

## Read

```bash
wb read [--md|--json]              # default: tagged <name>…</name>; --md = plain markdown; --json = tree
```

## Compare revisions

```bash
wb diff <before-rev> <after-rev> [--path P]
```

Returns a read-only unified diff of artifact document content. Revisions are
`0`, an existing revision number, or `current`; `--path` narrows a multi-file
document to one path. Attachments and tags have their own lifecycle, so they
are not part of this document-content comparison.

## Mutate the artifact — one staging transaction

Open a change, stage ops, commit. One staging transaction at a time per session; a staging left open >5 min auto-sends when you next start a new one. Artifact ops only — annotation ops moved to `wb attach`/`wb tag` (running them under `wb change` prints a redirect).

```bash
wb change "<title>" [--summary S]          # start
wb change send                             # commit (one rev, one title)
wb change discard                          # abort
wb change status                           # peek at staged ops
```

Stage ops (between start and send):

```bash
wb change add <name> [--before X|--after X] --text T | --file f | -   # add a block
wb change edit <block> --text T | --diff f | -                        # replace a block's markdown
wb change move <name> --before X|--after X                            # reorder
wb change rename <old> <new>                                          # rename (cascades annotations)
wb change remove <name> [name…]                                       # delete block(s)
```

Block names are lowercase slugs (`[a-z0-9-]`), unique within a path. Pass `--by <name>` (or set `AGENT_NAME`) to record the author.

## Annotations — direct writes (not staged)

Two verbs sharing one storage primitive (an `attach` op with a `kind`); `kind` drives color in the viewer. `--on` is mandatory for create/set/clear.

**`wb attach` — replyable threads** (kinds: `question` | `warning` | `objection` | `note`):

```bash
wb attach <block> --on "quote" --kind question|warning|objection|note --content T [--by who] [--path P]
wb attach reply <id> --content T [--by who]
wb attach resolve <id>
wb attach reopen <id>
wb attach list [--block X] [--path P] [--open]
```

`note` is a non-action side comment (does not wake the agent); `question`/`warning`/`objection` from a user with no agent reply are actionable.

**`wb tag` — short status tags** (kinds: `unverified` | `superseded` | `needs-attention` | `decided`):

```bash
wb tag <block> --on "quote" --kind <tag-kind> [--content T] [--by who] [--path P]   # set (idempotent)
wb tag <block> --on "quote" --kind <tag-kind> --clear [--by who] [--path P]         # clear
wb tag list [--block X] [--path P]
```

A typical first seed:

```bash
wb new 2026-08-nmp-relay-identity-model
wb change "seed session"
wb change add goal --text "# Goal\nResolve how NMP relay identity is modeled."
wb change add constraints --text "# Constraints\n- Must survive key rotation."
wb change send
wb attach goal --on "Resolve how NMP relay identity is modeled." --kind question --content "Per-key or per-session identity?" --by user
```

## Notes

```bash
wb note "trail entry"             # append to notes.md (append-only; do not rewrite)
wb note --file f                  # append from a file
```

## Detect new annotations/chat (portable)

```bash
wb listen [--session <project>/<slug>] [--timeout 0]
```

Baselines existing actionable items, then prints one JSONL event and exits `0` as soon as a NEW actionable item lands (an unresolved human thread — `question`/`warning`/`objection` — with no agent reply, or a human chat with no agent chat reply). `note` threads and tags are not actionable. `--timeout N` exits `2` with `{"kind":"idle"}` after N seconds. Run it as a background monitor; wire its completion to wake you, handle the item, then relaunch.

Event shapes (`text` is the full human text, untruncated; `anchor` is the full highlighted span — always present now that every annotation is anchored):
```json
{"kind":"annotation","id":"c-…","block":"goal","session":"proj/slug","text":"…","anchor":"…"}
{"kind":"chat","id":"…","block":null,"session":"proj/slug","text":"…"}
```

Reply to an annotation with `wb attach reply …` then `wb attach resolve …`. Reply to chat by writing an agent chat message file into the session's `chat/` dir (`{id, role:"agent", text, created}`); there is no `wb chat` command.

## Scope

`--session <project>/<slug>` → `WB_SESSION` env → per-agent owners map (`~/.wb/owners.json`, keyed by `PI_SESSION_ID` or the stable agent-harness pid). Concurrent agents each resolve to their own session — no clobber.
