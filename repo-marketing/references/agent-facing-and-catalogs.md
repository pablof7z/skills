# Agent-Facing Repos And Catalogs

Use when the repo exposes skills, prompts, commands, MCP servers, plugins,
agent tasks, broad tool catalogs, or prompt-native activation.

## Prompt-Native Activation

For agent-facing repos, installation is not the end of the funnel. Show the
phrase, slash command, prompt, or agent instruction that starts the useful work.

Good:

```md
## First Agent Task

After installing, tell your agent:

> Watch this video and tell me what changes on screen after 2:30.

The agent should download captions first, extract only the needed frames, and answer with timestamped evidence.
```

Rules:

- Show the exact phrase, slash command, or prompt.
- State what the agent should do next.
- If the prompt involves credentials, browser state, local files, shell execution, or paid model/API usage, include the trust boundary inline.
- Separate host install from first task activation.

## Task Recipe Bank

Use a task recipe bank when one command is not enough to teach use.

Pattern:

```md
## What people use it for

| When you want to... | Say or run... | What happens | Verify it worked |
|---|---|---|---|
| Review a branch before merge | `/codex:review --base main` | Runs a read-only review. | Findings or clean pass are returned. |
| Understand a video without watching it | `/watch URL what is new here?` | Pulls captions, samples frames, answers from transcript and visuals. | The answer cites timestamps or visible moments. |
```

Good task recipes:

- use the reader's own intent language
- include exact prompt, slash command, shell command, URL, file, or input
- state the produced artifact, decision, report, output, or behavior
- include a verification signal
- mention trust boundaries inline when needed
- stay compact: 3-7 recipes before a command reference

Bad:

```md
## Commands

- `/scan`: scans
- `/review`: reviews
- `/status`: status
```

## Skill Catalog README Mode

Do not lead with a flat inventory.

Weak:

```md
| Skill | Description |
|---|---|
| name | Does X with Y and Z. |
```

Better:

```md
| Skill | Use it when | What it gives you |
|---|---|---|
| `name` | The moment or situation that should trigger this skill. | The artifact, judgment improvement, or failure mode avoided. |
```

Recommended structure:

```md
# Skill Collection Name

A collection of [skill type] for [audience] who need agents to [higher-quality work].

## Why this exists

Explain the pain.

## Quick Start

How to install and use the skills.

## Best Skills to Try First

3-7 high-value skills with human-facing hooks.

## Skills by Job

Group by user job, not alphabetically by default.

## Agent Router Metadata

Explain that `SKILL.md` descriptions are written for agent selection and may be more literal than public copy.
```

Do not add "Authoring a new skill", "Development checks", or a literal
repository tree to a skill-catalog README unless the user explicitly asks for
maintainer docs. If authoring guidance is useful, recommend a separate
`docs/authoring.md`.

## Per-Skill Fields

For every skill, generate:

```md
Name:
Human hook:
Use it when:
What it gives you:
Failure mode prevented:
Agent-router description:
Optional rename suggestions:
```

## Agent Router Copy

Router descriptions should remain explicit and keyword-rich. Public copy should
be more human-facing.

Router metadata can say:

```txt
Use when the user asks to transcribe, summarize, or inspect video files and URLs.
```

Public README copy should say:

```txt
Paste a video and ask the agent what actually happens on screen.
```
