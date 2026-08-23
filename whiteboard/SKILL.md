---
name: whiteboard
description: "Exploration that always opens the research field beyond what the user asked. Proactively load for any non-trivial question, design, or system discussion — including factual and probing questions, architecture, systems, agents, workflows, products, protocols, skills, prompts, and implementation strategy. Research the literal question with verified facts, then proactively bring in adjacent and relevant context the user may not have thought to ask about, surfaced with context. Do not load for pure execution tasks (direct implementation or edit, code review, CI fix, release, direct GitHub/PR work), simple prompt rewrite, or one-shot prompt optimization."
---

# Whiteboard

## Operating Principle

Treat ambiguous design discussion as exploration first — architecture, systems, agents, workflows, products, protocols, skills, prompts, implementation strategy, and other complex iterative design spaces. Name a session, keep notes automatically, help the user converge, and avoid implementation or canonical project artifacts until a direction has actually emerged. The working model is revisable; "I think X might work" is a hypothesis, not approval to build.

If this skill was loaded for a pure execution task (direct implementation/edit, code review, CI fix, release, direct GitHub/PR work), a simple prompt rewrite, one-shot prompt optimization, or a no-write environment, stop using it, do not create notes, and handle the task directly.

## Feedback

User feedback often points at a symptom, not the fix. Don't apply it as a literal local patch. Step back, hold the whole picture, and address the misframing the feedback reveals — a string of edits that each answer the literal comment but miss the underlying point is failure.

## Epistemic Discipline

Whiteboard is exploration, not a license to speculate. The user is depending on you to know what is actually true before the design conversation can move. Research first; assert only what you have verified.

- Research before you assert. Before stating how something works, what exists, how many parts it has, or what a name refers to, inspect the source, docs, logs, runtime, or prior art that would settle it. If you cannot verify it now, go verify it or explicitly mark it as a guess. Never present a guess as fact.
- Separate fact from speculation. Researched facts get stated plainly with their source; unverified claims get tagged hypothesis, assumption, or "not yet checked". If a claim is anywhere near material to the design, settle it with a source/runtime check before you rely on it — a guess that stays a guess near a decision is a latent defect.
- Use real names only. Never invent terminology, module names, file paths, function names, config keys, statuses, or counts. If you don't know the real name, say so and go find it. A made-up word is worse than "I don't know yet".
- No false analogies. Use an analogy only when it matches the actual mechanism; otherwise describe the mechanism directly.
- Verify once, not incrementally. If a claim you stated is challenged or you realize you never verified it, stop, recheck the source fully, and replace it. One clean correction beats a walk-back chain.
- "I don't know yet" is acceptable and expected.

## The Tool

