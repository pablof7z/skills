# Design Exploration Capture

## Preserve the path to a decision, not just the final sentence

Complex design work rarely moves in a straight line. A promising model reveals a hidden constraint. An objection changes the ownership boundary. A rejected option becomes useful under a different assumption. Weeks later, the final decision looks obvious only because the difficult path that produced it has disappeared.

`design-exploration-capture` gives that path a durable shape while the thinking is still alive.

It does not force an uncertain conversation into a premature specification. It keeps observations, assumptions, hypotheses, preferences, risks, alternatives, and actual decisions separate, so the team can change its mind without rewriting history.

## What the skill protects

- **Continuity:** the working model survives long sessions, context resets, and handoffs.
- **Intellectual honesty:** tentative ideas do not silently become approved architecture.
- **Decision quality:** alternatives are compared against constraints, invariants, and failure modes rather than taste alone.
- **Reversibility:** rejected directions retain the reason they lost, making them easier to revisit when conditions change.
- **Timing:** implementation waits until the conversation has genuinely converged.

The skill names the exploration, keeps concise notes without interrupting to ask permission, and updates the record as evidence or objections change the model. When a direction becomes real, it can be promoted into the repository's existing durable format: an issue, ADR, plan, or specification.

## Start an exploration

Invoke it in the language of the unresolved question:

```text
$design-exploration-capture help me work through whether query ownership belongs in the engine or the app shell.
```

Useful follow-ups are direct:

```text
show notes
that was not a decision
split this into a new session
mark this as decided
```

The output is not a ceremonial document. It is a reliable memory of what is known, what remains uncertain, and which evidence would change the direction.

Read [SKILL.md](SKILL.md) for the lifecycle and [the note schema](references/note-schema-and-examples.md) for the exact record it maintains.
