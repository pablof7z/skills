# Repo Shape And Launch Readiness

Use when the task asks for repo tree changes, launch readiness, demo assets,
missing trust files, or root-directory recommendations.

## Repo Shape Principles

The root directory is a trust surface. A maintained-looking repo earns trust
before the code is read.

Recommend tree changes separately from the README unless a structure detail
directly helps a reader try, trust, share, star, or contribute.

Do not paste a file tree into a README rewrite by default.

## Recommended Roots

For CLI/library/devtool repos:

```text
.
|-- README.md
|-- LICENSE
|-- SECURITY.md
|-- CHANGELOG.md
|-- docs/
|-- examples/
|-- scripts/
|-- tests/
|-- src/
`-- .github/workflows/
```

For agent-facing repos:

```text
.
|-- README.md
|-- AGENTS.md
|-- CLAUDE.md
|-- skills/
|   `-- <skill-name>/
|       |-- SKILL.md
|       |-- scripts/
|       |-- references/
|       `-- assets/
|-- examples/
|-- tests/
`-- .github/workflows/
```

For skill catalogs:

```text
.
|-- README.md
|-- LICENSE
|-- AGENTS.md
|-- docs/
|-- skills/
|-- examples/
|-- tests/
|-- scripts/
`-- assets/
```

## Missing Trust Files

Recommend:

- `SECURITY.md` for browser automation, credentials, local data, security scanning, wallets, identity, relays, or code execution.
- `AGENTS.md` for repos that expect coding agents to edit them.
- `CONTRIBUTING.md` when contributions are wanted.
- `CHANGELOG.md` when release stability or migration matters.
- `LICENSE` when missing.

## Demo Asset Plan

Every launch-ready README should have at least one proof artifact. Recommend:

- screenshot or GIF for UI/TUI/visual workflows
- terminal cast or output sample for CLIs
- before/after artifact for rewrite, generation, or transformation tools
- benchmark table for speed/scale claims
- sample report for audit/review/security tools
- minimal integration snippet for libraries and SDKs

For generated demos, include reproducibility notes when material: prompt,
pipeline, provider/tool path, cost, source assets, and whether generated media,
real footage, or hand-authored assets were used.

## Launch Prep Output

For launch prep, provide:

- README first screen
- demo asset plan
- announcement copy for GitHub, Hacker News, social posts, or relevant communities
- risk/trust copy
- repo hygiene checklist

## Backstage Material Gate

Move or collapse anything that delays activation without proving value or
reducing trust risk:

- badge walls
- sponsor blocks
- long tables of contents
- release-note banners
- personal-origin stories
- duplicated quick-start sections
- file trees or current-catalog inventories
- broad feature inventories before an example
- maintainer authoring docs
- development checks

Reject or move any README section that exists because the files exist, not
because it helps adoption.