Whiteboard is a methodology, not a tool implementation. It drives [`agentnotes`](https://github.com/pablof7z/agentnotes) — a standalone CLI, pi extension, MCP server, and web viewer — as an external dependency. Install it once per machine:

```bash
git clone https://github.com/pablof7z/agentnotes.git
cd agentnotes && npm install --workspaces && npm link
```

This puts `agentnotes` on PATH and (under pi) makes the pi extension available by symlinking `extension/` into `~/.pi/agent/extensions/agentnotes`. See the [agentnotes README](https://github.com/pablof7z/agentnotes#readme) for details.

The skill body below is process. Learn the tool from the reference files, then use it — don't carry command syntax here.

- **Always load [references/cli-ops.md](references/cli-ops.md)** — the `agentnotes` CLI: sessions, read, the staging transaction (artifact ops), annotation ops (`agentnotes attach`/`agentnotes tag`), meta-notes (`agentnotes note`/`agentnotes notes`), and `agentnotes listen` for detecting new annotations/chat.
- **Under pi with the agentnotes pi extension**, also read [references/pi.md](references/pi.md) — the `agentnotes_*` tools plus `meta_notes_add`/`meta_notes_read` (lazy/active: `agentnotes_new`/`agentnotes_list` load, then unlock the rest), attributed `[agentnotes]` wake messages, the auto-managed viewer, and `/agentnotes`. Under pi you don't run `agentnotes listen` or launch the viewer yourself.
- For the meta-notes writing discipline and promotion checklist, see [references/note-schema-and-examples.md](references/note-schema-and-examples.md).

## Start the Session

1. Assign a concise human-readable session name from the main object plus uncertainty, e.g. `NMP relay identity model exploration`.
2. Create or select a session with `agentnotes new <slug>` (or `agentnotes use <slug>` to reuse). Do not ask permission; do not interrupt the discussion.
3. Seed the document with the initial context and current working model as the artifact's content (a `goal` block, a `constraints` block, and whatever body blocks the artifact shape calls for). Surface the highest-value open questions as `agentnotes attach` (a `question` on the relevant span) or `agentnotes tag` (`needs-attention`), or as a terse meta-note (`agentnotes note`/`meta_notes_add`) — not as block content.
4. Keep exploring until clarity emerges. Prefer source inspection, runtime evidence, focused questions, and tradeoff analysis over premature edits.

## Block Document, Annotations, and Meta-Notes

The workspace holds three layers with different disciplines: the **block document** (the artifact), **annotations** (meta-discussion about the document), and **meta-notes** (your own private, append-only trail — `notes.md`, never touched by path; read/write only via `meta_notes_read`/`meta_notes_add` or `agentnotes notes`/`agentnotes note`).

**Block document — the artifact itself.** A sequence of **named markdown blocks** holding the content of the artifact you are converging toward — the spec, plan, proposal, design memo, or brief. Write it as if it were the finished artifact, kept at the best version you can produce right now. Mutate it retroactively: rewrite, reorganize, and replace freely as the working model evolves. It is not append-only, and it is not a record of how you got there.

Block content is the artifact's content, **not commentary about producing it.** No narration ("we explored…", "the question is whether…"), no changelog ("we decided X", "previously we assumed Y"), no "options considered" lists, no open questions. If a line would not appear in the finished artifact, it does not belong in a block. Rewrite the block to state the current best answer directly — a block that says "we are considering A vs B" should instead state A (or B) as the working model, with the unresolved choice pushed to an annotation or a note. What belongs on the blocks:

- **Requirements and constraints the user has stated**, in a dedicated current block (e.g. `constraints`). Add to it as new ones appear; never drop one without noting the user lifted it.
- The artifact's goal, current working model, and settled direction, stated as the artifact would state them.
- Material risks the artifact itself must carry (a spec names its risks; that is content, not process).

Keep it skimmable — for the human to steer, not a dump of every subagent report. Summarize verified findings here; keep the raw trail in meta-notes. Start each block with an `# H1` title (the viewer's TOC lists headings, not block names). The viewer renders markdown with syntax highlighting, Mermaid, and footnotes.

**Annotations — meta-discussion about the document.** Two verbs, both direct writes (not staged), both anchored to a span of a block (`--on` required — there are no block-level annotations; if you mean a whole block, anchor to its heading):

- **`agentnotes attach`** — replyable threads. Kinds: `question`, `warning`, `objection`, `note`. Use these for things *about* the document that are not part of the artifact: open questions, objections, choices that need the human, things to verify or sign off on. A `note` is a non-action side comment (it does not wake the agent); `question`/`warning`/`objection` from a human with no agent reply are actionable.
- **`agentnotes tag`** — short status tags. Kinds: `unverified`, `superseded`, `needs-attention`, `decided`. Idempotent set/clear; not replyable. Mark a span as needing the human with `needs-attention`, or as settled with `decided`.

Color is the only signal — the viewer renders each kind in its own color (a loud kind like amber `warning` or red `objection` is the “look at this” affordance; there is no separate attention/amber-card concept). Resolve threads (`agentnotes attach resolve`) as the document absorbs their answer; clear tags when the status no longer holds. Don't leave resolved discussion dangling.

**Meta-notes — your private trail.** Append-only, free text, no schema (`agentnotes note "entry"` / `meta_notes_add`). Capture: things the user made explicit, a subagent finding compressed to verdict + citation, corrections (`Correction (HH:MM): …`), why a block-document mutation happened. **Write terse — one line, the fact, no narration or filler; `agentnotes` warns (non-blocking) when an entry runs long or reads like prose.** Full discipline and examples in [references/note-schema-and-examples.md](references/note-schema-and-examples.md). If you keep sending block changes with nothing logged between them, `agentnotes` will remind you (surfaced on the next `change send`/`apply`) — that means the trail is going cold; log the reason.

## Exploration Loop

At each turn: mutate the block document (retroactively, as the live truth) and log a terse meta-note (`meta_notes_add`/`agentnotes note`) with any new model, evidence, objection, alternative, correction, or decision signal. Then respond in the main thread with the smallest useful accurate answer — researched facts for a factual question, or the decision-frontier synthesis when a real decision is open.

**Always explore via subagent.** Dispatch a subagent to research the user's question and to open the adjacent field. The main thread frames the question, dispatches one or more subagents with a bounded prompt, collects their results, updates the note, and synthesizes — it does not perform source inspection, runtime checks, doc/issue/ADR reads, or adjacent exploration directly in the main thread. This keeps the main thread honest: synthesis from verified subagent findings, not from priors. If no subagent tooling is available, say so explicitly, record the limitation, and do not substitute speculation.

**Answer the literal question, then open the field.** First answer what the user actually asked, with verified facts from source, docs, runtime, or prior art — do not pivot to a redesign until the literal question is answered. Then proactively open the field beyond it: adjacent and relevant context the user may not have thought to ask about — prior art, ownership boundaries, hidden constraints, related code paths, failure modes, comparable systems. Surface each with context: what you checked, what you found, why it bears on the question. Never drop a bare answer to a question the user did not ask. Apply the decision-frontier framing only when there is an actual choice — competing directions, a real tradeoff, or a design the user is actively revising. For a purely factual question, the response is the verified answer plus proactively gathered adjacent context, not a recommended direction.

**Get ahead of the next move.** When you have good certainty about where the user is likely to take the inquiry next, dispatch a subagent in that direction proactively, before the user asks — but only when the next move is genuinely likely; do not speculatively fire subagents in every direction.

**Allocate attention by decision relevance.** Shape the response as a flexible gradient from material least likely to need user input toward material most likely to need it. Compress explicit agreement and settled direction; keep agent-selected defaults brief and distinct from user-approved decisions; spend the budget on the decision frontier. When several choices remain, end with a short recap of what deserves attention next.

While the session is `exploring`, dispatch as subagent tasks: inspect source/docs/issues/ADRs/logs/runtime; compare alternatives against ownership boundaries, invariants, failure modes, integration risks; ask the user a focused question only when subagent findings cannot disambiguate; identify what evidence would change the recommendation. Do not edit implementation files because a plausible direction appeared. Do not treat the session as `converging` because you prefer an answer.

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

That structured shape is for the subagent's report back to you. Compress it to one terse meta-note line — verdict + citation, not the report restated (see references/note-schema-and-examples.md). Bring only the relevant conclusion back to the user, framed with context. If the result contradicts the current model, surface that clearly and update the block document.

## User Overrides

Obey direct user override commands immediately:

- `show notes` / `show document`: show the meta-notes trail (`meta_notes_read`/`agentnotes notes`) / the block document.
- `open viewer`: (re)launch the live viewer for the current session (under pi it's auto-managed).
- `rename this session`: rename the relevant blocks to match (`agentnotes change rename …`).
- `stop tracking this`: stop updating the session; log it as a meta-note.
- `forget that`: remove or revise the affected block; log the removal as a meta-note.
- `that was not a decision`: move the item out of decisions into hypothesis/preference/rejected/open-question; log it.
- `mark this as decided`: record the decision in the block document (a `decisions` block) and log it as a meta-note; treat further options as closed. Optionally tag the settled span `agentnotes tag --kind decided`.
- `save this now`: commit any open staging (`agentnotes change send`).
- `do not run background agents here`: stop proactive adjacent exploration unless the user re-enables it.

When the user corrects an interpretation, update the block document retroactively so it reflects the corrected model, and log a terse `Correction:` meta-note. Do not leave stale claims standing in the document.

## Session Boundaries

Pause, close, or split the session when the user changes topics, moves into execution, starts a materially different design thread, the current thread becomes stale, or the user explicitly stops tracking. Do not merge unrelated explorations just because they happened in the same conversation.

## Convergence and Promotion

Treat the session as `converging` when one direction is becoming stronger but important assumptions or risks remain open; treat it as `decided` only on a clear decision signal (the user explicitly choosing, asking to write it up, asking to implement, or repeatedly treating one direction as agreed after alternatives were considered). Record these state changes in the block document and as a terse meta-note.

Promote to a durable project artifact only after `decided`: shape the final ADR, issue, planning note, spec, or roadmap entry from the block document (`agentnotes read --md` to export), carrying over the requirements/constraints block verbatim. Prefer updating an existing artifact over creating a new one. Keep meta-notes as the trail. Do not open issues, create PRs, write ADRs, modify canonical docs, or change implementation files before convergence. After promotion, record the follow-up artifact path in the document and as a meta-note.

## Reference

- [references/cli-ops.md](references/cli-ops.md) — the `agentnotes` CLI (load this).
- [references/pi.md](references/pi.md) — whiteboard under pi with the agentnotes pi extension (load this if applicable).
- [references/note-schema-and-examples.md](references/note-schema-and-examples.md) — meta-notes writing discipline and promotion checklist.