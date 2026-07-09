---
name: repo-marketing
description: Use when turning an open-source repository into a project people understand, want to try, trust, star, share, or contribute to. Applies to README rewrites, launch preparation, repo audits, skill catalogs, CLI/library/app/framework/MCP/template repos, agent-facing repos, and root-structure recommendations. Separates human-facing positioning from agent-router metadata and produces adoption copy, proof, quick starts, trust signals, and maintainable repo shape.
---

# Repo Marketing

## Goal

Turn a repository into a product-shaped open-source project: easy to understand, worth trying, credible enough to trust, and structured enough for humans or agents to extend.

The README is the launch surface. The root directory is the trust surface. The first screen must create a clear reader hypothesis:

```txt
I understand what this is.
This is for someone like me.
I know when I would use it.
I can see what I get.
I believe I can try it safely.
```

A structurally complete README with sterile copy is a failed output. Good repo marketing is not a section checklist. It is the translation of implementation into a compelling situation, tension, transformation, first-use path, and proof.

## Core Rule

Do not start by writing a README. First create the marketing brief.

Every repo, tool, skill, library, template, or catalog needs these fields:

```md
- Audience: who has the problem?
- Trigger situation: when would they reach for this?
- Current pain or tension: what is frustrating, slow, risky, unclear, or expensive now?
- Desired transformation: what changes after using it?
- Concrete artifact or result: what does the user see, run, receive, inspect, or ship?
- Failure mode prevented: what bad default does this avoid?
- Root pain insight: what deeper human problem explains why this repo should exist?
- Default alternative: what would the reader otherwise use, ask, script, copy, buy, or do manually?
- Claim-proof map: which evidence substantiates the major claims about speed, security, privacy, scale, compatibility, quality, maturity, or adoption?
- Freshness/edition ledger: which versions, release channels, editions, demos, catalog entries, and proof artifacts are current, archived, experimental, paid, stable, or reproducible?
- Locale/market boundary: which languages, countries, data sources, platforms, accounts, regulations, or regional defaults does the repo assume, and which parts are globally reusable?
- Task recipes: what real user intents, prompts, commands, inputs, or scenarios prove the repo's useful loop?
- Proof: what command, screenshot, GIF, output sample, benchmark, demo, example, or test proves it?
- Trust objection: what might make a reader hesitate?
- Boundary: what this does not promise.
- Hook board: existing hooks, evidence-derived hook seeds, generated alternatives, scores, and the winner.
```

Use the marketing brief to write. Do not let package metadata, implementation nouns, or internal skill descriptions become public copy by default.

## Workflow

