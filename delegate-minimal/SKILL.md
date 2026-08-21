---
name: delegate-minimal
description: When delegating work to another agent, state the outcome and get out of the way — do not prescribe the process. Use when handing off, dispatching, spawning a subagent, assigning a task, or otherwise asking another agent to do work. Triggers include "delegate", "dispatch", "assign to", "hand off to", "ask the agent to", "have the agent", "spawn agent to", "tell X to", "route to".
---

# Delegate Minimal — state the goal, then stop

You are the delegator, not the worker. Say what "done" looks like. Hand over. Stop typing.

## The rule

Give the delegate the **what** and the **why**. Withhold the **how**.

A delegation message should fit in a few lines:

- the outcome you want
- the constraints that actually matter (deadlines, invariants, what must not break)
- the context the delegate lacks and cannot infer
- nothing else

## Delete on sight

- **Process prescriptions** — step-by-step "first do X, then Y, then Z." You are overfitting the delegate to your guess of the problem. The delegate sees the real problem; let it pick the path.
- **How-to for experts** — explaining their own specialty to them. If the delegate owns a vertical you don't, your instructions make it *worse*. State the goal; trust the expertise.
- **Redundant restatement** — "make sure you test it," "remember to handle errors," "follow best practices." Competent agents already do these. Saying them is noise that crowds out signal.
- **Your workaround history**** — "we tried A and B so try C." Give the *goal and constraints*, not the path you'd walk.

## Keep, always

- the success condition — what observable result ends the work
- hard constraints — budget, scope fences, things that must not break
- context the delegate genuinely lacks — secrets, prior decisions, where the bodies are
- the reason — one line on why this matters, if non-obvious

## Anti-patterns

- Five-paragraph brief for a one-sentence job. You are not helping; you are adding surface area for the delegate to misinterpret.
- "Expert" corrections from a non-expert. A generalist prescribing steps to a specialist is how specialists ship worse work than they would have alone.
- Disguised micromanagement — "feel free to do it however, but here's how I'd approach it..." The delegate hears the prescription, not the freedom.

## Test

Read your delegation back. Cross out every sentence about *how*. What remains should be: goal, constraints, missing context. If that's not enough for the delegate to start, add context — not steps.