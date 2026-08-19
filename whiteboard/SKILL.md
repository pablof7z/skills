---
name: whiteboard
description: "Exploration that always opens the research field beyond what the user asked. Proactively load for any non-trivial question, design, or system discussion — including factual and probing questions, architecture, systems, agents, workflows, products, protocols, skills, prompts, and implementation strategy. Research the literal question with verified facts, then proactively bring in adjacent and relevant context the user may not have thought to ask about, surfaced with context. Do not load for pure execution tasks (direct implementation or edit, code review, CI fix, release, direct GitHub/PR work), simple prompt rewrite, or one-shot prompt optimization."
---

# Whiteboard

## Operating Principle

Treat ambiguous design discussion as exploration first — architecture, systems, agents, workflows, products, protocols, skills, prompts, implementation strategy, and other complex iterative design spaces. Name the session, keep notes automatically, help the user converge, and avoid implementation or canonical project artifacts until a direction has actually emerged. Mindset: the working model is revisable; "I think X might work" is a hypothesis, not approval to build.

If this skill was loaded for a pure execution task (direct implementation/edit, code review, CI fix, release, direct GitHub/PR task), a simple prompt rewrite, one-shot prompt optimization, or a no-write environment, stop using it, do not create notes, and handle the task directly.

## Feedback

User feedback often points at a symptom, not the fix. Don't apply it as a literal local patch. Step back, hold the whole picture, and address the misframing the feedback reveals — a string of edits that each answer the literal comment but miss the underlying point is failure.

## Research And Epistemic Discipline

Whiteboard is exploration, not a license to speculate. The user is depending on you to know what is actually true before the design conversation can move. Research first; assert only what you have verified.

- Research before you assert. Before stating how something works, what exists, how many parts it has, or what a name refers to, inspect the source, docs, logs, runtime, or prior art that would settle it. If you cannot verify it right now, either go verify it or explicitly mark it as a guess. Never present a guess as fact.
- Separate fact from speculation in every response. Researched facts get stated plainly with their source; unverified claims get tagged hypothesis, assumption, or "not yet checked". Never smooth a guess into confident prose. If the claim is anywhere near material to the design, do not leave it as a disclosed guess — settle it with a source/runtime check before you rely on it. A guess that stays a guess near a decision is a latent defect.
- Use real names only. Never invent terminology, module names, file paths, function names, config keys, statuses, or counts. If you do not know the real name, say so and go find it. A made-up word is worse than "I don't know yet".
- No false analogies. Only use an analogy when it matches the actual mechanism; otherwise describe the mechanism directly.
- Answer the literal question first. Do not pivot to a redesign until the factual question is answered and a decision is actually on the table.
- Verify once, not incrementally. If a claim you stated is challenged or you realize you never verified it, stop, recheck the source fully, and replace it. One clean correction beats a walk-back chain.
- "I don't know yet" is acceptable and expected.

## The One Rule

Never hand-write the session document — mutate it only through `wb` (or, under pi, the `whiteboard` tool). It appends one atomic change file; that's what gives you stable comment anchors, semantic change tracking, and a live viewer.

## How To Use Whiteboard

The skill body is process. Learn the tool from the reference files, then use it:

- **Always load [references/cli-ops.md](references/cli-ops.md)** — the `wb` CLI: sessions, read, the staging transaction, ops, notes, and `wb listen` for detecting new comments/chat.
- **If you are in a pi harness with the pi-whiteboard extension**, also read [references/pi.md](references/pi.md) — the `whiteboard` tool, attributed `[whiteboard]` wake messages, the auto-managed viewer, and `/wb`. Under pi you do not run `wb listen` or launch the viewer yourself.
- For the `notes.md` shape and promotion checklist, see [references/note-schema-and-examples.md](references/note-schema-and-examples.md).

## Start the Session

1. Assign a concise human-readable session name from the main object plus uncertainty, e.g. `NMP relay identity model exploration`.
2. Create or select a session with `wb new <slug>` (or `wb use <slug>` to reuse). Do not ask permission; do not interrupt the discussion.
3. Seed the document with the initial context, current working model, and highest-value open questions (a `goal` block, a `constraints` block, an `open-questions` block).
4. Keep exploring until clarity emerges. Prefer source inspection, runtime evidence, focused questions, and tradeoff analysis over premature edits.

If the environment cannot write to `~/whiteboard/`, do not apply this skill.

## Block Document and Notes

The workspace holds the block document (the outward, live truth) and `notes.md` (the append-only trail), with different disciplines.

### Block document — the outward document

This is the artifact the human reads and annotates. It is a sequence of **named markdown blocks** you mutate retroactively (rewrite and reorganize freely as the working model evolves; it is not append-only). Shape it to fit the session — plan, proposal, spec, design memo, or short brief — rather than forcing a fixed template. Whatever the shape, it must always include:

- **Requirements and constraints the user has stated**, in a dedicated current block (e.g. `constraints`). Add to it as new ones appear; never drop one without noting the user lifted it.
- The core question and current working model.
- The viable options and the emerging direction, with the decision frontier visible.
- Open questions and material risks.

Keep it skimmable — for the human to steer, not a dump of every subagent report. Summarize verified findings here; keep the raw trail in `notes.md`. Start each block with an `# H1` title (the viewer's TOC lists headings, not block names). The viewer renders markdown with syntax highlighting, Mermaid, and footnotes.

When a block needs the human's attention (an open question, a risk to sign off on, a choice that's theirs), mark it with a needs-attention label — the viewer renders it as an amber card. Use it only for things that genuinely need the human; dismiss it once reviewed.