1. Inspect the repo before writing.
   - Identify the project type: CLI, library, app, framework, agent skill, MCP server, dataset/list, template, research prototype, security/privacy tool.
   - Identify the adoption archetype: immediate utility, workflow accelerator, sensemaking/exploration companion, guardrail, integration bridge, template/starter, skill catalog, reference/cookbook catalog, research artifact, local-first trust tool, or developer infrastructure.
   - Identify the primary audience: developers, agents, researchers, operators, founders, maintainers, privacy/security users, nontechnical users, or another specific group.
   - Identify the smallest impressive demo and the shortest honest first-run path.
   - Identify the generated artifact or visible result.
   - Identify the first-run fit gate: hard platform, hardware, host, account, API key, model, runtime, Docker/admin, edition, maturity, data-boundary, or legal constraints that decide whether the reader can or should try it.
   - Identify operating modes and tradeoff dials: hosted/local, app/CLI/library, auto/manual install, fast/full scan, cheap/high-fidelity mode, model/provider choice, sandbox level, update behavior, or any knob that changes cost, latency, quality, safety, or ownership.
   - Identify the default alternative or obvious objection: what the reader is already doing, likely to try instead, or likely to ask ("why not just ...?").
   - Identify the install footprint and reversibility path: what files, configs, hooks, agent entries, services, credentials, caches, or local state are created, and how to inspect, skip, update, disable, or uninstall them.
   - Build a claim-proof map for major front-door claims: speed, scale, privacy, security, local-first, compatibility, AI quality, maturity, adoption, or production provenance.
   - Identify freshness, edition, and provenance boundaries when the repo is a living catalog, demo gallery, provider/tool matrix, benchmark set, prompt/archive repo, or multi-edition product. Distinguish current from archived, stable from canary/beta/experimental, free/open from paid/pro/hosted, and reproducible proof from badges or broad claims.
   - Identify locale and market boundaries when the repo depends on regional job boards, social platforms, government or finance sources, local package managers, account norms, language-specific prompts, or translated docs. Separate the universal core from local adapters before claiming broad applicability.
   - Check trust requirements: code reading, command execution, browser automation, credentials, private data, local/cloud behavior, file writes, wallets, keys, relays, signatures, identity material, telemetry, or network calls.
   - Check the root shape: docs, examples, assets, scripts, tests, CI, license, security policy, AGENTS.md, CLAUDE.md, SKILL.md, package/build files.
   - Resolve source conflicts before writing. Compare README, CLI help, package metadata, docs, examples, tests, recent commits, and shipped behavior. Prefer current executable behavior and recent product docs over stale planning docs or old metadata. Do not blend contradictory product eras into one promise.
   - Identify the strongest existing hook, line, demo, proof artifact, or explanation before rewriting. The final README must preserve it, improve it, or clearly explain why it was cut.
   - For agent-facing repos, identify the prompt-native activation path: the exact phrase, slash command, prompt, or agent instruction that starts the useful workflow after installation.
   - For agent-facing tools, command catalogs, and broad capability layers, identify task recipes: 3-7 realistic user intents mapped to the exact prompt, command, input, artifact, and expected result.
2. Build a marketing brief using the fields above.
3. Research and select the hook before drafting the README.
   - Extract hook candidates from the current README, docs, examples, demos, screenshots, output samples, tests, commit messages, issue titles, user complaints, product specs, and generated artifacts.
   - Run an independent hook pass: synthesize at least 3 hooks that could have been discovered if the current README title area did not exist, using docs, examples, demos, tests, issues, CLI help, product specs, and generated artifacts.
   - Infer the root pain before generating hooks: surface symptom, deeper frustration, stakes if nothing changes, and the desired transformation.
   - Generate new hook variants from the root pain and strongest evidence-derived seeds, not from artifact labels alone. Each serious candidate must point to the evidence that produced it.
   - Score the best existing hook against the generated alternatives for reader recognition, pain/tension, concrete artifact, specificity, trust/differentiation, and memorability.
   - Keep the existing hook when it wins. A rewrite does not need a new hook; it needs the strongest hook.
   - Do not draft the first screen until the hook winner is selected.
4. Generate multiple positioning candidates before choosing one.
   - At least 5 hooks.
   - At least 3 one-line positioning statements.
   - At least 3 first-screen structures if the repo is ambiguous or novel.
   - If different readers need different activation paths, define reader lanes such as "for agents", "for developers", "for operators", or "for humans". Each lane must contain a different first-use path or decision trigger, not just a different label.
   - If there are multiple ways in, build an activation ladder: zero-install demo or hosted trial, fastest install/release binary, first useful local command, integration path, then build-from-source/development. Put build instructions before the try path only when building is genuinely the primary way to use the repo.
5. Separate copy layers:
   - Human-facing hook: creates desire or recognition.
   - README positioning: explains category, audience, value, and difference.
   - Card/listing copy: short, clickable, outcome-first.
   - Agent-router description: keyword-rich instructions for when to invoke a skill/tool.
   - Detail paragraph: explains mechanism after interest exists.
6. Rewrite or evaluate the first screen first. It must answer what it is, who it is for, when to use it, what changes, how to try it, and why it is credible.
7. Build one default golden path before describing architecture. Include commands and expected output.
8. Move detailed internals, configuration matrices, background, and citations below the proof and first-run path.
9. Surface trust early when the repo touches sensitive data, credentials, local files, browser sessions, code execution, security workflows, or identity material. Put the concrete trust boundary beside the first runnable path, not only in a later security section.
10. Recommend repo-tree changes that make the project look maintained and make agent work predictable.
11. Run the final marketing lint before output.

