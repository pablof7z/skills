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
2. Create or select a note file without asking whether to take notes. Do not interrupt the discussion with a permission question.
3. Record the initial context, the current working model, and the highest-value open questions before or during the first substantive response.
4. Keep exploring until clarity emerges. Prefer source inspection, runtime evidence, focused questions, and tradeoff analysis over premature edits.

Treat tentative language like "I think X might work" as a hypothesis, not approval to implement.

## Note Location

Always store exploration notes under the agent private home from the `agent-home` skill:

```text
~/.agents/home/{identifier}/whiteboard/<project-slug>/YYYY-MM-DD-<session-slug>.md
```

Resolve `{identifier}` with `agent-home` (stable agent identity, not a session handle).

Resolve `<project-slug>` as:

1. The git repository name when inside a git work tree. Use the main repository directory name, not the worktree directory name:

```bash
basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
```

2. Otherwise the basename of the current working directory only (`basename "$PWD"`), never a full path.

Create parent directories as needed. If an existing note clearly matches the same session, update it instead of creating another. Do not write exploration notes into the project tree.

If the environment cannot write a note file, do not apply this skill.

## Note Contents

Use the full template in [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating or refreshing notes. Every note must track:

- Session name
- Date and project/context
- Status: `exploring`, `converging`, `decided`, or `archived`
- Core question
- Current working model
- Observations
- Constraints and invariants
- Preferences
- Assumptions
- Open questions
- Hypotheses
- Risks
- Evidence gathered
- Adjacent checks
- Alternatives considered, including rejected options
- Decisions or emerging direction
- Follow-up artifacts, if any

Update the note as the discussion evolves. Keep entries concise, preserve concrete names and file paths, and make uncertainty explicit instead of smoothing it away.

Keep observations, assumptions, hypotheses, constraints, preferences, decisions, rejected options, risks, and open questions distinct. Do not promote a hypothesis, preference, or repeated suggestion into a decision unless the user explicitly agrees or the conversation clearly converges.

## Exploration Loop

At each turn, update the note with any new model, evidence, objection, alternative, correction, or decision signal. Then respond in the main thread with the smallest useful accurate answer — researched facts for a factual question, or the decision-frontier synthesis below when a real decision is open.

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

- `show notes`: summarize or show the current note path and contents.
- `rename this session`: rename the session and note file if practical.
- `stop tracking this`: mark the note `archived` or stop updating it.
- `forget that`: remove or revise the affected note content.
- `that was not a decision`: move the item out of decisions and into hypothesis, preference, rejected option, or open question as appropriate.
- `mark this as decided`: mark the session `decided`, unless doing so would create a false record; if unclear, record the user's command as the decision signal.
- `split this into a new session`: create a separate note and move the relevant context.
- `merge this with the previous session`: merge only related explorations and preserve distinct decisions/risks.
- `save this now`: flush the current note under the agent private home path without bypassing the convergence gate for canonical project artifacts.
- `do not run background agents here`: stop proactive adjacent exploration for this session unless the user later re-enables it.

When the user corrects an interpretation, revise the affected note sections retroactively. Do not merely append a correction below stale assumptions.

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

Summarize the result into the main notes. Bring only the relevant conclusion back to the user, framed with context: what was checked, what was found, and why it bears on the user's question or the current design. Never drop a bare answer to a question the user did not ask — if the finding is worth surfacing, say what it is and why it matters. If the result contradicts the current model, surface that clearly. Do not paste large background reports into the main conversation.

## Convergence and Promotion

Move status from `exploring` to `converging` when one direction is becoming stronger but important assumptions or risks remain open. Do not mark a session `converging` only because the agent has a preferred answer.

Move status to `decided` only when there is a clear decision signal, such as the user explicitly choosing a direction, asking to write it up, asking to implement, or repeatedly treating one direction as the agreed model after alternatives have been considered.

Promote notes to a durable project artifact only after the session is `decided`. Prefer updating an existing artifact over creating a new one. Match the project's existing durable style: ADR, issue, planning note, spec, roadmap entry, or project notes.

Do not open GitHub issues, create PRs, write ADRs, modify canonical docs, or change implementation files before convergence. Move to implementation only when the user directly asks for it or the agreed direction is clear and the next requested action requires implementation.

After promotion, update the exploration note with the follow-up artifact path or URL and mark it `archived` when it no longer needs active updates.

## Reference

Read [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating the first note, checking trigger edge cases, or promoting a decided exploration into a durable artifact.
