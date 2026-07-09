---
name: repo-marketing
description: Improve open-source GitHub repository positioning, README quality, launch readiness, and root structure. Use when creating, rewriting, or auditing README.md; preparing a repo for Product Hunt, Hacker News, GitHub Trending, grants, or funding review; making a CLI, library, app, MCP server, framework, template, or agent skill easier to try and trust; or adding agent-facing repo affordances such as AGENTS.md, SKILL.md, examples, docs, scripts, and safety files.
---

# Repo Marketing

## Goal

Turn a repository into a product-shaped open-source project: easy to understand, easy to try, easy to trust, and easy for humans or agents to extend.

Treat the README as the launch surface and the root directory as the trust surface. The README should create belief before it explains internals.

## Workflow

1. Inspect the repo before writing:
   - Identify the project type: CLI, library, app, framework, agent skill, MCP server, dataset/list, template, research prototype, security/privacy tool.
   - Identify the primary audience: developers, agents, researchers, operators, founders, privacy/security users, or nontechnical users.
   - Identify the smallest impressive demo and the shortest honest first-run path.
   - Check trust requirements: code reading, command execution, browser automation, credentials, private data, local/cloud behavior, file writes, wallets, keys, relays, signatures, or identity material.
   - Check the root shape: docs, examples, assets, scripts, tests, CI, license, security policy, AGENTS.md, CLAUDE.md, SKILL.md, package/build files.
2. Rewrite or evaluate the first screen first. It must answer what it is, who it is for, why it matters, how to try it, and why it is credible.
3. Build one default golden path before describing architecture. Include commands and expected output.
4. Move detailed internals, configuration matrices, background, and citations below the proof and first-run path.
5. Surface trust early when the repo touches sensitive data, credentials, local files, browser sessions, code execution, security workflows, or identity material.
6. Recommend repo-tree changes that make the project look maintained and make agent work predictable.
7. Return concrete artifacts: rewritten README content or patch, scorecard, missing files, suggested visual assets, and priority changes.

Read `references/readme-playbook.md` when rewriting a README, auditing a repo, scoring README quality, or recommending launch-readiness changes.

## Above-the-Fold Contract

The first screen of a marketable README should contain:

- Project name.
- One-line positioning statement.
- Proof artifact: screenshot, GIF, terminal cast, output sample, benchmark, architecture thumbnail, or real example.
- One installation or activation path.
- One sentence naming the audience.
- One sentence naming what is different or less painful than the old workflow.

Do not open with philosophy, roadmap, academic background, contributor policy, giant tables, or internal architecture unless the repo is purely reference material.

## Non-Negotiables

- Position before explaining. A visitor should know what the project does by line 5.
- Pain before features. Features without a named pain are inventory.
- Install before architecture. Architecture is for convinced readers.
- Show a working loop: run this, see that.
- Use proof, not adjectives. Prefer screenshots, benchmarks, supported platforms, tests, real output, package stats, or examples over "powerful" claims.
- Use examples as marketing. A good example is a miniature demo.
- Name objections early: local/cloud, API keys, data storage, file writes, Docker, telemetry, and supported platforms.
- Add agent affordances when agent-facing: AGENTS.md, SKILL.md, CLAUDE.md or equivalent, command docs, examples, fixtures, tests, and clear file trees.
- Keep the root directory legible. A maintained-looking repo earns trust before the code is read.
- Never start with corporate archaeology. Background and acknowledgements come after activation.

## Output Shapes

For a README rewrite, provide:

- The revised `README.md` content or patch.
- Suggested repo tree changes.
- Missing trust/safety files.
- Suggested demo, screenshot, GIF, or asset list.
- Optional `AGENTS.md` stub if the repo is agent-facing.

For an audit, provide:

- A 0-3 score for positioning, first-run path, proof, structure, trust, and agent readiness.
- Findings ordered by adoption impact.
- P0/P1/P2 changes.
- Specific file-level recommendations.

## Strong Defaults

Use clear, direct language:

```txt
Run this.
You should see this.
This writes files here.
This requires these keys.
This does not upload your code.
```

Avoid empty adjectives and vague enterprise copy:

```txt
Robust, flexible, next-generation, powerful, revolutionary, seamless.
```