Read `references/readme-playbook.md` as the reference router when rewriting a README, auditing a repo, scoring README quality, creating a skill-catalog README, or recommending launch-readiness changes. Follow its load sets and read only the task-relevant reference files. Do not load all files under `references/` by default.

## Adoption Archetypes

Classify the repo before writing. Different repo types need different marketing.

### Immediate Utility

The user wants a job done quickly.

Examples: CLI, converter, scraper, local app, browser extension, small automation.

Lead with:

```txt
Run this → get this result → avoid this pain.
```

### Developer Primitive

The user wants a reusable capability in their own code.

Examples: library, SDK, framework component, script tag, package.

Lead with:

```txt
Add this in one line → unlock this behavior → see this minimal example.
```

### Workflow Accelerator

The user has a recurring process with too many manual steps.

Examples: job search automation, release helper, issue triage, launch prep.

Lead with:

```txt
Replace this tedious workflow → with this guided flow → producing these artifacts.
```

### Sensemaking or Exploration Companion

The user is not just asking for an answer. They are entering a collaborative exploration where the problem, constraints, tradeoffs, and boundaries are not yet sharp.

Examples: design exploration, research synthesis, architecture exploration, strategy, product discovery, requirements shaping.

Lead with:

```txt
When a question turns into an exploration → keep the session coherent → surface options, boundaries, tensions, unknowns, and next decisions.
```

Do not force a fake promise of one-shot certainty. The value may be preserving ambiguity, sharpening the problem, mapping tradeoffs, or making exploration legible.

### Guardrail or Review Tool

The user fears a bad outcome.

Examples: security scanner, regression checker, prompt risk review, repo audit, launch-readiness check.

Lead with:

```txt
Catch this failure mode before it ships → show evidence → recommend fixes.
```

### Integration Bridge

The user wants two systems to work together.

Examples: MCP server, API bridge, data connector, plugin, agent tool.

Lead with:

```txt
Connect X to Y → expose these actions/data → with these trust boundaries.
```

### Skill Catalog

The repo is a collection of skills, commands, prompts, or agent workflows.

Lead with:

```txt
Find the right skill for the job → understand when to use it → know what it produces.
```

Do not present a flat alphabetical table of names and dry descriptions as the main experience.

### Reference or Cookbook Catalog

The repo is a collection of examples, recipes, guides, prompts, design files, patterns, or reusable reference material.

Lead with:

```txt
Pick the job you have -> copy or open the most relevant example -> adapt it safely.
```

Do not force a fake software install path. The first useful loop may be opening one recipe, copying one artifact, running one notebook, or choosing from a "start here" set.

Good catalog READMEs name:

- who the collection is for
- which problem to start with
- the first 3-7 examples worth trying
- what each example gives the reader
- how to verify an example is current, safe, or compatible
- where to request or contribute a missing recipe

### Local-First Trust Tool

The reader cares about data, credentials, wallets, code, identity, private context, or autonomy.

Lead with:

```txt
Do the valuable thing locally → state what never leaves the machine → show how to audit it.
```

## Above-the-Fold Contract

The first screen of a marketable README should contain:

- Project name.
- One-line positioning statement.
- A human-facing hook or tension statement.
- Proof artifact: screenshot, GIF, terminal cast, output sample, benchmark, architecture thumbnail, or real example.
- One installation or activation path.
- One sentence naming the audience.
- One sentence naming what is different, easier, safer, sharper, or less painful than the old workflow.

Do not open with philosophy, roadmap, academic background, contributor policy, giant tables, or internal architecture unless the repo is purely reference material.

## Human Copy vs Router Copy

Never reuse agent-router text as public marketing copy without rewriting it.

### Human-facing copy

Purpose: make a person want to click, install, star, share, or continue reading.

It should contain at least two of:

