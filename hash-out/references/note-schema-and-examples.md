# Meta-Notes Log

Read this file when writing to a session's meta-notes log, checking trigger boundaries, or promoting a converged exploration into a durable project artifact.

The session workspace holds two things with different disciplines (see `SKILL.md` → Session Workspace):

- **Block document** — the outward artifact. A sequence of named markdown blocks mutated only through `pad` (the fold over `changes/<rev>.json`). Rewritten retroactively as the live truth. Becomes the durable artifact on promotion (export with `pad read --md`). This is where the structured summary lives — goal, constraints, current model, decisions, open questions — not `notes.md`.
- **Meta-notes (`notes.md`)** — your own private, append-only scratchpad: why the document is changing, what you tried, what you ruled out. Written with `pad_meta_notes_add` (pi/MCP) or `pad note <text>` (CLI); read back with `pad_meta_notes_view` / `pad notes`. Never read or write the raw file path directly — go through those, so the path stays an implementation detail.

Session status (`exploring`/`converging`/`decided`/`archived`) lives in the session's `manifest.json`, not in `notes.md` — there is no state block to keep in sync.

## Writing discipline: terse, or don't write it

A meta-note is a fact for future-you, not prose for a reader. Every entry:

- States the fact directly. No narration ("we explored…", "the question is whether…"), no throat-clearing ("it's worth noting that…"), no hedging ("this may potentially…"), no intensifiers (very/really/extremely/significantly), no empty adjectives (robust/seamless/comprehensive/pivotal/holistic).
- Compresses a subagent's finding to its verdict and citation, not its paragraph — `finding + file:line`, not a restated report.
- Skips whatever is already obvious from the block document. If it belongs in the artifact, it doesn't belong here too.
- Fits on one line where the fact allows it. `pad` warns (non-blocking) past ~40 words or on a filler-word hit — heed it, don't write around it.

Bad: "It's worth noting that after exploring this in some depth, we found that the viewer's notes rendering is really quite undercooked and could benefit from a more comprehensive treatment."
Good: "notes-view: flat markdown dump, no entry differentiation (viewer/blockview.mjs:31-34). Confirmed, not user unfamiliarity."

## When To Write One

- A user statement that changes the model: a new constraint, a correction, a decision.
- A subagent's finding, compressed to verdict + citation.
- A correction: `Correction (HH:MM): <what changed, in one line>`.
- Around a block-document mutation (`pad change send` / `pad apply`) whenever the *why* isn't obvious from the diff alone. Several mutations with nothing logged between them will trip `pad`'s own reminder (surfaced on the next change/apply call) — that means the trail is going cold, not that the tool is nagging for its own sake. Log the reason and move on.

## Example Entries

```text
- (2026-08-23 07:26) notes-view: flat markdown dump, no entry differentiation (viewer/blockview.mjs:31-34). Confirmed, not user unfamiliarity.
- (2026-08-23 07:27) Correction (07:27): user meant the block-doc storage, not notes.md — notes.md is already plain markdown.
- (2026-08-23 07:31) Decided: meta-notes stays free text, no schema. Block doc keeps the structured summary.
```

## Block Document Shape

The block document has no fixed template — shape it to the session (plan, proposal, spec, design memo). It is a sequence of named markdown blocks (each starting with an `# H1` title; the TOC lists headings, not block names). It must always carry:

- **Requirements and constraints** the user has stated, in a dedicated current block (e.g. `constraints`).
- The core question and current working model.
- The viable options and the emerging direction, with the decision frontier visible.
- Open questions and material risks.

Keep it skimmable for the human; summarize verified findings here, keep the raw trail in `notes.md`. Mutate it only through `pad change` (retroactively — rewrite and reorganize freely as the working model evolves).

## Naming

Session names should be short, searchable, and specific:

- `NMP relay identity model exploration`
- `Trellis phase-boundary design exploration`
- `Podcast queue ownership exploration`
- `skill trigger boundary exploration`
- `agent handoff workflow exploration`

Session directory slugs are lowercase hyphen-case, with a year-month date prefix:

```text
~/pad/nmp/2026-07-nmp-relay-identity-model/
```

## Trigger Examples

Use the skill for:

- "How does the relay identity model work?" (a factual question — research it, then proactively bring in adjacent context)
- "How does the relay identity model work? What if app accounts owned it instead?"
- "I am not sure whether Trellis should split this at phase boundaries or runtime boundaries."
- "Compare the queue ownership designs before we implement anything."
- "That model feels wrong because failure recovery crosses the shell/Rust boundary. What else could own it?"
- "This skill trigger seems too broad. What if we split prompt rewriting from meta-prompt design?"
- "We need an implementation strategy, but I want to compare migration paths before coding."
- "How should this agent workflow hand off state? I keep changing my mind about the boundary."

Do not use the skill for:

- "What is an ADR?"
- "Implement the queue ownership fix."
- "Review this PR."
- "Fix the failing CI job."
- "Rewrite this prompt."
- "Optimize this prompt once."

If a simple question becomes iterative across turns with alternatives, objections, or changed direction, start the workspace at that point and include the prior context in the first log entry.

## Update Discipline

Keep the block document compact and current: the decision-relevant synthesis, not a dump of every subagent report. Keep meta-notes terser still — one line per fact, per the writing discipline above.

These categories are useful for *thinking about* the state of an exploration, even with no dedicated section for each: observations (checked facts), assumptions (unverified context), hypotheses (tentative models), constraints, preferences, decisions, rejected options, risks, open questions. Mark them directly on the block document's relevant span with `pad tag` (`unverified`/`needs-attention`/`decided`) and `pad attach` (`question`/`warning`/`objection`) rather than maintaining a parallel categorized list in `notes.md`.

When exploration contradicts the working model, update the block document's current-model block via `pad change`, and log a `Correction:` entry in `notes.md` so the trail shows what changed and when. Do not leave stale claims standing in the block document while a correction sits only in the log.

## Adjacent Check Examples

Good adjacent checks include prior art or prior ADRs/issues/PRs, existing ownership boundaries, hidden protocol/dependency/platform constraints, terminology pressure, comparable systems, failure modes and cost of being wrong, security/privacy implications, operational complexity, reversibility, and runtime evidence that can confirm or falsify the working model.

Prefer one high-leverage adjacent check at a time. A subagent may report back in a `Finding / Implication / Confidence` shape — that's fine for what it hands *you*. What you then write to `notes.md` is the terse compression of that: verdict + citation on one line (e.g. `"notes-view: no schema parsing (blockview.mjs:31-34), high confidence"`), not the three-field report restated.

## Promotion Checklist

Before promoting to a durable artifact, confirm the session has:

- a chosen or strongly implied direction
- at least one alternative considered and rejected or deferred
- evidence supporting the direction
- observations, assumptions, hypotheses, constraints, preferences, risks, and open questions clearly reflected in the block document (via its own blocks, plus `pad tag`/`pad attach`)
- known unresolved risks or a statement that none are material
- the target artifact type that matches project convention

Shape the durable artifact from the block document (`pad read --md` to export), carrying its requirements/constraints block over verbatim. Prefer updating existing ADRs, specs, planning notes, roadmap entries, or issues; create a new one only when no suitable existing artifact exists. After promotion, record the follow-up artifact path in the block document and log it with `pad_meta_notes_add`/`pad note`, and set `manifest.json` status to `decided` (then `archived`).