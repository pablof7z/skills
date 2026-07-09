# Scoring And Output

Use when the task needs a scorecard, final lint, rewrite checklist, prioritized
changes, or output template.

## README Scoring Rubric

Score each category from 0 to 3.

| Category | 0 | 1 | 2 | 3 |
| --- | --- | --- | --- | --- |
| Positioning | Cannot tell what it is | Category clear, value vague | Clear category and audience | Clear category, audience, trigger, pain, differentiated promise |
| First-run path | None | Buried or incomplete | Works for normal user | Produces visible value quickly or shortest honest equivalent |
| Proof | Only claims | Badges or weak screenshots | Demo, example, output, benchmark | Demo plus numbers, real output, reproducible example, or credible trust evidence |
| Structure | Wall of text | Basic headings | Good order | Excellent scanning and progressive disclosure |
| Trust | No trust info | Mentions license | Covers basic install/data behavior | Clear trust model, data flow, local/cloud behavior, limitations |
| Agent readiness | No agent info | Mentions agents | Has agent docs/tests/structure | Agent instructions, fixtures, tests, safe edit boundaries |
| Copy quality | Generic inventory | Understandable but dull | Concrete and human-facing | Memorable, specific, situation-aware, differentiated |

## Copy Quality Rubric

Score each important hook, tagline, card, and table row from 0 to 3.

- Pain or tension clarity: no pain -> implied -> clear -> immediately recognizable.
- Outcome clarity: vague process -> abstract benefit -> concrete result -> concrete result plus why it matters.
- Specificity: generic sludge -> domain nouns -> concrete tasks/artifacts -> tasks, artifacts, and failure modes.
- Human appeal: bureaucratic -> understandable but dull -> useful-sounding -> clickable or memorable.
- Agent routing: unclear -> broad trigger -> clear use cases -> use cases plus boundaries.
- Anti-jargon: packed with internal terms -> some jargon -> mostly plain -> plain with technical precision.

Any front-door copy scoring below 2 in pain/tension clarity, outcome clarity, or
human appeal must be rewritten.

## Final Marketing Lint

Reject and rewrite front-door copy that:

- describes internal process instead of user-visible value
- starts with "capture", "enable", "facilitate", "leverage", "utilize", or "streamline"
- contains more than two abstract nouns in a row
- uses a capability list as the main description
- fails to name a pain, tension, trigger situation, or failure mode
- fails to say what artifact, result, or change the user gets
- uses agent-router text as public marketing text
- sounds like a Jira ticket title
- sounds like a compliance policy
- promises a final answer when the repo supports exploration, sensemaking, or human judgment
- hides trust issues below the fold when sensitive data, credentials, code execution, or private context are involved

## Rewrite Checklist

Before finalizing a README, verify:

- The marketing brief is present or was implicitly used.
- The first screen says what the project does.
- The first screen names when someone would use it.
- The user can try it without reading architecture.
- The README names a painful workflow, unclear situation, trust risk, or failure mode.
- If there is an obvious default alternative, the README explains why this repo beats it, differs from it, or is not for that path.
- There is at least one concrete example.
- Installation is copy-pastable.
- The expected result is described.
- Hard first-run fit constraints are visible before or beside setup.
- Meaningful modes or dials are explained with trigger and tradeoff.
- Fast-moving catalogs, demo galleries, provider matrices, and multi-edition products show freshness, provenance, and edition/channel state.
- Locale-specific and market-specific repos split universal workflow from regional adapters.
- Agent-facing tools, command catalogs, and broad capability layers include task recipes.
- The generated artifact/result is explicit.
- Trust/security behavior is explicit.
- Major claims have matching proof.
- Installers and agent-registration flows explain footprint, update, disable/uninstall, and safe/dry-run options.
- Repo-structure detail included in the README directly supports trying, trusting, or contributing.
- Contribution path is present if contributions are wanted.
- License is present.
- Claims are specific enough to audit.
- Hook board includes a non-README candidate synthesized from concrete repo evidence.
- Public hooks are not reused router descriptions.
- Exploratory tools are not forced into fake one-shot certainty.
- The README does not start with internal history.

## Prioritized Changes

P0:

- Add a one-line value proposition directly under the title.
- Add a human-facing hook that names trigger, pain, or transformation.
- Add a hero screenshot, GIF, terminal cast, output sample, or benchmark.
- Add a single quick-start command block with expected output.
- Add a "What you get" section if the repo produces artifacts.
- Add `AGENTS.md` if the repo targets coding agents.
- Add `SECURITY.md` for browser automation, local data, credentials, or security workflows.

P1:

- Add `examples/` with one minimal and one realistic example.
- Add `docs/configuration.md` and move advanced knobs out of the main funnel.
- Add real release, CI, license, package, or download badges.
- Add a short "How it works" section.
- Add template usage notes for templates.
- Add skill catalog grouping by user job if this is a skill collection.

P2:

- Add FAQ or common questions.
- Add contribution map or good-first-issue notes.
- Add selective social proof.
- Add host-specific install snippets for agent hosts.
- Add a docs site only after the GitHub README is already strong.

## Output Templates

README rewrite:

```md
## Marketing Brief

Audience:
Trigger situation:
Pain/tension:
Transformation:
Artifact/result:
Proof:
Trust objection:
Claim-proof map:
Freshness/edition ledger:
Locale/market boundary:
Task recipes:

## Revised README

[README content]

## Repo Shape Recommendations

P0:
P1:
P2:

## Demo Asset Plan

- Screenshot/GIF:
- Output sample:
- Example scenario:

## Missing Trust Files

- SECURITY.md:
- AGENTS.md:
- CONTRIBUTING.md:
```

Audit:

```md
## Scorecard

| Category | Score | Finding |
|---|---:|---|
| Positioning | /3 | |
| First-run path | /3 | |
| Proof | /3 | |
| Structure | /3 | |
| Trust | /3 | |
| Agent readiness | /3 | |
| Copy quality | /3 | |

## Highest-impact fixes

1. ...
2. ...
3. ...

## Replacement first screen

[content]
```

Skill catalog:

```md
## Collection Positioning

[one-line promise]

## Best Skills to Try First

| Skill | Use it when | What it gives you |
|---|---|---|

## Skills by Job

### [Group]

| Skill | Use it when | What it gives you |
|---|---|---|

## Router Metadata Notes

The public README copy should be more human-facing than the `SKILL.md` descriptions.
```