- recognizable situation
- pain or tension
- concrete outcome
- visible artifact
- failure mode prevented
- trust advantage
- speed or simplicity
- surprising capability

### Agent-router copy

Purpose: help an agent decide when to invoke a skill or tool.

It can be procedural, keyword-rich, and explicit about conditions.

### Detail copy

Purpose: explain how the repo works after the reader is interested.

This is where implementation nouns, detailed capabilities, and internal method language can appear.

## Non-Negotiables

- Public copy must sell outcomes, not procedures.
- Position before explaining. A visitor should know what the project does by line 5.
- Pain, tension, or trigger situation before features. Features without context are inventory.
- Install before architecture. Architecture is for convinced readers.
- Show a working loop: run this, see that.
- Use proof, not adjectives. Prefer screenshots, benchmarks, supported platforms, tests, real output, package stats, or examples over claims.
- Match proof to claim. Performance claims need measurements; privacy/security claims need boundaries, audits, threat details, or reproducible-build/signing evidence; compatibility claims need tested platforms or matrices; scale/adoption claims need real usage, production provenance, or package stats; AI quality claims need sample outputs, evals, or review loops; maturity claims need release channel and stability language.
- For fast-moving catalogs, AI/tooling matrices, prompt/archive repos, benchmark/demo galleries, and multi-edition products, include a freshness, edition, and provenance ledger. State what is current, archived, experimental, beta/canary/stable, free/open, paid/pro/hosted, planned, or reproducible; badges alone do not prove freshness.
- For locale-specific or market-specific repos, state the boundary instead of overclaiming global fit. Split global core workflow from regional adapters, name required languages/platform accounts, and show translated or native-language activation only when it is part of real use.
- Use examples as marketing. A good example is a miniature demo.
- Name objections early: local/cloud, API keys, data storage, file writes, Docker, telemetry, and supported platforms.
- Use trust adjacency for risky first runs. If the first command or demo touches code, local files, browser state, cloud APIs, secrets, Docker, private data, wallets, relays, security targets, or identity material, place a short trust boundary directly beside that command.
- For installers, MCP servers, agent skills, plugins, hooks, CLIs, browser tools, or local apps that modify user state, include the install footprint and reversibility path near setup: what changes, where state lives, how to inspect or dry-run when available, how to update, disable, or uninstall.
- Add a first-run fit gate when prerequisites or disqualifiers affect adoption. Name platform, host, hardware, runtime, account/API key, Docker/admin permissions, local/cloud mode, edition limits, preview status, legal constraints, or prohibited-use boundaries before the reader invests in setup.
- Segment activation by reader path when the repo serves materially different readers. Agent-facing repos often need an agent install/invocation lane and a human/developer lane; each lane must show a first useful loop.
- For agent-facing repos, include prompt-native activation when it exists. Show the exact phrase, slash command, or prompt the reader gives the agent, what the agent should do next, and any permissions or trust boundary needed before that prompt is safe.
- For agent-facing tools, command catalogs, and broad capability layers, include a task recipe bank when one command is not enough to teach use. Map real user intents to exact prompts or commands, the input they need, the artifact/result produced, and how the reader verifies success. Do not let a command inventory substitute for this.
- Use an activation ladder when there are multiple entry paths. Separate try, install, integrate, and build-from-source paths so development setup does not crowd out the fastest way to see value.
- For tools with meaningful operating modes, add a compact mode/tradeoff table before broad feature lists. Show when to use each mode and what it changes: speed, cost, fidelity, token/context use, update behavior, isolation, data boundary, or required credentials.
- Run an interruption audit before finalizing the README. Move or collapse anything that delays the first useful loop without proving value or reducing trust risk: sponsor blocks, long tables of contents, changelog banners, personal stories, badge walls, and internal inventories.
- Keep maintainer material out of the README funnel unless it directly helps a reader decide to try, trust, share, star, or contribute to the project.
- Do not dump file trees, "current catalog" inventories, authoring instructions, development checks, or internal maintenance notes into a README rewrite by default.
- Recommend agent affordances and repo-tree fixes separately from the public README unless they remove a concrete adoption or trust objection.
- Do not merge conflicting source eras. If package metadata, CLI help, docs, examples, and current README disagree, pick the source of truth deliberately and call out stale material as a follow-up fix.
- Do not flatten a strong existing hook into tidy but forgettable adoption copy. A rewrite that is clearer but less compelling has regressed.
- Research the hook before writing the README. The hook must survive competition against existing copy and evidence-derived alternatives.
- Existing hooks are competitors, not the limit of the search. Always synthesize non-README hook candidates from deeper repo evidence before choosing the winner.
- Synthesize hooks from root pain, not from artifact categories. "Turns sessions into memory" is usually a description; the hook is the human problem that makes that artifact desirable.
- When a repo displaces an obvious workaround, competitor, hosted service, manual process, or generic AI prompt, include a default-alternative comparison. Name the old path, what breaks about it, and why this repo changes the decision.
- Never start with corporate archaeology. Background and acknowledgements come after activation.
- Do not flatten exploratory, creative, strategic, or design tools into simplistic “produce final answer” copy. Some repos are valuable because they keep uncertainty visible and useful.
- Generate multiple hook variants before selecting one.
- Run the copy-quality rubric before final output.

