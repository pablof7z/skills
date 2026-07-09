# Core README Workflow

Use for README rewrites, audits, hook repair, and front-door copy passes.

## What Strong READMEs Do

Strong repo READMEs behave like product pages with engineering receipts:

1. State the category plainly.
2. Name the audience or trigger situation.
3. Show a fast path to value.
4. Include proof near the first screen: screenshot, GIF, output, benchmark, demo, one-line integration snippet, or concrete example.
5. Convert features into user-visible outcomes.
6. Surface trust signals before readers have to ask: license, local/cloud behavior, tests, CI, package/release, credentials, telemetry, data writes.
7. Keep implementation details available but not first.
8. Make the root directory look maintained: docs, examples, tests, scripts, assets, CI, contributing, security, and agent instructions when relevant.

Weak repos often have enough technical content but fail to create a reason to care.

## Inspection Checklist

Before writing, identify:

- Project type: CLI, library, app, framework, agent skill, MCP server, dataset/list, template, research prototype, security/privacy tool.
- Adoption archetype: immediate utility, developer primitive, workflow accelerator, exploration companion, guardrail, integration bridge, skill catalog, reference catalog, local-first trust tool, template, research artifact.
- Primary audience: developers, agents, researchers, operators, founders, maintainers, privacy/security users, nontechnical users.
- Trigger situation: when would a reader reach for this?
- Pain or tension: what is slow, risky, unclear, annoying, expensive, or currently manual?
- Transformation: what changes after using it?
- Artifact/result: what does the user see, run, receive, inspect, or ship?
- Smallest impressive demo and shortest honest first-run path.
- Trust requirements: code reads, command execution, browser state, private data, files, credentials, telemetry, network calls.
- First-run gates: platform, host, hardware, runtime, account, API key, Docker/admin, edition, maturity, data boundary, legal boundary, locale/market boundary.
- Repo shape: docs, examples, assets, scripts, tests, CI, license, security policy, `AGENTS.md`, `CLAUDE.md`, `SKILL.md`, package/build files.

## Source Conflict Pass

Before writing, identify which evidence is current and which belongs to an older product era.

Check:

- README and README history
- CLI `--help`, package metadata, manifest descriptions, install scripts
- recently edited docs and specs
- examples, screenshots, demo assets, tests
- changelog, releases, CI, recent commits

When sources disagree, do not average them into one vague story. Prefer:

1. Current executable behavior and tests.
2. Current README and recent product docs.
3. Recently maintained examples or demos.
4. Package metadata and CLI descriptions.
5. Older planning docs, archived specs, and stale roadmaps.

Call out stale material as a follow-up recommendation when it affects adoption.

## Existing Hook Regression Check

Before rewriting, collect the best current material:

- strongest hook or tension line
- clearest one-sentence category description
- most convincing demo, screenshot, GIF, output sample, or example
- most honest trust boundary
- most memorable explanation of the problem
- clearest first-use path
- strongest differentiator

The rewrite must preserve, improve, or explicitly reject the best existing material. Do not flatten a strong hook into tidy but forgettable copy.

## Hook Research Protocol

Do not draft the first screen until the hook winner is selected.

Build a hook board:

| Candidate | Source | Reader recognition | Pain/tension | Artifact/result | Specificity | Trust/differentiation | Memorability |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |

Required passes:

1. Extract hooks from the current README, docs, examples, demos, screenshots, output samples, tests, commit messages, issue titles, product specs, and generated artifacts.
2. Run an independent hook pass: synthesize at least 3 hooks that could be found if the README title area did not exist.
3. Infer root pain: surface symptom, deeper frustration, stakes if nothing changes, desired transformation.
4. Generate at least 5 hook variants from root pain and strongest evidence-derived seeds.
5. Score the best existing hook against generated alternatives.
6. Keep the existing hook if it wins.

Good hooks name a situation, not just a category:

```txt
When an agent keeps guessing where logic lives...
When a repo is solid but nobody can tell why it matters...
Catch risky skills before an agent installs them.
```

## Default Alternative And Objection Inversion

Identify what the reader would otherwise use, ask, script, buy, or do manually.

Use a compact comparison only when the alternative affects adoption:

| Default path | What breaks | Why this repo changes the decision |
| --- | --- | --- |
| Ask a generic AI model | No repeatable evidence trail or decision discipline | This repo produces cited artifacts and reviewable steps |
| Manage providers by hand | Keys expire, bills surprise you, fallback logic scatters | One endpoint routes across providers with explicit cost/fallback behavior |

Do not dunk on vague competitors. Be specific about the failure mode.

## Marketing Brief

Build this before writing:

```md
Audience:
Trigger situation:
Pain/tension:
Transformation:
Artifact/result:
Failure mode prevented:
Root pain insight:
Default alternative:
Claim-proof map:
Freshness/edition ledger:
Locale/market boundary:
Task recipes:
Proof:
Trust objection:
Boundary:
Hook board:
```

## Copy Layers

Keep these separate:

- Human-facing hook: creates desire or recognition.
- README positioning: explains category, audience, value, and difference.
- Card/listing copy: short, clickable, outcome-first.
- Agent-router description: keyword-rich trigger metadata for skill/tool invocation.
- Detail paragraph: mechanism after interest exists.

Never reuse agent-router text as public marketing copy without rewriting it.

## Front-Door Copy

The first screen must answer:

1. What is this?
2. Who is it for?
3. When would I use it?
4. What changes after I use it?
5. How can I try it?
6. Why should I trust it?

Good front-door shapes:

```txt
[Project] helps [audience] do [job] when [trigger], producing [artifact] without [pain/default failure].
```

```txt
When [situation], use [project] to [transformation] without [failure mode].
```

Avoid hooks that start with generic verbs such as "facilitate", "leverage", "utilize", "streamline", or "enable robust".

## README Structure

Default order:

1. Title.
2. One-line positioning.
3. Hook or tension line.
4. Proof artifact.
5. Fastest honest activation path.
6. Fit/trust note if needed.
7. What you get.
8. Use cases or task recipes.
9. How it works.
10. Configuration.
11. Safety, trust, limitations.
12. Contributing and license.

Move backstage material out of the adoption funnel unless it helps a reader decide to try, trust, share, star, or contribute.

Do not dump file trees, current catalog inventories, authoring instructions, development checks, or internal maintenance notes into the public README by default.
