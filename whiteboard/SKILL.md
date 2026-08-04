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
2. Create or select a note file without asking whether to take notes. Do not interrupt the discussion with a permission question.
3. Record the initial context, the current working model, and the highest-value open questions before or during the first substantive response.
4. Keep exploring until clarity emerges. Prefer source inspection, runtime evidence, focused questions, and tradeoff analysis over premature edits.

Treat tentative language like "I think X might work" as a hypothesis, not approval to implement.

## Note Location

Always store exploration notes under the agent private home from the `home-directory` skill:

```text
~/.agents/home/{identifier}/whiteboard/<project-slug>/YYYY-MM-DD-<session-slug>.md
```

Resolve `{identifier}` with `home-directory` (stable agent identity, not a session handle).

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

At each turn, update the note with any new model, evidence, objection, alternative, correction, or decision signal. Then respond in the main thread with the smallest useful synthesis.

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

Summarize the result into the main notes. Bring only the relevant conclusion back to the user. If the result contradicts the current model, surface that clearly. Do not paste large background reports into the main conversation.

## Convergence and Promotion

Move status from `exploring` to `converging` when one direction is becoming stronger but important assumptions or risks remain open. Do not mark a session `converging` only because the agent has a preferred answer.

Move status to `decided` only when there is a clear decision signal, such as the user explicitly choosing a direction, asking to write it up, asking to implement, or repeatedly treating one direction as the agreed model after alternatives have been considered.

Promote notes to a durable project artifact only after the session is `decided`. Prefer updating an existing artifact over creating a new one. Match the project's existing durable style: ADR, issue, planning note, spec, roadmap entry, or project notes.

Do not open GitHub issues, create PRs, write ADRs, modify canonical docs, or change implementation files before convergence. Move to implementation only when the user directly asks for it or the agreed direction is clear and the next requested action requires implementation.

After promotion, update the exploration note with the follow-up artifact path or URL and mark it `archived` when it no longer needs active updates.

## Reference

Read [references/note-schema-and-examples.md](references/note-schema-and-examples.md) when creating the first note, checking trigger edge cases, or promoting a decided exploration into a durable artifact.
