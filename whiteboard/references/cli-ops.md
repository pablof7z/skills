# Whiteboard CLI operations (`wb`)

Brief how-to for the `wb` CLI — the portable way to drive a whiteboard session from any harness. Run `wb help` for the full reference. `wb` is on PATH (`~/.local/bin/wb`); if not, invoke `<skill-dir>/whiteboard/bin/wb` or `node <skill-dir>/whiteboard/cli/main.mjs …`.

A session lives at `~/whiteboard/<project>/<YYYY-MM-slug>/` (`<project>` = repo name, or cwd basename outside a repo). The document is the fold over `changes/<rev>.json`; you never hand-write it — every mutation is a staged `wb change` then `wb change send`.

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

## Mutate — one staging transaction

Open a change, stage ops, commit. One staging transaction at a time per session; a staging left open >5 min auto-sends when you next start a new one.

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
wb change rename <old> <new>                                          # rename (cascades attachments)
wb change remove <name> [name…]                                       # delete block(s)
wb change comment <block> --text T [--exact "quote"]                  # comment (auto selector with --exact)
wb change reply <thread-id> --text T                                  # reply in a thread
wb change resolve <thread-id> | wb change unresolve <thread-id>
wb change flag <block> <flag> [--clear] [--text reason]               # set/clear a label (needs-attention|decided|…)
wb change attention <block> --text T                                  # needs-attention label + amber card
wb change amend <thread-id> [--text T] [--exact "quote"]              # edit an attachment's body/anchor
wb change detach <thread-id>                                          # remove an attachment
```

Block names are lowercase slugs (`[a-z0-9-]`), unique. Comments and labels are one `attach` op discriminated by `kind`; ids and attachment state are derived for you — pass intent, not hand-rolled ids. Pass `--by <name>` (or set `AGENT_NAME`) to record the author.

A typical first seed:

```bash
wb new 2026-08-nmp-relay-identity-model
wb change "seed session"
wb change add goal --text "# Goal\nResolve how NMP relay identity is modeled."
wb change add constraints --text "# Constraints\n- Must survive key rotation."
wb change add open-questions --text "# Open Questions\n- Per-key or per-session?"
wb change send
```

## Notes

```bash
wb note "trail entry"             # append to notes.md (append-only; do not rewrite)
wb note --file f                  # append from a file
```

## Detect new comments/chat (portable)

```bash
wb listen [--session <project>/<slug>] [--timeout 0]
```

Baselines existing actionable items, then prints one JSONL event and exits `0` as soon as a NEW actionable item lands (an unresolved human comment with no agent reply, or a human chat with no agent chat reply). `--timeout N` exits `2` with `{"kind":"idle"}` after N seconds. Run it as a background monitor; wire its completion to wake you, handle the item, then relaunch.

Event shapes:
```json
{"kind":"comment","id":"c-…","block":"goal","session":"proj/slug","excerpt":"…"}
{"kind":"chat","id":"…","block":null,"session":"proj/slug","excerpt":"…"}
```

Reply to a comment through `wb change reply …` then `wb change resolve …` then `wb change send`. Reply to chat by writing an agent chat message file into the session's `chat/` dir (`{id, role:"agent", text, created}`); there is no `wb chat` command.

## Scope

`--session <project>/<slug>` → `WB_SESSION` env → per-agent owners map (`~/.wb/owners.json`, keyed by `PI_SESSION_ID` or the stable agent-harness pid). Concurrent agents each resolve to their own session — no clobber.