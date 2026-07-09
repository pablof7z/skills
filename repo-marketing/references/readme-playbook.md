# README Reference Router

Use this file as the routing index for repo-marketing reference material.
Do not load every reference by default. Pick the files that match the task,
repo type, and adoption risks.

## Default Load Sets

README rewrite:

- `core-workflow.md`
- `scoring-and-output.md`
- Add the focused files below only when their trigger applies.

README audit:

- `core-workflow.md`
- `scoring-and-output.md`
- Add `trust-and-proof.md` when claims, safety, privacy, install behavior, or proof are weak.

Launch prep:

- `core-workflow.md`
- `repo-shape-and-launch.md`
- `scoring-and-output.md`

Skill catalog, MCP, plugin, command catalog, or agent-facing repo:

- `core-workflow.md`
- `agent-facing-and-catalogs.md`
- `activation-and-setup.md`
- `trust-and-proof.md` if it installs, registers, writes config, runs commands, or handles credentials.

Ambiguous or novel repo:

- `core-workflow.md`
- `archetypes.md`
- `scoring-and-output.md`

## Focused References

| File | Load when |
| --- | --- |
| `core-workflow.md` | Any README rewrite, audit, hook repair, positioning pass, or front-door copy pass. |
| `archetypes.md` | The repo type is unclear, multi-purpose, exploratory, research-oriented, template-like, local-first, or catalog-like. |
| `trust-and-proof.md` | The repo makes claims about speed, security, privacy, local-first behavior, maturity, compatibility, adoption, freshness, editions, provenance, locale/market fit, or sensitive data. |
| `activation-and-setup.md` | The repo has install paths, first-run constraints, modes, operating dials, reader lanes, demos, hosted/local paths, or build-vs-use confusion. |
| `agent-facing-and-catalogs.md` | The repo exposes skills, prompts, commands, MCP servers, plugins, agent tasks, broad tool catalogs, or prompt-native activation. |
| `repo-shape-and-launch.md` | The task asks for repo tree changes, launch readiness, demo assets, missing trust files, or root-directory recommendations. |
| `scoring-and-output.md` | The task needs a scorecard, final lint, rewrite checklist, prioritized changes, or output template. |

## Loading Rule

Start with the smallest load set that can answer the task. If a new risk appears
while inspecting the repo, load the relevant focused reference then. Do not read
all reference files just because they exist.
