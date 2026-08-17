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

## Start the Session

1. Assign a concise human-readable session name using the main object plus uncertainty, such as `NMP relay identity model exploration`, `Trellis phase-boundary design exploration`, or `Podcast queue ownership exploration`.
2. Create or select a session workspace (see [Session Workspace](#session-workspace)) without asking permission. Do not interrupt the discussion with a permission question.
3. Record the initial context, the current working model, and the highest-value open questions in the workspace before or during the first substantive response.
4. Launch the live viewer so the human can read and annotate the deliverable as it evolves (see [Live Viewer and Comments](#live-viewer-and-comments)).
5. Keep exploring until clarity emerges. Prefer source inspection, runtime evidence, focused questions, and tradeoff analysis over premature edits.

Treat tentative language like "I think X might work" as a hypothesis, not approval to implement.

## Session Workspace

Every whiteboard session lives in a shared, uncommitted directory outside any repo so the work-in-progress is visible to the human and can become a real deliverable:

```text
~/whiteboard/<project-slug>/YYYY-MM-<session-slug>/
├── manifest.json     # name, status, project, createdAt
├── deliverable.md    # outward-facing doc the agent constantly updates; becomes the deliverable
├── notes.md          # append-only log: user explicit statements, subagent findings, corrections
├── versions/         # auto-snapshots of deliverable.md per content version (viewer-managed)
├── comments/         # W3C Web Annotation JSON files (one per comment or reply)
└── chat/             # chat messages between human and agent (one JSON per message)
```

Resolve `<project-slug>` as:

1. The git repository name when inside a git work tree. Use the main repository directory name, not the worktree directory name:

```bash
basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
```

2. Otherwise the basename of the current working directory only (`basename "$PWD"`), never a full path.

Resolve `<session-slug>` as a lowercase hyphen-case slug of the session name, e.g. `nmp-relay-identity-model`. Use `YYYY-MM` (year and month) as the date prefix, not the full day, so a session that spans days stays in one folder.

Create the directory and `manifest.json` on first write. If an existing workspace clearly matches the same session, reuse it instead of creating another. Do not write session files into the project tree.

The workspace is the single source of truth for the session. The viewer reads it; the agent reads and writes it. Keep everything the human needs to review inside this directory.

If the environment cannot write the workspace, do not apply this skill.

## Deliverable and Notes

The workspace holds two documents with different disciplines.

### deliverable.md — the outward document

This is the artifact the human reads and annotates. It is the live truth of the session and becomes the deliverable when the session converges. Rewrite and reorganize it freely as the working model evolves; it is not append-only.

Shape it to fit the session — a plan, proposal, spec, design memo, or short brief — rather than forcing a fixed template. Whatever the shape, it must always include:

- **Requirements and constraints the user has stated.** Keep a dedicated, current section listing every requirement and constraint the user made explicit. Add to it as new ones appear; never drop one without noting the user lifted it.
- The core question and current working model.
- The viable options and the emerging direction, with the decision frontier visible.
- Open questions and material risks.

Keep it skimmable. This is for the human to steer, not a dump of every subagent report. Summarize verified findings here; keep the raw trail in `notes.md`.

The viewer renders the deliverable as markdown with syntax highlighting and diagrams, so prefer rich, precise content over prose:
- **Fenced code blocks with a language** get syntax highlighting — use ```` ```rust ```` , ```` ```ts ```` , ```` ```bash ```` , etc. (common language tags).
- **Mermaid blocks** (```` ```mermaid ```` ) render as diagrams in the viewer — use them for architecture, state, sequence, and flow diagrams instead of describing shapes in prose.

### notes.md — the append-only log

Append, do not rewrite. Each entry is a timestamped bullet under a dated heading. Capture the trail that produced the deliverable:

- Things the user made explicit (requirements, preferences, constraints, decisions).
- Useful research subagents surfaced (compact findings with source, not full reports).
- Corrections the user made, logged as they happen (`Correction (HH:MM): …`).
- Adjacent-check results in the compact `Finding / Implication / Confidence` form.

Also track the structured exploration state here (status, core question, working model, observations, assumptions, hypotheses, constraints, preferences, risks, open questions, alternatives, rejected options, decisions). Update the state by editing the structured block at the top of `notes.md`; append new evidence and corrections below it. The deliverable is the retroactively-updated truth; the log is the append-only trail that explains how it got there.

Use the full template in [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating the first `notes.md`. Keep observations, assumptions, hypotheses, constraints, preferences, decisions, rejected options, risks, and open questions distinct. Do not promote a hypothesis, preference, or repeated suggestion into a decision unless the user explicitly agrees or the conversation clearly converges.

## Exploration Loop

At each turn, update `deliverable.md` (retroactively, as the live truth) and append to `notes.md` (as the trail) with any new model, evidence, objection, alternative, correction, or decision signal. Then respond in the main thread with the smallest useful accurate answer — researched facts for a factual question, or the decision-frontier synthesis below when a real decision is open.

### Always Explore Via Subagent

The main agent must always dispatch a subagent to research the user's question and to open the adjacent field. The main agent never performs source inspection, runtime checks, doc/issue/ADR reads, or adjacent exploration directly in the main thread. The main agent's role is to frame the question, dispatch one or more subagents with a bounded prompt, collect their results, update the note, and synthesize the response.

This keeps the main thread honest: the synthesis is built from verified subagent findings, not from the main agent's priors, and it prevents the speculate-then-walk-back pattern inline. The main agent may reason about and combine subagent results, but the underlying facts must come from a dispatched exploration, not from memory or inference.

If no subagent or multi-agent tooling is available in this environment, say so explicitly to the user, record the limitation in the note, and do not substitute speculation. Either obtain the tooling or stop and ask the user how to proceed — never guess in place of a subagent check.

### Answer The Literal Question, Then Open The Field

The skill always does two things, in order:

1. Answer what the user actually asked, with verified facts from source, docs, runtime, or prior art. Do not pivot to a redesign or recommendation until the literal question is answered.
2. Proactively open the research field beyond the literal question: chase down adjacent and relevant context the user may not have thought to ask about — prior art, ownership boundaries, hidden constraints, related code paths, failure modes, comparable systems, terminology pressure. Surface each finding with context: what you checked, what you found, and why it bears on the user's question. Never drop a bare answer to a question the user did not ask.

Apply the decision-frontier framing below only when there is an actual choice for the user to make: competing directions, a real tradeoff, or a design the user is actively revising. For a purely factual question, the response is the verified answer plus the proactively gathered adjacent context — not a recommended direction or a synthesis of options the user never raised.

### Get Ahead Of The Next Move

When you have good certainty about where the user is likely to take the inquiry or design next, dispatch a subagent in that direction proactively, before the user asks. Use the same bounded-result format. Only do this when the next move is genuinely likely — do not speculatively fire subagents in every possible direction. The goal is to have verified findings ready, with context, so the next turn is already derisked instead of starting cold.

Surface a proactively-gathered-ahead finding the same way as any adjacent finding: what you checked, what you found, why you expected it to be the next move, and how it bears on the current question. If the user then goes a different direction, the finding is still useful context or a noted rejected option — never wasted.

### Allocate Attention By Decision Relevance

Shape the response as a flexible attention gradient: move loosely from material least likely to need user input toward material most likely to need it. Do not turn this into mandatory sections, symbols, or a fixed template.

- Compress explicit agreement and settled direction aggressively. A label or short bullet is usually enough; do not re-argue what the user already chose.
- Keep strong agent-selected defaults brief and distinguish them from user-approved decisions as assumptions, proposed defaults, or emerging direction.
- State supporting evidence compactly. Explain contrary evidence in proportion to how much it threatens the direction: mention mild caveats briefly or omit them, but give potential showstoppers enough context to evaluate.
- Spend most of the explanation budget on the decision frontier. When the user needs to make a call, make the context vertically skimmable: what the choice controls, the viable options, the recommended default and why, and the meaningful consequence of each option.
- When several choices remain, end with a very short recap of what deserves the user's attention next.

Markers such as `✅` for agreement, `➡️` for a proposed default, or `❓` for a user decision can improve scanability, but they are illustrative rather than required. Preserve natural conversation, omit empty layers, and compress low-attention material before shortening decision context.

Optimize for understanding before action. Answer probing questions directly, but keep the main thread oriented around the current decision frontier:

- what is known
- what is uncertain
- which choice would change the design
- what evidence would settle the uncertainty
- what direction appears to be emerging
- what the next useful question or check is

Prefer these actions while the status is `exploring`, all dispatched as subagent tasks rather than done inline:

- inspect existing source, docs, issues, plans, ADRs, logs, or runtime paths that bear on the question
- compare alternatives against ownership boundaries, invariants, failure modes, and integration risks
- ask the user a focused question only when subagent findings cannot disambiguate the direction safely
- identify what evidence would change the recommendation

Do not edit implementation files merely because a plausible direction appears.

Do not mark a session `converging` merely because you have a preferred answer. Keep it `exploring` until the user has reacted to the direction or independent evidence has narrowed the realistic options.

## User Overrides

Obey direct user override commands immediately:

- `show notes`: summarize or show the `notes.md` path and contents.
- `show deliverable`: summarize or show the `deliverable.md` path and contents.
- `open viewer`: (re)launch the live viewer for the current workspace and open it in the browser.
- `rename this session`: rename the session and update `manifest.json` (and the workspace dir name if practical).
- `stop tracking this`: mark the session `archived` in `manifest.json` and stop updating it.
- `forget that`: remove or revise the affected content. Revise `deliverable.md` retroactively; log the removal in `notes.md`.
- `that was not a decision`: move the item out of decisions and into hypothesis, preference, rejected option, or open question in `notes.md`, and reflect the change in `deliverable.md`.
- `mark this as decided`: mark the session `decided` in `manifest.json`, unless doing so would create a false record; if unclear, record the user's command as the decision signal.
- `split this into a new session`: create a separate workspace and move the relevant context.
- `merge this with the previous session`: merge only related explorations and preserve distinct decisions/risks.
- `save this now`: flush the current `deliverable.md` and `notes.md` without bypassing the convergence gate for canonical project artifacts.
- `do not run background agents here`: stop proactive adjacent exploration for this session unless the user later re-enables it.

When the user corrects an interpretation, update `deliverable.md` retroactively so it reflects the corrected model, and append the correction to `notes.md` as a log entry. Do not leave stale claims standing in the deliverable.

## Session Boundaries

Pause, close, or split the session when the user changes topics, moves into execution, starts a materially different design thread, the current thread becomes stale, or the user explicitly stops tracking.

Do not merge unrelated explorations just because they happened in the same conversation. If implementation starts, carry the notes forward as context, but stop treating the execution work as open-ended exploration unless new unresolved design questions appear.

## Adjacent Exploration

Adjacent exploration is part of the subagent dispatch above, not a separate fallback. When an adjacent question would materially derisk the discussion, dispatch a background subagent without asking the user first, using the template below. The main agent does not perform adjacent exploration inline.

Prefer one high-leverage adjacent exploration at a time. Do not launch background work for curiosity, obvious facts, or questions unlikely to materially affect the design.

Good adjacent checks include prior art, existing code paths, ownership boundaries, hidden constraints, terminology or naming pressure, comparable systems, standards/protocol behavior, failure modes, migration/testing/performance risks, security or privacy implications, operational complexity, reversibility, cost of being wrong, sibling projects, and runtime evidence that could confirm or falsify the working model.

Briefly tell the user what is being checked and why, for example:

```text
I am checking the ownership boundary and the existing runtime path to see whether that lines up with the design we are sketching.
```

Use this background-agent prompt template:

```text
Context: I am helping the user explore `<session name>`. We are not implementing yet. Current working model: `<short model>`. Open question: `<question>`. Explore `<specific adjacent area>` using available repo/source context. Do not produce a long report. Do not modify files. Return only this compact format:

Adjacent check: [question]
Finding: [1-3 sentence synthesis]
Implication: [how this affects the current design]
Confidence: [low/medium/high]
Suggested note update: [optional]
```

Summarize the result into `notes.md`. Bring only the relevant conclusion back to the user, framed with context: what was checked, what was found, and why it bears on the user's question or the current design. Never drop a bare answer to a question the user did not ask — if the finding is worth surfacing, say what it is and why it matters. If the result contradicts the current model, surface that clearly and update `deliverable.md`. Do not paste large background reports into the main conversation.

## Live Viewer and Comments

The whiteboard root (`~/whiteboard`) has a localhost web viewer (`whiteboard/viewer`) that serves an **explorer** plus a per-session view. The explorer lists every project's sessions with **unread badges** (agent replies the human hasn't opened yet); each session view renders `deliverable.md` and lets the human select any span and write a comment anchored to that text **at the current document version**. Comments are W3C Web Annotation JSON files in `comments/`. The viewer watches the filesystem and re-renders live whenever any deliverable, notes, or comments change.

### Launch the viewer

Launch one viewer for the whole root (not per session) as a background monitor and open it in the browser:

```bash
node "<skill-dir>/whiteboard/viewer/server.mjs" ~/whiteboard --open
```

`<skill-dir>` is the directory containing this `SKILL.md`. The server binds to `127.0.0.1:4318` (override with `--port`) and serves every session under the root. Keep it running across sessions; tell the human the root URL (`http://127.0.0.1:4318/`) and the direct link to the current session: `http://127.0.0.1:4318/session/<project-slug>/<session-slug>`.

The viewer auto-snapshots `deliverable.md` into `versions/<sha12>.md` on every change, so a comment's anchored version can always be recovered even after later edits. Opening a session marks it seen and clears its unread badge.

### Watch for new comments and chat, and reply

The human will leave comments in the viewer and may also send chat messages from the viewer's Chat tab — not in the host conversation. To respond, run the inbox watcher for the current session as a background monitor:

```bash
node "<skill-dir>/whiteboard/viewer/wait-for-comment.mjs" "<session-dir>"
```

It baselines existing items, then exits (printing a token) as soon as there is a new actionable item: a top-level human comment with no agent reply, or a human chat message with no agent chat reply after it. The token is `comment:<urn:uuid>` or `chat:<urn:uuid>`. Wire its completion to wake you (the monitor's `onDone` prompt), then handle by kind:

**`comment:<id>`** — an anchored question on the deliverable:
1. Read the new comment from its file in `comments/`.
2. Answer it. Often the answer also changes `deliverable.md` or adds a `notes.md` entry — make those edits too.
3. Write a **reply annotation** file into `comments/` with `motivation: "replying"`, `creator.name: "agent"`, and `target: { id: <parent urn:uuid>, type: "Annotation" }` so the reply threads under the question in the viewer. The W3C Web Annotation shape is specified in [references/annotations.md](references/annotations.md).

**`chat:<id>`** — a free-form message from the webapp chat tab:
1. Read the message from its file in `chat/` (JSON: `{ id, role, text, created }`).
2. Respond appropriately — this is a normal turn of conversation about the session. Update `deliverable.md` and/or `notes.md` if the message changes the model, and answer any question it raises.
3. Write an **agent chat reply** file into `chat/` with `role: "agent"`, `creator`-free shape `{ id: "urn:uuid:…", role: "agent", text, created }` so it renders in the viewer's Chat tab. (The viewer reads any `.json` in `chat/` with those fields.)

In both cases, relaunch the watcher for the next item. The viewer's filesystem watch picks up the new file and renders it live; no restart needed.

Do not answer a comment or chat only in the host conversation — the human is reviewing in the viewer, so the reply must live in `comments/` or `chat/` to appear there. Use the host conversation to surface that you replied and to discuss anything that changes the direction.

## Convergence and Promotion

Move status from `exploring` to `converging` when one direction is becoming stronger but important assumptions or risks remain open. Do not mark a session `converging` only because the agent has a preferred answer.

Move status to `decided` only when there is a clear decision signal, such as the user explicitly choosing a direction, asking to write it up, asking to implement, or repeatedly treating one direction as the agreed model after alternatives have been considered.

Promote the session to a durable project artifact only after the session is `decided`. The deliverable already is a draft of that artifact: shape the final ADR, issue, planning note, spec, or roadmap entry from `deliverable.md`, carrying over the requirements/constraints section verbatim. Prefer updating an existing artifact over creating a new one. Keep `notes.md` as the trail that produced it.

Do not open GitHub issues, create PRs, write ADRs, modify canonical docs, or change implementation files before convergence. Move to implementation only when the user directly asks for it or the agreed direction is clear and the next requested action requires implementation.

After promotion, update `manifest.json` status to `decided` (then `archived` when it no longer needs active updates) and record the follow-up artifact path or URL in both `deliverable.md` and `notes.md`.

## Reference

Read [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating the first `notes.md`, and [references/annotations.md](references/annotations.md) when writing or replying to comments. Read either when checking trigger edge cases or promoting a decided exploration into a durable artifact.