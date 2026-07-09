# Activation And Setup

Use when the repo has install paths, first-run constraints, modes, operating
dials, reader lanes, demos, hosted/local paths, or build-vs-use confusion.

## Quick Start

Create one golden path.

It must:

- work on the default host or platform
- show the shortest install flow
- show the first useful command
- show the expected result
- defer edge cases to later sections
- mention what gets written or modified when relevant

Prefer:

```bash
install-command
first-use-command
```

Then state:

```txt
You should see ...
```

## First-Run Fit Gate

Add a compact fit gate when any of these affect adoption:

- platform or hardware: macOS version, Apple silicon, Linux-only KVM, GPU/CPU expectations
- host or ecosystem: Claude Code, Codex, Cursor, VS Code preview, browser extension, MCP host, runtime version
- account or credential: API key, cloud account, model provider, local CLI auth, browser login state
- permission or operations: Docker, admin password, system service, kernel feature, network policy, sandbox image pull
- edition or maturity: community vs pro, preview/beta, active-development stability, compatibility guarantees
- data boundary: local-only, self-hosted, hosted demo, telemetry, storage path, retention
- legal or safety boundary: voice cloning consent, prohibited uses, offensive-security scope, compliance assumptions

Good:

```md
## Before You Start

- Runs on Apple silicon Macs with macOS 26 or later.
- Installs a signed package and starts a local system service.
- Use the uninstall script with `-k` to keep user data or `-d` to remove it.
```

Rules:

- Put hard disqualifiers before or beside the first-run path.
- Keep development prerequisites out of the fit gate unless building from source is the primary use path.
- If there are multiple modes, separate fastest demo, normal local use, and hosted/pro path.
- If the legal or safety boundary affects whether the reader should use the project, mention it before examples that could be misused.

## Activation Ladder

Use an activation ladder when there are multiple entry paths. Order paths by
how quickly a reader can see value, not by how the maintainer works.

Default order:

1. Try without installing: hosted demo, browser demo, screenshot/GIF, sample output, playground, notebook, downloadable release artifact.
2. Fastest local use: package install, release binary, one command, host install.
3. First useful loop: create/read/run something and state expected result.
4. Integration path: minimal code snippet, API call, plugin install, host-specific activation.
5. Build from source/development: dependencies, compiler/toolchain, tests, contribution setup.

Rules:

- If there is a hosted demo, say what works there and what requires local install.
- For SDKs, separate "use the SDK" from "modify the SDK".
- For models and media tools, include the smallest command that produces a real artifact.
- For agent tools, distinguish host install from first invocation.

## Mode And Tradeoff Dials

When a project has real operating modes, show tradeoffs before feature inventory.

Use a mode/tradeoff table when choices affect:

- speed or latency
- token/context cost
- money/API cost
- output quality or fidelity
- local vs hosted data boundary
- sandbox/isolation level
- auto-update vs pinned/manual install
- GUI vs CLI vs library surface
- model/provider choice
- scan depth, frame budget, crawl depth, or other resource budget
- credential or permission requirements

Good:

```md
## Choose a Mode

| Mode | Use it when | Tradeoff |
|---|---|---|
| `transcript` | You only need what was said. | Fastest and cheapest; no visual inspection. |
| `efficient` | You need a broad visual scan. | Low token cost; may miss subtle visual changes. |
| `balanced` | You need normal visual grounding. | Slower and more tokens, but better scene coverage. |
```

Rules:

- Put the default recommendation first.
- Name the decision trigger, not just the option name.
- Keep the table short; three to five modes is usually enough.
- Do not add a tradeoff table for fake choices that all lead to the same workflow.
- If the choice changes trust, credentials, or data movement, combine it with the fit gate or trust note.

## Reader Path Lanes

Use lanes when materially different readers need different first-use paths.

Good:

```md
## For Agents

Install the skill, then say:

> Watch this video and tell me what changes on screen after 2:30.
```

```md
## For Developers

Add the package and run the minimal example.
```

Rules:

- Do not create fake lanes that differ only by label.
- Each lane must show a different activation path or decision trigger.
- Put the highest-conversion lane first.

## What You Get

Add this section when the project produces artifacts or changes a workflow.

Examples:

```md
## What You Get

- `repo-audit.md`: scored findings and prioritized fixes.
- `README.md`: rewritten first screen and quick start.
- `assets/demo.gif`: recommended demo script and capture checklist.
```

For exploratory repos:

```md
## What You Get

- A map of the problem space.
- Competing directions and what each optimizes for.
- Boundaries, tensions, and unknowns that still matter.
- A next-step decision point instead of a fake final answer.
```
