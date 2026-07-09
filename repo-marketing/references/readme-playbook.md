# README and Repo Marketing Playbook

Use this reference for README rewrites, repo audits, launch-readiness passes, and agent-facing repo structure recommendations.

## Inspection Checklist

Before writing, identify:

1. Project type:
   - CLI
   - library
   - app
   - framework
   - agent skill
   - MCP server
   - dataset/list
   - template
   - research prototype
   - security/privacy tool
2. Primary audience:
   - developers
   - agents
   - researchers
   - operators
   - founders
   - privacy/security users
   - nontechnical users
3. Main promise:
   - What painful workflow does this replace?
   - What can the user do after installing it?
   - What is the smallest impressive demo?
4. Trust requirements:
   - Does it read code?
   - Does it execute commands?
   - Does it touch tokens, browser cookies, wallets, private data, network requests, or credentials?
   - Does it run locally or use a cloud service?
   - Does it write files or modify agent config?
5. Current repo shape:
   - Is there a clear source directory?
   - Are tests visible?
   - Is there a docs folder?
   - Are examples present?
   - Are install scripts present?
   - Is there `AGENTS.md`, `CLAUDE.md`, or `SKILL.md` for agent-facing repos?

## README Structure

Use this order unless the repo has a strong reason not to:

```md
# Project Name

One-line positioning statement:
[What it is] for [who] that [does valuable thing] without [old pain].

[Hero image / GIF / terminal demo / architecture thumbnail]

Badges: release, package, CI, license, stars, downloads. No badge soup.

## Why this exists

Name the painful current workflow.
Show 3-7 concrete examples.
State the unlock.

## Quick Start

One command or the shortest possible path.
Then state what should happen after running it.

## Features

Outcome-first bullets. Not implementation-first bullets.

## Use Cases

Show who uses it and for what.
Commands/examples beat prose.

## How it works

Small architecture explanation.
Mention major modules only after the user understands the value.

## Configuration

Env vars, keys, local paths, permissions, data storage.

## Project Structure

Tree with comments.

## Safety / Trust / Limitations

Local/cloud behavior, security posture, threat model, telemetry, data retention, known limitations.

## Development

Clone, install, test, lint, release.

## Contributing

How to propose issues/PRs.

## License
```

Hard rule: the README should create a dopamine hit before it produces a dependency graph.

## Positioning

Use one of these shapes:

```txt
[Project] is a [category] for [audience] that [valuable outcome] without [old pain].
Use [project] to [high-value outcome] without [major pain].
[Project] gives [audience] a way to [specific result] in [time/few steps].
```

Examples:

```txt
A local-first CLI that turns any folder into searchable agent memory without sending code to the cloud.
A browser-side agent library that lets users control your web app in natural language with one script tag.
Fork once, fill in your profile, and let an agent score jobs, tailor CVs, write cover letters, and prepare interview notes.
```

Avoid empty adjectives: powerful, next-generation, revolutionary, robust, seamless.

## Hero Proof

Add at least one of:

- GIF
- screenshot
- terminal recording
- short architecture diagram
- before/after image
- benchmark table
- generated output example
- one-line integration snippet

If the project has a UI, TUI, visual output, workflow, or generated artifact, include visual proof above the fold.

## Quick Start

Create one golden path.

It must:

- Work on the default host or platform.
- Show the shortest install flow.
- Show the first useful command.
- Show the expected result.
- Defer edge cases to later sections.

Prefer command blocks like:

```bash
curl -fsSL https://example.com/install.sh | sh
tool init
tool demo
```

Then state the expected result:

```txt
You should see a local dashboard at http://localhost:3000 and a sample report in ./runs/latest.md.
```

For risky install behavior, include an audit path:

```bash
curl -fsSL https://example.com/install.sh -o install.sh
less install.sh
sh install.sh
```

## Features

Write outcome-first bullets.

Weak:

```md
- SQLite backend
- AST parser
- YAML config
```

Better:

```md
- Persistent local memory: survives agent restarts and stores decisions in SQLite.
- Structural code search: finds functions, routes, classes, and call chains without dumping entire files into context.
- Plain YAML config: review and edit all behavior without a UI.
```

Each feature should answer "so what?"

## Use Cases

Use cases should be concrete:

```md
## Use Cases

- Before editing a new repo: generate a map of entry points and risky files.
- During code review: ask what modules a change can affect.
- During incident response: trace an HTTP route to database writes.
- For onboarding: produce a 5-minute architecture brief.
```

Commands and examples beat prose.

## How It Works

Only after Quick Start and use cases, explain architecture:

```md
1. Index: parses source files into symbols, imports, routes, and call edges.
2. Store: writes the graph to local SQLite.
3. Query: exposes search and trace tools over MCP.
4. Update: watches git changes and refreshes stale nodes.
```

