---
name: cohesive
description: Reconstruct user intent, reconcile new requirements with existing architecture, and prevent additive or symptom-level patches. Use for ambiguous/high-level feature requests, structural changes, recurring bugs, or any change where the literal request may not be the real objective.
---

# Cohesive

Treat both the user's prompt and the current codebase as **evidence**, not ground truth.

The goal is not the smallest diff. The goal is the **smallest coherent change**: a change that satisfies the user's underlying intent, preserves explicit constraints, and leaves the system conceptually cleaner or at least no less coherent than before.

## When to activate

Use the full workflow when any of these are true:

- The request is high-level, exploratory, ambiguous, or dictated/thought aloud.
- The user mixes desired outcomes with suggested mechanisms ("maybe", "ideally", "could", "e.g.", "use X").
- A new feature crosses subsystem boundaries or changes the domain model.
- The obvious implementation would add a parallel path, guard, flag, adapter, wrapper, helper, or special case.
- A bug has already been patched before, is intermittent, or suggests an invalid state/ownership problem.
- The requested change makes an existing abstraction feel strained.
- The user explicitly asks for a proper fix, root-cause fix, refactor, cleanup, rethink, or architectural work.

Use the **fast path** for truly mechanical changes: explicit outcome, no meaningful ambiguity, no domain/ownership change, and an implementation that follows a clearly healthy existing pattern. Still perform the Coherence Gate internally. If the fast path uncovers structural tension, switch to the full workflow.

## Hard rules

1. **User wording is not automatically a specification.** Infer the underlying goal before treating implementation suggestions as requirements.
2. **Candidate mechanisms are non-binding by default.** Examples, ideas, and phrases such as "maybe", "ideally", "could", and "for example" are evidence about intent unless the user explicitly locks them.
3. **Existing architecture is not automatically a constraint.** It is evidence about prior decisions. Reuse it only when it still fits the new reality.
4. **Optimize for the smallest coherent change, not the smallest diff.** A larger refactor can be smaller conceptually than another special case.
5. **Deletion, consolidation, generalization, and replacement are first-class options.** Do not default to additive code.
6. **Do not fix a bug before explaining its mechanism.** Diagnostic instrumentation is allowed before root cause is known; production fixes are not.
7. **Do not refactor unrelated code.** Structural work must be causally connected to the goal, invariant, or failure being addressed.
8. **Do not ask the user questions the codebase can answer.** Investigate facts; ask only for human-owned product judgments or material ambiguity.
9. **Do not silently preserve obsolete paths.** When a new design supersedes an old path, identify its retirement explicitly.
10. **When new evidence invalidates the plan, re-plan.** Never patch around a now-wrong plan merely because implementation has started.

---

# Workflow

## 1. Learn before asking or editing

Do a read-only reconnaissance first.

Read the relevant project instructions, architecture/domain docs, tests, and the 5–15 source files most likely to define the affected behavior. Trace enough of the data/control flow to answer:

- What concept owns this behavior today?
- What are the current invariants?
- Where does state originate and who may mutate it?
- Which public/user-visible behavior must remain stable?
- Which existing abstractions and paths would the requested change touch?
- Are there already parallel concepts, compatibility layers, special cases, or deprecated paths nearby?
- What existing tests characterize current behavior?

Do not edit during this step.

Existing patterns are **inputs to judgment**, not templates to copy automatically.

## 2. Reconstruct intent

Before planning implementation, build an internal **Intent Map** from the user's request.

```text
GOAL
  The underlying outcome the user is trying to achieve.

OBSERVATIONS / PAIN
  What prompted the request; what currently feels wrong.

OBSERVABLE OUTCOMES
  What should become true from the user's or system consumer's perspective.

CONSTRAINTS / INVARIANTS
  Things that must remain true.

PREFERENCES
  Desired qualities or trade-offs that are not hard constraints.

CANDIDATE MECHANISMS
  Solutions the user mentioned. NON-BINDING unless explicitly locked.

NON-GOALS / EXCLUSIONS
  Things explicitly or implicitly outside this change.

UNKNOWNS
  Questions whose answers could materially change product behavior or architecture.
```

Preserve the user's terminology when it carries meaning. Do not flatten nuanced language into generic requirements jargon.

### Reflection gate

If interpretation is materially uncertain, **reflect before interrogating**:

- State the underlying goal in your own words.
- Separate outcomes from mechanisms you think the user merely suggested.
- State the important constraints/non-goals you inferred.
- Name the one or two uncertainties that could change the solution.
- Ask the user to correct the read.