## Banned Front-Door Language

Avoid these in hooks, taglines, cards, skill tables, and first-screen README copy unless quoting existing text or explaining why it is weak:

```txt
facilitate
leverage
enable robust
seamless
comprehensive
powerful
next-generation
advanced
intelligent
streamline
workflow optimization
structured approach
enhance productivity
improve efficiency
utilize
capabilities
solution
```

Also avoid leading with internal method terms. If a term is useful inside the repo, translate it for the front door.

## Output Shapes

For a README rewrite, provide:

- Revised `README.md` content or patch.
- A short marketing brief showing the extracted audience, trigger situation, transformation, artifact, proof, and objection.
- A hook board when the hook changed or when multiple plausible hooks competed: existing best hook, independently synthesized non-README alternatives, scores, evidence sources, and why the winner won.
- A freshness/edition/provenance ledger when time, release channel, edition split, demo reproducibility, or catalog currency affects trust.
- A locale/market boundary when language, geography, regional platforms, or country-specific data sources affect adoption.
- A task recipe bank for agent-facing tools or command catalogs: user intent, exact invocation, expected result, and verification signal.
- Suggested repo tree changes only as follow-up recommendations, not as automatic README content.
- Missing trust/safety files.
- Suggested demo, screenshot, GIF, or asset list.
- Optional `AGENTS.md` stub if the repo is agent-facing.

For an audit, provide:

- A 0-3 score for positioning, first-run path, proof, structure, trust, agent readiness, and copy quality.
- Findings ordered by adoption impact.
- P0/P1/P2 changes.
- Specific file-level recommendations.
- A replacement first screen when the current one is weak.

For a skill catalog README, provide:

- Collection-level positioning.
- Installation/use instructions.
- A “best skills to try first” section.
- Skills grouped by user job, pain, or session type.
- For each skill: human hook, use-when trigger, concrete output, and optional rename suggestion.
- A note separating human-facing descriptions from agent-router metadata.

For launch prep, provide:

- README first screen.
- Demo asset plan.
- Announcement copy for GitHub, Hacker News, social posts, or relevant community channels.
- Risk/trust copy.
- Repo hygiene checklist.

## Strong Defaults

Use clear, direct language:

```txt
Run this.
You should see this.
This writes files here.
This requires these keys.
This does not upload your code.
Use it when...
It gives you...
It prevents...
```

Prefer copy that names a situation:

```txt
When a prompt turns into a real design session...
When an agent keeps guessing where logic lives...
When a release has too many hidden manual steps...
When a repo is technically solid but nobody can tell why it matters...
```

Avoid empty adjectives and vague enterprise copy:

```txt
Robust, flexible, next-generation, powerful, revolutionary, seamless.
```
