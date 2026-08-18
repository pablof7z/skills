---
name: whiteboard
description: "Exploration that always opens the research field beyond what the user asked. Proactively load for any non-trivial question, design, or system discussion — including factual and probing questions, architecture, systems, agents, workflows, products, protocols, skills, prompts, and implementation strategy. Research the literal question with verified facts, then proactively bring in adjacent and relevant context the user may not have thought to ask about, surfaced with context. Do not load for pure execution tasks (direct implementation or edit, code review, CI fix, release, direct GitHub/PR work), simple prompt rewrite, or one-shot prompt optimization."
---

# Whiteboard

## Operating Principle

Treat ambiguous design discussion as exploration first. This includes architecture, systems, agents, workflows, products, protocols, skills, prompts, implementation strategy, and other complex iterative design spaces. Name the session, keep notes automatically, help the user converge, and avoid implementation or canonical project artifacts until a direction has actually emerged.

If this skill was loaded for a pure execution task (direct implementation/edit request, code review, CI fix, release, direct GitHub/PR task), a simple prompt rewrite, one-shot prompt optimization, or a no-write environment, stop using it, do not create notes, and handle the task directly. Do use it for any non-trivial question or design discussion, including factual and probing questions — the skill's job is to research the literal question and then proactively open the field beyond it.

## Research And Epistemic Discipline

Whiteboard is exploration, not a license to speculate. The user is depending on you to know what is actually true before the design conversation can move. Research first; assert only what you have verified.

- Research before you assert. Before stating how something works, what exists, how many parts it has, or what a name refers to, inspect the source, docs, logs, runtime, or prior art that would settle it. If you cannot verify it right now, either go verify it or explicitly mark it as a guess. Never present a guess as fact.
- Separate fact from speculation in every response. Researched facts get stated plainly with their source; unverified claims get tagged as hypothesis, assumption, or "not yet checked". Never smooth a guess into confident prose. Never include an unverified claim without disclosing that it is unverified. If the claim is anywhere near material to the design being considered, do not leave it as a disclosed guess — proactively settle it with a source/runtime check before you rely on it. A guess that stays a guess near a decision is a latent defect.
- Use real names only. Never invent terminology, module names, file paths, function names, config keys, statuses, or counts. If you do not know the real name, say so and go find it. A made-up word is worse than "I don't know yet".
- No false analogies. Only use an analogy when it matches the actual mechanism. If the analogy would misrepresent how the thing really behaves, describe the mechanism directly instead.
- Answer the literal question first. When the user asks "how does A work?", answer how A works. Do not pivot to "we should redesign A" or "here is my recommended direction" until the factual question is answered and a decision is actually on the table.
- Verify once, not incrementally. Do not state an unverified claim, then half-correct it, then correct it again. If a claim you stated is challenged or you realize you never verified it, stop, recheck the source fully, and replace the claim with what you find. One clean correction beats a walk-back chain.
- "I don't know yet" is acceptable and expected. Saying you don't know, then researching with the source-inspection and adjacent-exploration tools available to you, is far better than a confident wrong answer.

## The One Rule: Mutate The Document Only Through `wb`

The session document is an **append-only change log** of named markdown blocks. You **never hand-write the document** — no `deliverable.md`, no hand-edited `document.json`, no hand-written comment/annotation JSON files. Every mutation goes through the `wb` CLI, which appends one atomic change file. This is what gives you stable comment anchors, semantic change tracking, and a live viewer. If you find yourself writing session files by hand, stop and use `wb`.

`wb` is installed on PATH (`~/.local/bin/wb`). If it is not on PATH in your environment, invoke the shim directly: `<skill-dir>/whiteboard/bin/wb` or `node <skill-dir>/whiteboard/cli/main.mjs …`.

## Start the Session