Do not combine this with a long questionnaire. Wait for correction when the ambiguity is consequential.

If the request is already clear, this gate can remain internal.

## 3. Surface assumptions instead of outsourcing archaeology to the user

For each material uncertainty that code inspection can partially resolve, create an assumption:

```text
ASSUMPTION: <specific claim>
EVIDENCE: <files/tests/docs/behavior that support it>
IF WRONG: <concrete consequence for the design>
CONFIDENCE: high | medium | low
```

Read more before settling for low confidence.

Ask the user only when:

- the decision is genuinely product-owned rather than codebase-owned, and
- getting it wrong would materially change behavior, scope, data semantics, or architecture.

When asking, lead with your recommended interpretation and why, then give the real alternatives. Do not ask generic checklist questions.

## 4. Architecture Reconciliation Gate

Run this gate before proposing implementation for any non-mechanical change.

### A. State the new information

What did this request, requirement, or bug teach us about the domain/system that the existing design may not have represented?

### B. Counterfactual design test

Ask:

> If this requirement had existed when this subsystem was originally designed, would we have designed it differently?

If **no**, explain briefly why the current abstraction naturally accommodates it.

If **yes**, describe what the subsystem should look like given what is now known **before** deciding how to modify the current code.

### C. Generate alternatives before anchoring

For structural changes, consider at least two materially different approaches. When useful, include:

1. **Local/additive:** preserve the current model and add the behavior.
2. **Reconciled/refactor:** reshape the existing abstraction so old and new behavior share one coherent model.
3. **Subtractive/replacement:** delete or replace an abstraction/path that no longer represents the domain correctly.

Do not manufacture three options when only one is sensible, but do not accept the first plausible patch without considering a structural alternative.

### D. Accretion audit

Before choosing, explicitly check whether the proposed approach would create any of these:

- another path for the same concept
- duplicated state or source of truth
- a guard that merely prevents an invalid state from surfacing
- a boolean/enum branch that records a historical exception rather than a domain concept
- an adapter around an abstraction that should instead change
- a second helper/service/model for an existing responsibility
- compatibility code with no retirement condition
- an old implementation that becomes obsolete but remains reachable
- ownership split across layers
- a new abstraction whose only purpose is to avoid touching existing code

If yes, treat that as evidence in favor of reconciliation rather than accepting the complexity automatically.

### E. Select the smallest coherent design

Choose the design that best represents the domain **after** this change, not the design requiring the fewest edited lines.

State explicitly:

- what remains
- what changes responsibility
- what is generalized or merged
- what becomes obsolete and should be deleted
- what compatibility behavior, if any, temporarily remains and its retirement condition

If you choose the additive approach, say why it is genuinely coherent rather than merely cheaper.

## 5. For bugs: Root-Cause Gate

Before changing production behavior, write a compact reasoning checkpoint:

```text
SYMPTOM
  Exact observed failure.

HYPOTHESIS
  X causes Y because Z. Must be falsifiable.

MECHANISM
  The causal path from root condition to symptom.

CONFIRMING EVIDENCE
  Direct observations, not inference alone.

FALSIFICATION TEST
  What observation would prove this hypothesis wrong?

COMPETING CAUSES
  At least one plausible alternative when the evidence is not decisive.

FIX RATIONALE
  Why the proposed change removes/prevents the cause rather than hiding the symptom.

BLIND SPOTS
  What remains untested or uncertain?
```

Do not proceed with a production fix until the mechanism is understood well enough to explain why the fix works. If evidence is insufficient, reproduce, instrument, bisect, minimize, compare working/failing cases, or trace backwards first.

Prefer a failing regression test that captures the defect before fixing it when practical.

## 6. Define the change contract

Turn the reconstructed intent and architecture decision into a small contract.

```text
WHY
  The underlying problem/outcome.

OUTCOMES
  O-1 ... observable result
  O-2 ... observable result

INVARIANTS
  I-1 ... behavior/data/ownership property that must remain true

EXCLUSIONS
  X-1 ... work or behavior intentionally not changed

STRUCTURAL CONSEQUENCES
  Files/concepts/paths to move, merge, generalize, retire, or delete because of this change.

PROOF
  Tests, reproductions, walkthroughs, or measurements that demonstrate the outcomes and invariants.
```

A refactor required to make the new model coherent belongs in **STRUCTURAL CONSEQUENCES** and is therefore inside scope. This avoids the false choice between "no drive-by refactors" and "bolt another path on."

Before implementation, check:

> Could two competent engineers implement this contract independently and produce materially different behavior or architecture?

