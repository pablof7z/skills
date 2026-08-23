# Notes Log Schema And Examples

Read this file when creating or refreshing a session's `notes.md`, checking trigger boundaries, or promoting a converged exploration into a durable project artifact.

The session workspace holds the block document and `notes.md` with different disciplines (see `SKILL.md` → Session Workspace):

- **Block document** — the outward document. A sequence of named markdown blocks mutated only through `agentnotes` (the fold over `changes/<rev>.json`). Rewritten retroactively as the live truth. Becomes the durable artifact on promotion (export with `agentnotes read --md`).
- **`notes.md`** — the append-only log. This file. Captures the trail that produced the block document.

## notes.md Structure

`notes.md` has two parts: a structured **state block** at the top that you edit in place, and an **append-only log** below it that you only ever append to.

```markdown
# <Session name> — notes log

Date: <YYYY-MM-DD>
Project/context: <repo, module, product, or conversation context>
Status: exploring

## Core Question

- <What the user is trying to understand or decide>

## Current Working Model

- <Best current explanation or proposed model>

## Observations

- <Concrete user statements, source facts, runtime behavior, logs, or other checked facts>

## Constraints And Invariants

- <Non-negotiables, ownership boundaries, compatibility needs, protocol constraints, or integration limits>

## Preferences

- <User or project preference; do not treat as a decision unless agreed>

## Assumptions

- <Unverified context or likely convention; include how to verify it>

## Open Questions

- <Question that could change the direction>

## Hypotheses

- <Tentative idea, explicitly marked as unproven>

## Risks

- <Failure mode, cost of being wrong, migration risk, security/privacy risk, operational risk, or reversibility concern>

## Evidence Gathered

- <Source, runtime behavior, issue, log, ADR, user statement, or code path>

## Alternatives Considered

- <Alternative>: <why it helps, why it may fail>

## Rejected Options

- <Rejected option>: <reason, evidence, or decision signal>

## Decisions Or Emerging Direction

- <Only record decisions when explicit or strongly implied>

## Follow-Up Artifacts

- <ADR, issue, spec, roadmap entry, PR, or planning note after promotion>

---

## Log

### <YYYY-MM-DD>

- <HH:MM> <Entry: user statement, subagent finding (compact, with source), adjacent check, or correction.>
- <HH:MM> Correction: <what the user corrected and the corrected model.>
- Adjacent check: <question>
  Finding: <1-3 sentence synthesis>
  Implication: <how this affects the current design>
  Confidence: <low/medium/high>
```

The state block is edited in place as the model evolves (replace stale entries). The log below the `---` is append-only: add timestamped entries, never rewrite them. When a correction changes the model, update the state block above **and** append a `Correction:` entry below.

Status values:

- `exploring`: active uncertainty; alternatives and tradeoffs are still open.
- `converging`: one direction is strongest, but assumptions or risks remain.
- `decided`: a clear direction exists and the user has chosen or strongly implied it.
- `archived`: the result has been promoted or no longer needs active tracking.

Do not promote a hypothesis, preference, or repeated suggestion into a decision unless the user explicitly agrees or the conversation clearly converges.

## Block Document Shape

The block document has no fixed template — shape it to the session (plan, proposal, spec, design memo). It is a sequence of named markdown blocks (each starting with an `# H1` title; the TOC lists headings, not block names). It must always carry:

- **Requirements and constraints** the user has stated, in a dedicated current block (e.g. `constraints`).
- The core question and current working model.
- The viable options and the emerging direction, with the decision frontier visible.
- Open questions and material risks.

Keep it skimmable for the human; summarize verified findings here, keep the raw trail in `notes.md`. Mutate it only through `agentnotes change` (retroactively — rewrite and reorganize freely as the working model evolves).

## Naming

Session names should be short, searchable, and specific:

- `NMP relay identity model exploration`
- `Trellis phase-boundary design exploration`
- `Podcast queue ownership exploration`
- `skill trigger boundary exploration`
- `agent handoff workflow exploration`

Session directory slugs are lowercase hyphen-case, with a year-month date prefix:

```text
~/agentnotes/nmp/2026-07-nmp-relay-identity-model/
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

Keep both artifacts compact. Prefer bullets with concrete nouns, paths, issue numbers, command names, logs, and direct user decisions. Do not copy long subagent reports into either; summarize key facts, conflicts, risks, and implications in `notes.md`, and only the decision-relevant synthesis in the block document.

Keep these categories separate (in the `notes.md` state block):

- observations: checked facts and direct user statements
- assumptions: unverified context or likely conventions
- hypotheses: tentative models being tested
- constraints: limits the design must respect
- preferences: desired direction without decision force
- decisions: explicit or clearly converged choices
- rejected options: alternatives ruled out or deferred
- risks: ways the direction could fail or be expensive to reverse
- open questions: uncertainty that could change the direction

When exploration contradicts the working model, update the state block's `Current Working Model` and `Observations` in place, record the contradiction under `Evidence Gathered`, and append a log entry. Update the block document to match via `agentnotes change`. Do not leave stale claims standing in the block document while a correction sits only in the log.

## Adjacent Check Examples

Good adjacent checks include prior art or prior ADRs/issues/PRs, existing ownership boundaries, hidden protocol/dependency/platform constraints, terminology pressure, comparable systems, failure modes and cost of being wrong, security/privacy implications, operational complexity, reversibility, and runtime evidence that can confirm or falsify the working model.

Prefer one high-leverage adjacent check at a time. Use the compact `Finding / Implication / Confidence` form, recorded in the log.

## Promotion Checklist

Before promoting to a durable artifact, confirm the session has:

- a chosen or strongly implied direction
- at least one alternative considered and rejected or deferred
- evidence supporting the direction
- observations, assumptions, hypotheses, constraints, preferences, risks, and open questions separated clearly in `notes.md`
- known unresolved risks or a statement that none are material
- the target artifact type that matches project convention

Shape the durable artifact from the block document (`agentnotes read --md` to export), carrying its requirements/constraints block over verbatim. Prefer updating existing ADRs, specs, planning notes, roadmap entries, or issues; create a new one only when no suitable existing artifact exists. After promotion, record the follow-up artifact path in the block document and `notes.md`, and set `manifest.json` status to `decided` (then `archived`).