1. Assign a concise human-readable session name from the main object plus uncertainty, e.g. `NMP relay identity model exploration`.
2. Create or select a session with `wb new <slug>` (or `wb use <slug>` to reuse). Do not ask permission; do not interrupt the discussion.
3. Seed the document with the initial context, current working model, and highest-value open questions using `wb change` (see [Block Document Model](#block-document-model-wb-cli)).
4. Launch the live viewer so the human can read and annotate as it evolves (see [Live Viewer and Comments](#live-viewer-and-comments)).
5. Keep exploring until clarity emerges. Prefer source inspection, runtime evidence, focused questions, and tradeoff analysis over premature edits.

Treat tentative language like "I think X might work" as a hypothesis, not approval to implement.

## Session Workspace

Every whiteboard session lives in a shared, uncommitted directory outside any repo so the work-in-progress is visible to the human and can become a real deliverable:

```text
~/whiteboard/<project-slug>/YYYY-MM-<session-slug>/
├── manifest.json     # name, status, project, createdAt, owner
├── changes/          # append-only change log: 000001.json, 000002.json, … (the source of truth)
├── notes.md          # append-only trail (wb note)
└── chat/             # chat messages between human and agent (one JSON per message)
```

There is **no `deliverable.md`** and **no `comments/` directory** in a block-doc session. The document is the fold over `changes/`; comments/labels are attachments inside those change files (one unified `attach` op, discriminated by `kind`). The viewer reads the fold; the agent mutates it only via `wb`.

Resolve `<project-slug>` as the git repository name when inside a git work tree (`basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`), otherwise `basename "$PWD"` — never a full path. Resolve `<session-slug>` as lowercase hyphen-case of the session name with a `YYYY-MM` date prefix (month, not day, so a session spanning days stays in one folder).

If the environment cannot write the workspace, do not apply this skill.

## Block Document and Notes

The workspace holds the block document (the outward, live truth) and `notes.md` (the append-only trail), with different disciplines.

### Block document — the outward document

This is the artifact the human reads and annotates. It is a sequence of **named markdown blocks** you mutate through `wb change` (retroactively — rewrite and reorganize freely as the working model evolves; it is not append-only). Shape it to fit the session — plan, proposal, spec, design memo, or short brief — rather than forcing a fixed template. Whatever the shape, it must always include:

- **Requirements and constraints the user has stated.** Keep a dedicated, current block (e.g. `constraints`) listing every requirement and constraint the user made explicit. Add to it as new ones appear; never drop one without noting the user lifted it.
- The core question and current working model.
- The viable options and the emerging direction, with the decision frontier visible.
- Open questions and material risks.

Keep it skimmable. This is for the human to steer, not a dump of every subagent report. Summarize verified findings here; keep the raw trail in `notes.md`.

The viewer renders blocks as markdown with syntax highlighting, Mermaid diagrams, and footnotes, so prefer rich, precise content over prose: ```` ```rust ```` , ```` ```mermaid ```` , and `[^1]` footnotes all render. Start each block with an `# H1` title (the TOC lists headings, not block names).

### notes.md — the append-only log

Append, do not rewrite (`wb note "entry"`). Each entry is a timestamped bullet under a dated heading. Capture the trail: things the user made explicit, compact subagent findings with source, corrections (`Correction (HH:MM): …`), and adjacent-check results in `Finding / Implication / Confidence` form. Use the template in [references/note-schema-and-examples.md](references/note-schema-and-examples.md) for the first `notes.md`.

## Block Document Model (`wb` CLI)

The document is the fold over `changes/<rev>.json` (append-only; no `document.json` state file). Each `wb change send` appends one atomic change file with a human title and N ops. Any past version is the fold up to that rev. Comments and labels are one `attach` op discriminated by `kind` (`comment`, `needs-attention`, `decided`, …) — same anchor (block + optional selector), same lifecycle (active/resolved/removed); only the UI rendering differs per kind.

```bash
wb new <slug> [--from <md-file>]                # create a block-doc session
#  --from <md-file>: import an existing markdown doc VERBATIM, split into blocks
#  by H1/H2 heading (block name = heading slug; content before the first heading
#  -> an "intro" block; H3+ stay inside their parent block; code-fence safe).
#  Use this to scaffold a session from a doc, notes, or an ADR in one command.
wb use <slug>                                    # set current session (claims it for this agent)
wb read [--md|--json]                            # project the doc (default: tagged <name>…</name>)
wb note "trail entry"                            # append to notes.md
# Mutations: ONE interface — a staging transaction. `wb change "<title>"` opens it
# (only one at a time), `wb change <op> …` stages ops, `wb change send` commits them
# as one change (one rev, one title). Ops are intent — ids + attachment state are
# derived for you. A staging left open >5m auto-sends when you next start a new one.
wb change "<title>" [--summary S]                # START a staging transaction
wb change add <name> [--before X|--after X] (--file f|- | --text T)   # stage: add a block
wb change edit <block> (--file f|- | --text T | --diff f|-)           # stage: replace a block's md
wb change move <name> --before X|--after X       # stage: reorder
wb change rename <old> <new>                      # stage: rename (cascades attachments)
wb change remove <name> [name…]                  # stage: delete block(s) + their attachments
wb change comment <name> "text" [--exact "quote"] # stage: comment on a block (auto selector with --exact)
wb change reply <thread-id> "text"               # stage: reply in a thread
wb change resolve <thread-id>                    # stage: resolve a comment
wb change unresolve <thread-id>                  # stage: reopen a comment
wb change flag <name> <flag> [--clear]            # stage: set/clear a block label (needs-attention|decided|…)
wb change attention <name> "reason"               # stage: needs-attention label + amber card
wb change amend <thread-id> [--text T] [--exact "quote"]   # stage: edit an attachment's body or anchor
wb change detach <thread-id>                     # stage: remove an attachment
wb change status                                 # peek at staged ops
wb change send                                   # COMMIT staged ops as one change
wb change discard                                # abort the staging transaction
# Pass --by <your-name> (or set AGENT_NAME) so wb records you as the change author.
# Scope: --session <project>/<slug> → WB_SESSION env → per-agent owners map
# (~/.wb/owners.json, keyed by PI_SESSION_ID or the stable agent-harness pid).
# `wb new`/`wb use` record this agent's session in the map + stamp manifest.owner;
# later `wb` calls with no --session/WB_SESSION auto-resolve to THIS agent's session
# (concurrent agents each get their own — no clobber). The pi extension also pins
# WB_SESSION from manifest.owner (same identity).
```

Block names are unique lowercase slugs (`[a-z0-9-]`). `wb read` default output is the tagged projection so you see block boundaries:

```
<goal>
Design the block model and CLI.
</goal>

<tradeoffs>
We favor **named blocks** over flat markdown.
</tradeoffs>
```

A typical first-turn seed:

```bash
wb new 2026-08-nmp-relay-identity-model
wb change "seed session" 
wb change add goal --text "# Goal\nResolve how NMP relay identity is modeled."
wb change add constraints --text "# Constraints\n- Must survive key rotation."
wb change add open-questions --text "# Open Questions\n- Is the relay identity per-key or per-session?"
wb change send
```

## Exploration Loop

At each turn, mutate the block document via `wb change` (retroactively, as the live truth) and append to `notes.md` via `wb note` (as the trail) with any new model, evidence, objection, alternative, correction, or decision signal. Then respond in the main thread with the smallest useful accurate answer — researched facts for a factual question, or the decision-frontier synthesis below when a real decision is open.

### Always Explore Via Subagent

The main agent must always dispatch a subagent to research the user's question and to open the adjacent field. The main agent never performs source inspection, runtime checks, doc/issue/ADR reads, or adjacent exploration directly in the main thread. The main agent's role is to frame the question, dispatch one or more subagents with a bounded prompt, collect their results, update the note, and synthesize the response. This keeps the main thread honest: the synthesis is built from verified subagent findings, not from the main agent's priors. If no subagent tooling is available, say so explicitly, record the limitation, and do not substitute speculation.

### Answer The Literal Question, Then Open The Field

1. Answer what the user actually asked, with verified facts from source, docs, runtime, or prior art. Do not pivot to a redesign until the literal question is answered.
2. Proactively open the research field beyond the literal question: chase adjacent and relevant context the user may not have thought to ask about — prior art, ownership boundaries, hidden constraints, related code paths, failure modes, comparable systems. Surface each finding with context: what you checked, what you found, and why it bears on the user's question. Never drop a bare answer to a question the user did not ask.

Apply the decision-frontier framing only when there is an actual choice: competing directions, a real tradeoff, or a design the user is actively revising. For a purely factual question, the response is the verified answer plus proactively gathered adjacent context — not a recommended direction.

### Get Ahead Of The Next Move

When you have good certainty about where the user is likely to take the inquiry next, dispatch a subagent in that direction proactively, before the user asks. Use the same bounded-result format. Only do this when the next move is genuinely likely — do not speculatively fire subagents in every direction.

### Allocate Attention By Decision Relevance

Shape the response as a flexible attention gradient from material least likely to need user input toward material most likely to need it. Compress explicit agreement and settled direction aggressively; keep agent-selected defaults brief and distinguished from user-approved decisions; spend most of the explanation budget on the decision frontier. When several choices remain, end with a very short recap of what deserves the user's attention next. Markers like `✅`/`➡️`/`❓` are illustrative, not required.

Prefer these actions while status is `exploring`, all dispatched as subagent tasks: inspect source/docs/issues/ADRs/logs/runtime; compare alternatives against ownership boundaries, invariants, failure modes, integration risks; ask the user a focused question only when subagent findings cannot disambiguate; identify what evidence would change the recommendation. Do not edit implementation files merely because a plausible direction appears. Do not mark a session `converging` merely because you have a preferred answer.

## User Overrides

Obey direct user override commands immediately:

- `show notes`: `wb note` trail / show `notes.md`.
- `show document`: `wb read` (or `wb read --md`).
- `open viewer`: (re)launch the live viewer for the current session.
- `rename this session`: `wb change rename` the relevant blocks / update `manifest.json`.
- `stop tracking this`: mark the session `archived` in `manifest.json` and stop updating it.
- `forget that`: remove or revise the affected block via `wb change edit`/`remove`; log the removal via `wb note`.
- `that was not a decision`: move the item out of decisions into hypothesis/preference/rejected/open-question (edit the block via `wb change edit`, log via `wb note`).
- `mark this as decided`: mark the session `decided` in `manifest.json`, unless doing so would create a false record.
- `save this now`: `wb change send` any open staging.
- `do not run background agents here`: stop proactive adjacent exploration unless the user re-enables it.

When the user corrects an interpretation, update the block document retroactively via `wb change edit` so it reflects the corrected model, and append the correction to `notes.md` via `wb note`. Do not leave stale claims standing in the document.

## Session Boundaries

Pause, close, or split the session when the user changes topics, moves into execution, starts a materially different design thread, the current thread becomes stale, or the user explicitly stops tracking. Do not merge unrelated explorations just because they happened in the same conversation.

## Adjacent Exploration

Adjacent exploration is part of the subagent dispatch, not a separate fallback. When an adjacent question would materially derisk the discussion, dispatch a background subagent without asking first. Prefer one high-leverage adjacent exploration at a time. Good checks: prior art, existing code paths, ownership boundaries, hidden constraints, terminology pressure, comparable systems, standards behavior, failure modes, migration/testing/performance risks, security/privacy implications, reversibility, cost of being wrong, runtime evidence. Briefly tell the user what is being checked and why.

Background-agent prompt template:

```text
Context: I am helping the user explore `<session name>`. Not implementing yet. Current working model: `<short model>`. Open question: `<question>`. Explore `<specific adjacent area>` using available repo/source context. Do not produce a long report. Do not modify files. Return only this compact format:

Adjacent check: [question]
Finding: [1-3 sentence synthesis]
Implication: [how this affects the current design]
Confidence: [low/medium/high]
Suggested note update: [optional]
```

Summarize the result into `notes.md` (`wb note`). Bring only the relevant conclusion back to the user, framed with context. If the result contradicts the current model, surface that clearly and update the block document via `wb change`.

## Live Viewer and Comments

The whiteboard root (`~/whiteboard`) has a localhost web viewer (`whiteboard/viewer`) that serves an **explorer** plus a per-session view. The explorer lists every project's sessions with unread badges; each session view renders the block document and lets the human select any span and write a comment anchored to that block at the current version. The viewer watches the filesystem and re-renders live whenever a change file, note, or chat message lands.

### Launch the viewer

One viewer serves the whole root (not per session):

```bash
node "<skill-dir>/whiteboard/viewer/server.mjs" ~/whiteboard --open
```

`<skill-dir>` is the directory containing this `SKILL.md`. It binds to `127.0.0.1:4318` (override with `--port`). Tell the human the root URL (`http://127.0.0.1:4318/`) and the direct link to the current session: `http://127.0.0.1:4318/session/<project-slug>/<session-slug>` (a path, not a hash).

**If a viewer is already running on `127.0.0.1:4318`** (another agent or your harness may keep it running), reuse it — don't launch a second one. Some harnesses also wake you automatically when a comment or chat lands; if so, skip the watcher below and follow the reply steps when woken.

### Reply to comments and chat

Comments and chat come from the viewer, not the host conversation. Watch for them with `wait-for-comment.mjs` (below), or whatever wake mechanism your harness provides; when you receive a `[whiteboard] New comment on block "<block>" … (id <id>)` or `[whiteboard] New chat …` message, reply through `wb`, not by writing files by hand:

**Comment** (`[whiteboard] New comment on block "goal" … (id c-xxxxx)`):
```bash
wb change "reply to c-xxxxx" --session <project>/<slug>
wb change reply c-xxxxx "your answer"
wb change resolve c-xxxxx        # if fully settled
wb change send
```
If the answer changes the document, stage those `edit`/`add` ops in the same transaction before `wb change send`.

**Chat** (`[whiteboard] New chat …`): chat is a free-form conversation. There is no `wb chat` command — write an agent reply file directly into the session's `chat/` dir so it renders in the viewer's Chat tab:
```bash
sess=~/whiteboard/<project>/<slug>
ts=$(node -e 'console.log(Date.now())'); id=$(node -e 'console.log(Math.random().toString(16).slice(2,8))')
cat > "$sess/chat/$ts-$id.json" <<EOF
{ "id": "urn:uuid:agent-$id", "role": "agent", "text": "your reply", "created": "$(node -e 'console.log(new Date().toISOString())')" }
EOF
```
Update the block document via `wb change` if the message changes the model.

Do not answer a comment or chat only in the host conversation — the human is reviewing in the viewer, so the reply must land in the change log (comments) or `chat/` (chat) to appear there. Use the host conversation to surface that you replied and to discuss anything that changes the direction.

### Watch for new items (portable)

If your harness doesn't already wake you on viewer activity, run the inbox watcher as a background monitor for the current session:

```bash
node "<skill-dir>/whiteboard/viewer/wait-for-comment.mjs" "<session-dir>"
```

It baselines existing items, then exits (printing `comment:<id>` or `chat:<id>`) as soon as a new actionable item lands — a top-level human comment with no agent reply, or a human chat with no agent chat reply after it. Wire its completion to wake you, handle by kind (above), then relaunch it for the next item.

## Marking something for the human's attention

When a block needs the human to look at it (an open question, a risk they must sign off on, a choice that is theirs), mark it with a needs-attention label via `wb` — the viewer renders it as an amber card + flag:

```bash
wb change "flag <block> for attention" --session <project>/<slug>
wb change attention <block> "Why this needs your attention (one or two sentences)."
wb change send
```

Use it only for things that genuinely need the human — do not litter the document. Dismiss it with `wb change resolve <thread-id>` once reviewed.

## Convergence and Promotion

Move status from `exploring` to `converging` when one direction is becoming stronger but important assumptions or risks remain open. Move to `decided` only on a clear decision signal (the user explicitly choosing, asking to write it up, asking to implement, or repeatedly treating one direction as agreed after alternatives were considered).

Promote to a durable project artifact only after `decided`: shape the final ADR, issue, planning note, spec, or roadmap entry from the block document (`wb read --md` to export), carrying over the requirements/constraints block verbatim. Prefer updating an existing artifact over creating a new one. Keep `notes.md` as the trail. Do not open issues, create PRs, write ADRs, modify canonical docs, or change implementation files before convergence. After promotion, update `manifest.json` status to `decided` (then `archived`) and record the follow-up artifact path in the document and `notes.md`.

## Reference

Read [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating the first `notes.md`. The legacy per-file W3C annotation path (`references/annotations.md`) is superseded by the `wb` attachment model; read it only if you are migrating an old `deliverable.md` session.