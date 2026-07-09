# Adoption Archetypes

Use when the repo type is unclear, multi-purpose, exploratory, research-oriented,
template-like, local-first, or catalog-like.

## Immediate Utility

The user wants a job done quickly.

Examples: CLI, converter, scraper, local app, browser extension, small automation.

Lead with:

```txt
Run this -> get this result -> avoid this pain.
```

## Developer Primitive

The user wants a reusable capability in their own code.

Examples: library, SDK, framework component, script tag, package.

Lead with:

```txt
Add this in one line -> unlock this behavior -> see this minimal example.
```

## Workflow Accelerator

The user has a recurring process with too many manual steps.

Examples: job search automation, release helper, issue triage, launch prep.

Lead with:

```txt
Replace this tedious workflow -> with this guided flow -> producing these artifacts.
```

## Sensemaking Or Exploration Companion

The user is entering an exploration where the problem, constraints, tradeoffs,
and boundaries are not yet sharp.

Examples: design exploration, research synthesis, architecture exploration,
strategy, product discovery, requirements shaping.

Lead with:

```txt
When a question turns into an exploration -> keep the session coherent -> surface options, boundaries, tensions, unknowns, and next decisions.
```

Do not force a fake promise of one-shot certainty. The value may be preserving
ambiguity, sharpening the problem, mapping tradeoffs, or making exploration legible.

## Guardrail Or Review Tool

The user fears a bad outcome.

Examples: security scanner, regression checker, prompt risk review, repo audit,
launch-readiness check.

Lead with:

```txt
Catch this failure mode before it ships -> show evidence -> recommend fixes.
```

## Integration Bridge

The user wants two systems to work together.

Examples: MCP server, API bridge, data connector, plugin, agent tool.

Lead with:

```txt
Connect X to Y -> expose these actions/data -> with these trust boundaries.
```

## Skill Catalog

The repo is a collection of skills, commands, prompts, or agent workflows.

Lead with:

```txt
Find the right skill for the job -> understand when to use it -> know what it produces.
```

Do not present a flat alphabetical table of names and dry descriptions as the
main experience.

## Reference Or Cookbook Catalog

The repo is a collection of examples, recipes, guides, prompts, design files,
patterns, or reusable reference material.

Lead with:

```txt
Pick the job you have -> copy or open the most relevant example -> adapt it safely.
```

Do not force a fake software install path. The first useful loop may be opening
one recipe, copying one artifact, running one notebook, or choosing from a
"start here" set.

Good catalog READMEs name:

- who the collection is for
- which problem to start with
- the first 3-7 examples worth trying
- what each example gives the reader
- how to verify an example is current, safe, or compatible
- where to request or contribute a missing recipe

## Local-First Trust Tool

The reader cares about data, credentials, wallets, code, identity, private
context, or autonomy.

Lead with:

```txt
Do the valuable thing locally -> state what never leaves the machine -> show how to audit it.
```

## Template Or Starter

The reader wants to begin from a known-good shape.

Lead with:

```txt
Start with this working baseline -> replace these parts -> avoid these setup mistakes.
```

Name whether the reader should clone, fork, use a template button, install a
package, or copy only one folder.

## Research Artifact

The reader wants to understand an idea, reproduce results, or inspect a method.

Lead with:

```txt
Here is the claim -> here is the evidence -> here is how to reproduce or inspect it.
```

Do not make research artifacts sound more production-ready than they are.
