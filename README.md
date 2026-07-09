# Skills

A compact collection of agent skills for repo marketing, Nostr Cashu wallet guidance, text-to-speech, and high-level explanation.

Use this repo when you want reusable agent behavior as plain folders instead of long prompts that have to be pasted into every session.

```text
repo-marketing/
|-- SKILL.md                      # core instructions loaded when the skill triggers
|-- agents/openai.yaml            # optional UI metadata for compatible hosts
`-- references/readme-playbook.md # deeper playbook loaded only when needed
```

## Why this exists

Agent skills work best when they are small, inspectable, and easy to copy between environments. This repo keeps each skill in its own folder with a `SKILL.md` entry point and optional bundled resources such as `references/`, `scripts/`, and `agents/openai.yaml`.

The collection is useful when you need to:

- Give agents durable domain knowledge without expanding every prompt.
- Package a workflow with scripts or references that can be reused safely.
- Share agent instructions across Codex, Claude-style, or other skill-aware hosts.
- Keep sensitive workflows legible by making scripts, network behavior, and setup notes visible in the repo.

## Quick Start

Clone the collection:

```bash
git clone https://github.com/pablof7z/skills.git
cd skills
```

Install one skill by copying its folder into your agent host's skills directory. For Codex-style local skills:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R repo-marketing "${CODEX_HOME:-$HOME/.codex}/skills/"
```

Start a new agent session and invoke it:

```text
Use $repo-marketing to audit this README for positioning, quick start, proof, trust, and agent readiness.
```

The agent should load `repo-marketing/SKILL.md`, then read `references/readme-playbook.md` only when doing a README rewrite or audit.

## Included Skills

| Skill | Use it for |
|---|---|
| [high-level](high-level/) | Explain a topic, codebase, document, system, or workflow at a plain-language high level. |
| [nip60](nip60/) | Build Cashu wallets on Nostr with NIP-60 wallets, NIP-61 nutzaps, and NIP-87 mint discovery. |
| [repo-marketing](repo-marketing/) | Create, rewrite, or audit README files and repo structures for adoption, launch readiness, trust, and agent-friendliness. |
| [tts](tts/) | Generate spoken audio from text with a Kokoro-compatible TTS endpoint. |

## How It Works

Each skill is a self-contained folder:

```text
<skill-name>/
|-- SKILL.md             # required; frontmatter for host discovery plus instructions
|-- agents/openai.yaml   # optional UI metadata for compatible skill hosts
|-- references/          # optional docs loaded only when needed
`-- scripts/             # optional executable helpers used by the skill
```

For host-discoverable skills, the `SKILL.md` frontmatter names the skill and describes when it should trigger. The body gives the agent the core workflow. Larger playbooks stay in `references/` so the host can load them only when the task needs that detail. Deterministic helper code lives in `scripts/`.

Some older guide-style folders in this repo are plain Markdown `SKILL.md` files. Add frontmatter when modernizing them for automatic discovery.

## Project Structure

```text
.
|-- README.md
|-- high-level/
|   |-- SKILL.md
|   `-- agents/openai.yaml
|-- nip60/
|   `-- SKILL.md
|-- repo-marketing/
|   |-- SKILL.md
|   |-- agents/openai.yaml
|   `-- references/readme-playbook.md
`-- tts/
    |-- SKILL.md
    |-- references/setup.md
    `-- scripts/tts
```

## Trust and Safety

Review a skill before installing it. Skills are plain text plus optional local scripts, so the trust boundary is the folder you copy into your agent host.

- `high-level`, `repo-marketing`, and `nip60` are primarily instruction and reference skills.
- `tts` includes an executable helper and uses a Kokoro-compatible endpoint.
- `nip60` may involve relays, keys, wallets, or signed events when used in real workflows. Keep secret keys out of prompts and shell history.
- No repo-wide install script runs automatically.

## Development

Add or update one skill at a time. For new skills, keep the root folder name, `SKILL.md` frontmatter `name`, and README entry aligned.

Useful local checks:

```bash
find . -maxdepth 2 -name SKILL.md -print
rg -n '^(name|description):' */SKILL.md
git diff --check
```

For skills with scripts, run the script manually on a harmless example before committing. For skills with `references/`, keep the main `SKILL.md` short and link directly to the reference files it expects an agent to read.

## Contributing

Good contributions are small and easy to inspect:

- New skills with a clear trigger description and a focused workflow.
- Reference files that remove bulky detail from `SKILL.md`.
- Script fixes with a tested command and expected output.
- Setup notes for skills that depend on local tools, endpoints, browser flags, relays, or credentials.

Avoid adding generic documentation files inside a skill folder unless the skill actually uses them. A useful skill should be easy for another agent to load, understand, and apply without reading unrelated material.

## License

MIT. See [LICENSE](LICENSE).
