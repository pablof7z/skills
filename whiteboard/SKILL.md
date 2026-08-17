---
name: whiteboard
description: "Process for iterative exploration with the user. Proactively load this skill when a clear task becomes open-ended: direction is fuzzy, options keep shifting, or probes point into unknown work."
---

# Whiteboard

## Operating Principle

Treat ambiguous design discussion as exploration first. This includes architecture, systems, agents, workflows, products, protocols, skills, prompts, implementation strategy, and other complex iterative design spaces. Name the session, keep notes automatically, help the user converge, and avoid implementation or canonical project artifacts until a direction has actually emerged.

If this skill was loaded for a simple one-off question, simple prompt rewrite, one-shot prompt optimization, direct implementation/edit request, code review, CI fix, release, direct GitHub/PR task, or a no-write environment, stop using it, do not create notes, and answer the user's direct request normally. Do use it for complex prompt, skill, agent, workflow, product, protocol, or system-design exploration when the user is iterating across alternatives and uncertainty.

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
└── comments/         # W3C Web Annotation JSON files (one per comment or reply)
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

### notes.md — the append-only log

Append, do not rewrite. Each entry is a timestamped bullet under a dated heading. Capture the trail that produced the deliverable:

- Things the user made explicit (requirements, preferences, constraints, decisions).
- Useful research subagents surfaced (compact findings with source, not full reports).
- Corrections the user made, logged as they happen (`Correction (HH:MM): …`).
- Adjacent-check results in the compact `Finding / Implication / Confidence` form.

Also track the structured exploration state here (status, core question, working model, observations, assumptions, hypotheses, constraints, preferences, risks, open questions, alternatives, rejected options, decisions). Update the state by editing the structured block at the top of `notes.md`; append new evidence and corrections below it. The deliverable is the retroactively-updated truth; the log is the append-only trail that explains how it got there.

Use the full template in [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating the first `notes.md`. Keep observations, assumptions, hypotheses, constraints, preferences, decisions, rejected options, risks, and open questions distinct. Do not promote a hypothesis, preference, or repeated suggestion into a decision unless the user explicitly agrees or the conversation clearly converges.

## Exploration Loop

At each turn, update `deliverable.md` (retroactively, as the live truth) and append to `notes.md` (as the trail) with any new model, evidence, objection, alternative, correction, or decision signal. Then respond in the main thread with the smallest useful synthesis.

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

Prefer these actions while the status is `exploring`:

- inspect existing source, docs, issues, plans, ADRs, logs, or runtime paths that bear on the question
- compare alternatives against ownership boundaries, invariants, failure modes, and integration risks
- ask a focused question only when local context cannot disambiguate the direction safely
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

When an adjacent question would materially derisk the discussion, dispatch a background agent without asking the user first. Use available multi-agent or subagent tooling when present. If no background-agent tool is available, do a short read-only exploration in the main thread and record that limitation in the notes.

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

Summarize the result into `notes.md`. Bring only the relevant conclusion back to the user. If the result contradicts the current model, surface that clearly and update `deliverable.md`. Do not paste large background reports into the main conversation.

## Live Viewer and Comments

The workspace has a localhost web viewer (`whiteboard/viewer`) that renders `deliverable.md` and lets the human select any span and write a comment anchored to that text **at the current document version**. Comments are W3C Web Annotation JSON files in `comments/`. The viewer watches the filesystem and re-renders live whenever the deliverable, notes, or comments change.

### Launch the viewer

When the session starts, launch the viewer as a background monitor and open it in the browser:

```bash
node "<skill-dir>/whiteboard/viewer/server.mjs" "<session-dir>" --open
```

`<skill-dir>` is the directory containing this `SKILL.md`. The server binds to `127.0.0.1:4318` (override with `--port`). Keep it running for the life of the session. Tell the human the URL.

The viewer auto-snapshots `deliverable.md` into `versions/<sha12>.md` on every change, so a comment's anchored version can always be recovered even after later edits.

### Watch for new comments and reply

The human will leave comments in the viewer, not in chat. To respond, run the comment watcher as a background monitor:

```bash
node "<skill-dir>/whiteboard/viewer/wait-for-comment.mjs" "<session-dir>"
```

It baselines existing comments, then exits (printing the new annotation's `urn:uuid:…` id) as soon as a new top-level human comment without an agent reply appears. Wire its completion to wake you (the monitor's `onDone` prompt), then:

1. Read the new comment from its file in `comments/`.
2. Answer it. Often the answer also changes `deliverable.md` or adds a `notes.md` entry — make those edits too.
3. Write a **reply annotation** file into `comments/` with `motivation: "replying"`, `creator.name: "agent"`, and `target: { id: <parent urn:uuid>, type: "Annotation" }` so the reply threads under the question in the viewer. The W3C Web Annotation shape is specified in [references/annotations.md](references/annotations.md).
4. Relaunch the watcher for the next comment.

The viewer's filesystem watch picks up the reply file and renders it live; no restart needed.

Do not answer a comment only in chat — the human is reviewing in the viewer, so the reply must live in `comments/` to appear there. Use chat to surface that you replied and to discuss anything the comment surfaced that changes the direction.

## Convergence and Promotion

Move status from `exploring` to `converging` when one direction is becoming stronger but important assumptions or risks remain open. Do not mark a session `converging` only because the agent has a preferred answer.

Move status to `decided` only when there is a clear decision signal, such as the user explicitly choosing a direction, asking to write it up, asking to implement, or repeatedly treating one direction as the agreed model after alternatives have been considered.

Promote the session to a durable project artifact only after the session is `decided`. The deliverable already is a draft of that artifact: shape the final ADR, issue, planning note, spec, or roadmap entry from `deliverable.md`, carrying over the requirements/constraints section verbatim. Prefer updating an existing artifact over creating a new one. Keep `notes.md` as the trail that produced it.

Do not open GitHub issues, create PRs, write ADRs, modify canonical docs, or change implementation files before convergence. Move to implementation only when the user directly asks for it or the agreed direction is clear and the next requested action requires implementation.

After promotion, update `manifest.json` status to `decided` (then `archived` when it no longer needs active updates) and record the follow-up artifact path or URL in both `deliverable.md` and `notes.md`.

## Reference

Read [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating the first `notes.md`, and [references/annotations.md](references/annotations.md) when writing or replying to comments. Read either when checking trigger edge cases or promoting a decided exploration into a durable artifact.