For deeper material, link to `docs/architecture.md`.

## Configuration

Include:

- environment variables
- config file path
- default data directory
- API keys
- permissions
- network behavior
- local/cloud mode
- generated files

Use a table when there are more than five settings.

## Project Structure

Always include this for complex repos and agent-facing repos:

```text
.
|-- src/              # main implementation
|-- tests/            # unit and integration tests
|-- examples/         # runnable examples
|-- docs/             # long-form docs
|-- scripts/          # install, release, and maintenance scripts
|-- AGENTS.md         # instructions for coding agents
`-- README.md
```

Comment every important folder.

## Trust, Safety, and Limitations

Required for any repo that:

- reads private code
- touches credentials
- runs shell commands
- controls a browser
- scans security issues
- modifies configs
- handles personal data
- interacts with Bitcoin/Nostr keys, wallets, relays, signatures, or identity material

Include:

```md
## Security and Privacy

- Runs locally by default.
- Does not upload source code.
- Stores config at ...
- Reads credentials from ...
- Writes generated files to ...
- Network calls are limited to ...
- Known limitations: ...
```

Do not make unverifiable trust claims.

## Recommended Repo Structures

For CLI/library/devtool repos:

```text
.
|-- README.md
|-- LICENSE
|-- CHANGELOG.md
|-- CONTRIBUTING.md
|-- SECURITY.md
|-- AGENTS.md
|-- docs/
|-- examples/
|-- assets/
|-- scripts/
|-- src/ or <package>/
|-- tests/
|-- .github/workflows/
|-- .env.example
|-- pyproject.toml / package.json / Cargo.toml / CMakeLists.txt
`-- Makefile / justfile
```

For agent-skill repos:

```text
.
|-- README.md
|-- LICENSE
|-- CHANGELOG.md
|-- AGENTS.md
|-- CLAUDE.md
|-- skills/
|   `-- <skill-name>/
|       |-- SKILL.md
|       |-- scripts/
|       `-- docs/
|-- .claude/
|   |-- commands/
|   `-- settings.json
|-- .agents/skills/
|-- docs/
|-- tests/
|-- fixtures/
`-- scripts/
```

For freedom-tech, security, or privacy projects, put trust model, local/cloud behavior, telemetry, reproducible-build status, key handling, and threat assumptions in the README. Do not bury that in docs.

## README Scoring Rubric

Score each category from 0 to 3.

### Positioning

0: Cannot tell what it is.
1: Category is clear, value is vague.
2: Clear category and audience.
3: Clear category, audience, pain, and differentiated promise.

### First-Run Path

0: No install or usage path.
1: Install exists but is buried or incomplete.
2: Quick Start works for a normal user.
3: Quick Start produces visible value in under two minutes.

### Proof

0: Only claims.
1: Some badges or screenshots.
2: Demo, example, or benchmark.
3: Demo plus numbers, screenshots, real output, or credible trust evidence.

### Structure

0: Wall of text.
1: Basic headings.
2: Good order: why, install, features, usage, docs.
3: Excellent scanning, examples, table of contents if needed, project tree.

### Trust

0: No license/security/privacy info.
1: License only.
2: Mentions security/privacy/config behavior.
3: Clear trust model, data flow, local/cloud behavior, limitations, and contribution rules.

### Agent Readiness

0: No agent instructions.
1: README is understandable but no agent files.
2: Has `AGENTS.md`, docs, tests, and clear structure.
3: Has agent instructions, skill/command docs, fixtures, tests, and safe edit boundaries.

## Rewrite Checklist

Before finalizing a README, verify:

- The first screen says what the project does.
- The user can try it without reading architecture.
- The README names a painful old workflow.
- There is at least one concrete example.
- Installation is copy-pastable.
- The expected result is described.
- Trust/security behavior is explicit.
- The repo tree is understandable.
- Contribution path is present.
- License is present.
- Claims are specific enough to be audited.
- The README does not start with internal history.

## Prioritized Changes

P0:

- Add a one-line value proposition directly under the title.
- Add a hero screenshot, GIF, terminal cast, output sample, or benchmark.
- Add a single quick-start command block with expected output.
- Add `AGENTS.md` if the repo targets coding agents.
- Add `SECURITY.md` for browser automation, local data, credentials, or security workflows.

P1:

- Add `examples/` with one minimal and one realistic example.
- Add `docs/configuration.md` and move advanced knobs out of the main funnel.
- Add real release, CI, license, package, or download badges.
- Add a short "How it works" section.
- Add "Use this template" or "Do not clone directly" notes for templates.

P2:

- Add FAQ or common questions.
- Add contribution map or good-first-issue notes.
- Add selective social proof.
- Add host-specific install snippets for Claude, Codex, Cursor, Gemini, and similar agent hosts.
- Add a docs site only after the GitHub README is already strong.
