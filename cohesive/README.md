# Cohesive skill

A one-file extraction of the OpenGSD ideas that are most relevant to preventing literal, additive, symptom-level coding-agent behavior.

## Install

Copy `SKILL.md` into the skill directory used by your coding harness, for example:

```text
.agents/skills/cohesive/SKILL.md
```

or, for a harness with a host-specific skill directory:

```text
.claude/skills/cohesive/SKILL.md
```

Then invoke it explicitly for a few sessions until you are satisfied with the behavior. If your harness supports automatic skill discovery, the frontmatter description is intended to make it trigger on ambiguous features, architecture evolution, and root-cause bug work.

## What was extracted

The design is synthesized from MIT-licensed OpenGSD material, primarily:

- `open-gsd/gsd-pi`: reflection-before-questioning, layered discussion, capability-vs-feature requirements, architecture gates, depth confirmation.
- `open-gsd/gsd-core`: assumptions mode, evidence/confidence/consequence surfacing, root-cause debugger checkpoint, goal-backward planning/checking, tracer-first architecture proof.
- `open-gsd/gsd-spec-build-loop`: discovery maps, facts-vs-decisions, outcome/exclusion contracts, separate build/review roles, human-owned product decisions.

This is not an official OpenGSD skill and does not require the GSD runtime.

## Deliberate deviations from GSD

The skill changes several OpenGSD defaults because they conflict with the specific failure mode it is meant to solve:

1. Existing code patterns are evidence, not automatically templates to copy.
2. User solution suggestions are not "locked decisions" until intent has been reconstructed or the user explicitly locks them.
3. "No drive-by refactors" is replaced with "no unrelated refactors": architecture reconciliation that is necessary for the requested outcome is explicitly brought into scope.
4. The build agent may not simply preserve existing architecture when a new requirement demonstrates that the architecture is now wrong.
5. A post-implementation coherence/deletion pass is mandatory for structural work.

## What was intentionally not extracted

No roadmap/milestone machinery, SQLite state, worktree orchestration, GitHub label state machine, scheduling, cloud daemon, browser automation, multi-session recovery protocol, or GSD-specific CLI is required.

The point is to get the cognitive discipline without buying into the harness.
