# Note Schema And Examples

Read this file when creating or refreshing a whiteboard exploration note, checking trigger boundaries, or promoting a converged exploration into a durable project artifact.

## Note Template

```markdown
# <Session name>

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

- <Memory, prior preference, likely convention, or unverified context; include how to verify it>

## Open Questions

- <Question that could change the direction>

## Hypotheses

- <Tentative idea, explicitly marked as unproven>

## Risks

- <Failure mode, cost of being wrong, migration risk, security/privacy risk, operational risk, or reversibility concern>

## Evidence Gathered

- <Source, runtime behavior, issue, log, ADR, user statement, or code path>

## Adjacent Checks

- Adjacent check: <question>
  Finding: <1-3 sentence synthesis>
  Implication: <how this affects the current design>
  Confidence: <low/medium/high>
  Suggested note update: <optional>

## Alternatives Considered

- <Alternative>: <why it helps, why it may fail>

## Rejected Options

- <Rejected option>: <reason, evidence, or decision signal>

## Decisions Or Emerging Direction

- <Only record decisions when explicit or strongly implied>

## Follow-Up Artifacts

- <ADR, issue, spec, roadmap entry, PR, or planning note after promotion>
```

Status values:

- `exploring`: active uncertainty; alternatives and tradeoffs are still open.
- `converging`: one direction is strongest, but assumptions or risks remain.
- `decided`: a clear direction exists and the user has chosen or strongly implied it.
- `archived`: the result has been promoted or no longer needs active tracking.

Do not promote a hypothesis, preference, or repeated suggestion into a decision unless the user explicitly agrees or the conversation clearly converges.

## Naming

Session names should be short, searchable, and specific:

- `NMP relay identity model exploration`
- `Trellis phase-boundary design exploration`
- `Podcast queue ownership exploration`
- `tenex-edge awareness routing exploration`
- `skill trigger boundary exploration`
- `agent handoff workflow exploration`

File slugs should be lowercase hyphen-case:

```text
2026-07-09-nmp-relay-identity-model-exploration.md
```

## Trigger Examples

Use the skill for:

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

If a simple question becomes iterative across turns with alternatives, objections, or changed direction, start the note at that point and include the prior context in the first entry.

## Update Discipline

Keep notes compact. Prefer bullets with concrete nouns, paths, issue numbers, command names, logs, and direct user decisions. Do not copy long background-agent reports into the note; summarize key facts, conflicts, risks, and implications.

Keep these categories separate:

- observations: checked facts and direct user statements
- assumptions: unverified context or likely conventions
- hypotheses: tentative models being tested
- constraints: limits the design must respect
- preferences: desired direction without decision force
- decisions: explicit or clearly converged choices
- rejected options: alternatives ruled out or deferred
- risks: ways the direction could fail or be expensive to reverse
- open questions: uncertainty that could change the direction

When background exploration contradicts the working model, record the contradiction under `Evidence Gathered` and update `Current Working Model` rather than burying it.

When the user corrects an interpretation, revise the affected sections retroactively. Do not append a correction below stale assumptions while leaving the stale assumption active.

## Adjacent Check Examples

Good adjacent checks include:

- prior art or prior ADRs/issues/PRs that may already settle the question
- existing ownership boundaries that may contradict the proposed direction
- hidden protocol, dependency, platform, or compatibility constraints
- terminology and naming pressure that could reveal a confused model
- comparable systems, sibling projects, or similar modules
- failure modes and cost of being wrong
- security and privacy implications
- operational complexity, release risk, migration burden, and testability
- reversibility: whether a wrong decision can be unwound cheaply
- runtime evidence that can confirm or falsify the working model

Prefer one high-leverage adjacent check at a time. Do not launch background work for curiosity, obvious facts, or questions unlikely to materially affect the design.

Use this compact result format:

```text
Adjacent check: [question]
Finding: [1-3 sentence synthesis]
Implication: [how this affects the current design]
Confidence: [low/medium/high]
Suggested note update: [optional]
```

## Promotion Checklist

Before creating or updating a durable artifact, confirm the note has:

- a chosen or strongly implied direction
- at least one alternative considered and rejected or deferred
- evidence supporting the direction
- observations, assumptions, hypotheses, constraints, preferences, risks, and open questions separated clearly
- known unresolved risks or a statement that none are material
- the target artifact type that matches project convention

Prefer updating existing ADRs, specs, planning notes, roadmap entries, or issues. Create a new durable artifact only when no suitable existing artifact exists.

During exploration, prefer scratch notes. Promote to durable repo/project notes only when the project already has a clear WIP/design-note convention, the user asks to save/write/document it, or the design has converged enough that losing the state would be costly.