### notes.md — the append-only log

Append, do not rewrite (`wb note "entry"`). Capture the trail: things the user made explicit, compact subagent findings with source, corrections (`Correction (HH:MM): …`), and adjacent-check results in `Finding / Implication / Confidence` form. Use the template in [references/note-schema-and-examples.md](references/note-schema-and-examples.md) for the first `notes.md`.

## Exploration Loop

At each turn, mutate the block document (retroactively, as the live truth) and append to `notes.md` (as the trail) with any new model, evidence, objection, alternative, correction, or decision signal. Then respond in the main thread with the smallest useful accurate answer — researched facts for a factual question, or the decision-frontier synthesis when a real decision is open.

### Always Explore Via Subagent

The main agent must always dispatch a subagent to research the user's question and to open the adjacent field. The main agent never performs source inspection, runtime checks, doc/issue/ADR reads, or adjacent exploration directly in the main thread. Its role: frame the question, dispatch one or more subagents with a bounded prompt, collect their results, update the note, and synthesize. This keeps the main thread honest — synthesis from verified subagent findings, not from priors. If no subagent tooling is available, say so explicitly, record the limitation, and do not substitute speculation.

### Answer The Literal Question, Then Open The Field

1. Answer what the user actually asked, with verified facts from source, docs, runtime, or prior art. Do not pivot to a redesign until the literal question is answered.
2. Proactively open the field beyond it: adjacent and relevant context the user may not have thought to ask about — prior art, ownership boundaries, hidden constraints, related code paths, failure modes, comparable systems. Surface each with context: what you checked, what you found, why it bears on the question. Never drop a bare answer to a question the user did not ask.

Apply the decision-frontier framing only when there is an actual choice — competing directions, a real tradeoff, or a design the user is actively revising. For a purely factual question, the response is the verified answer plus proactively gathered adjacent context, not a recommended direction.

### Get Ahead Of The Next Move

When you have good certainty about where the user is likely to take the inquiry next, dispatch a subagent in that direction proactively, before the user asks. Only when the next move is genuinely likely — do not speculatively fire subagents in every direction.

### Allocate Attention By Decision Relevance

Shape the response as a flexible attention gradient from material least likely to need user input toward material most likely to need it. Compress explicit agreement and settled direction; keep agent-selected defaults brief and distinct from user-approved decisions; spend the budget on the decision frontier. When several choices remain, end with a short recap of what deserves attention next.

While status is `exploring`, dispatch as subagent tasks: inspect source/docs/issues/ADRs/logs/runtime; compare alternatives against ownership boundaries, invariants, failure modes, integration risks; ask the user a focused question only when subagent findings cannot disambiguate; identify what evidence would change the recommendation. Do not edit implementation files because a plausible direction appeared. Do not mark a session `converging` because you prefer an answer.

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

Summarize the result into `notes.md`. Bring only the relevant conclusion back to the user, framed with context. If the result contradicts the current model, surface that clearly and update the block document.

## User Overrides

Obey direct user override commands immediately:

- `show notes` / `show document`: show the `notes.md` trail / the block document.
- `open viewer`: (re)launch the live viewer for the current session (under pi it's auto-managed).
- `rename this session`: rename the relevant blocks / update `manifest.json`.
- `stop tracking this`: mark the session `archived` in `manifest.json` and stop updating it.
- `forget that`: remove or revise the affected block; log the removal via `wb note`.
- `that was not a decision`: move the item out of decisions into hypothesis/preference/rejected/open-question; log it.
- `mark this as decided`: mark the session `decided` in `manifest.json`, unless doing so would create a false record.
- `save this now`: commit any open staging.
- `do not run background agents here`: stop proactive adjacent exploration unless the user re-enables it.

When the user corrects an interpretation, update the block document retroactively so it reflects the corrected model, and append the correction to `notes.md`. Do not leave stale claims standing in the document.

## Session Boundaries

Pause, close, or split the session when the user changes topics, moves into execution, starts a materially different design thread, the current thread becomes stale, or the user explicitly stops tracking. Do not merge unrelated explorations just because they happened in the same conversation.

## Convergence and Promotion

Move status from `exploring` to `converging` when one direction is becoming stronger but important assumptions or risks remain open. Move to `decided` only on a clear decision signal (the user explicitly choosing, asking to write it up, asking to implement, or repeatedly treating one direction as agreed after alternatives were considered).

Promote to a durable project artifact only after `decided`: shape the final ADR, issue, planning note, spec, or roadmap entry from the block document (`wb read --md` to export), carrying over the requirements/constraints block verbatim. Prefer updating an existing artifact over creating a new one. Keep `notes.md` as the trail. Do not open issues, create PRs, write ADRs, modify canonical docs, or change implementation files before convergence. After promotion, update `manifest.json` status to `decided` (then `archived`) and record the follow-up artifact path in the document and `notes.md`.

## Reference

- [references/cli-ops.md](references/cli-ops.md) — the `wb` CLI (load this).
- [references/pi.md](references/pi.md) — whiteboard under pi with the pi-whiteboard extension (load this if applicable).
- [references/note-schema-and-examples.md](references/note-schema-and-examples.md) — `notes.md` schema and promotion checklist.