If yes because of an unresolved product judgment, clarify it. If yes only because of implementation details that do not matter, leave those to engineering judgment.

## 7. Plan goal-backward

Work backwards from the contract:

1. What must be true for each outcome?
2. What artifacts/state must exist for those truths?
3. What wiring/ownership relationships must connect them?
4. What existing artifacts become unnecessary?
5. Where is the design most likely to fail or fork into parallel behavior?

For cross-layer work, prefer a thin production-quality end-to-end tracer that proves the architecture before expanding it. Functionality can be incomplete in the tracer; the architectural path must be real.

For risky refactors, characterize existing behavior first. Preserve externally required behavior with tests/fixtures while changing internals.

## 8. Implement without plan-preservation bias

During implementation:

- Follow the contract, not the original wording of the prompt.
- Reuse healthy existing concepts; do not clone patterns merely because they exist.
- Prefer modifying the owning abstraction over creating a neighboring workaround.
- Remove superseded code as part of the same coherent change when safe.
- Keep temporary compatibility paths explicit and bounded.
- Keep tests close to changed behavior and invariants.

### Re-plan trigger

Stop implementation and return to the Architecture Reconciliation Gate if you discover:

- the chosen abstraction needs repeated exceptions
- you need a second source of truth
- a supposedly local change spreads unexpectedly
- a new wrapper exists only to avoid changing ownership
- a test can pass only by preserving contradictory behavior
- code inspection disproves a material assumption

Do **not** solve these discoveries by adding another patch to preserve the current plan.

## 9. Independent coherence review

After behavior works, run a separate review pass. Use a fresh subagent/context when the harness supports it; otherwise deliberately switch roles and reread the diff plus affected surrounding code.

The review is not "does it compile?" It asks whether the system now tells one coherent story.

Check:

- Does the implementation satisfy the underlying GOAL, not merely the literal prompt?
- Did any candidate mechanism accidentally become a requirement?
- Is there now more than one representation/path/source of truth for the same concept?
- Did we add a guard where an invariant should make the bad state impossible?
- Did we introduce an abstraction that mainly protects old architecture from change?
- What existing code became obsolete?
- Can any new code be deleted by changing/generalizing existing code instead?
- Are responsibilities and ownership clearer after the change?
- If we had known this requirement from day one, would this resulting architecture look reasonable?
- Can a future agent safely modify this area without knowing the historical sequence of patches?
- Are all structural consequences in the contract actually completed?
- Are there unrelated changes that should be reverted?

Do not reward deletion for its own sake. The criterion is conceptual simplicity and one coherent model.

If the review finds architectural accretion, fix it before declaring the task complete.

## 10. Verify and report

Verify:

- each O-N outcome
- each I-N invariant
- original bug reproduction, when applicable
- adjacent behavior affected by changed ownership/wiring
- regression suite/typecheck/lint/build as appropriate
- no unexpected side effects beyond the contract
- obsolete paths identified for deletion are actually gone, or have an explicit evidence-based retirement condition

Report completion in terms of:

1. **Intent satisfied** — what underlying goal is now true.
2. **Architecture decision** — why this model was chosen.
3. **Subtractive work** — what was removed/merged/simplified, or why none was appropriate.
4. **Evidence** — tests/reproductions/verification performed.
5. **Residual uncertainty/debt** — only concrete remaining items, not speculative cleanup.

---

# Fast path

For an explicit mechanical task, do this internally before editing:

```text
1. Intent: What observable outcome is actually requested?
2. Fit: Does the existing owning abstraction naturally support it?
3. Cause: If bug, do I know the mechanism rather than only the symptom?
4. Accretion: Am I about to add a parallel path/guard/helper instead of changing the owner?
5. Obsolescence: Will this make any existing code unnecessary?
```

All five have clean answers -> implement and verify without ceremony.

Any uncomfortable answer -> switch to the full workflow.

---

# Anti-patterns

Never:

- translate the user's brainstorming directly into a task list
- lock a solution merely because the user mentioned it first
- ask the user how the codebase works before reading it
- make "follow existing patterns" an unconditional rule
- create a compatibility wrapper with no removal condition
- accept passing tests as proof of correct architecture
- fix repeated symptoms with escalating guards
- preserve dead code "just in case"
- perform broad unrelated cleanup under the banner of coherence
- continue implementing after discovering the plan's model is wrong

# Core heuristic

When choosing between two valid implementations, prefer the one for which this statement is most true:

> After the change, a new engineer can understand the system from its present domain model without needing to know the historical sequence of feature requests and bug reports that produced it.
