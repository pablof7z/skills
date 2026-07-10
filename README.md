# Skills

Turn recurring agent workflows into named skills you can invoke instead of re-explaining the job.

This catalog is for people who use coding agents often enough that the same high-value instructions keep coming back: repo launch work, design exploration, high-level explanation, speech generation, Nostr Cashu wallet implementation guidance, and local Codex plugin guardrails.

Instead of pasting a long prompt every time, install the relevant skill once and invoke it by name. The agent gets a focused workflow, the right reference material, and clearer boundaries for what it should produce.

## Quick Start

Clone the catalog:

```bash
git clone https://github.com/pablof7z/skills.git
cd skills
```

Install one skill by copying its folder into the directory your agent host scans. For a Codex-style local setup:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R repo-marketing "${CODEX_HOME:-$HOME/.codex}/skills/"
```

Start a new agent session and invoke it by name:

```text
Use $repo-marketing to audit this README for positioning, proof, quick start, trust, and agent readiness.
```

Expected result: the agent loads `repo-marketing`, builds a marketing brief, and returns a scored audit or rewritten first screen instead of a generic documentation summary.

## Start Here

| Skill | Use it when | What it gives you |
|---|---|---|
| [`repo-marketing`](repo-marketing/) | A repo is useful, but the README does not make people want to try it. | A marketing brief, sharper first screen, proof plan, quick start, trust copy, and launch-readiness fixes. |
| [`design-exploration-capture`](design-exploration-capture/) | A design question is turning into a real exploration with alternatives, objections, and shifting boundaries. | A named exploration session with notes, open questions, tradeoffs, rejected options, risks, and convergence discipline. |
| [`high-level`](high-level/) | You need the gist of a repo, system, protocol, document, or workflow without a deep internal tour. | A concise mental model, the main moving parts, and the next useful thing to inspect. |
| [`tts`](tts/) | The useful output is spoken audio, not another text reply. | Text-to-speech guidance plus a local helper that sends text to a Kokoro-compatible endpoint and returns MP3 audio. |
| [`nip60`](nip60/) | You are implementing Cashu wallets or nutzaps on Nostr with NDK. | Event kind references, wallet flows, token operations, nutzap monitoring, mint discovery, and security notes. |

## Plugins

| Plugin | Use it when | What it gives you |
|---|---|---|
| [`worktreeguard-codex`](plugins/worktreeguard-codex/) | Codex should respect WorktreeGuard-protected base checkouts and do mutating work in Git worktrees. | Codex lifecycle hooks that delegate policy decisions to `wtg` and return actionable worktree instructions on denied base-checkout mutations. |

## Skills By Job

### Make A Repo Easier To Try

| Skill | Use it when | What it gives you |
|---|---|---|
| [`repo-marketing`](repo-marketing/) | The repo front door reads like implementation notes, internal metadata, or stale docs. | Human-facing positioning, README copy, launch copy, proof assets, and trust objections. |

### Keep Exploration Coherent

| Skill | Use it when | What it gives you |
|---|---|---|
| [`design-exploration-capture`](design-exploration-capture/) | The user is still probing the shape of a design rather than asking for implementation. | A compact decision trail that keeps evidence, assumptions, risks, alternatives, and decisions separate. |
| [`high-level`](high-level/) | The user asks "what is this?", "how does this work at a high level?", or "give me the mental model." | A short explanation that starts broad, names the main parts, and stops before dumping internals. |

### Produce Audio

| Skill | Use it when | What it gives you |
|---|---|---|
| [`tts`](tts/) | You want a generated voice note, narration, accessibility read, or short audio proof. | MP3 output through your configured Kokoro endpoint, with voice selection and playback controls. |

### Build Nostr Wallet Flows

| Skill | Use it when | What it gives you |
|---|---|---|
| [`nip60`](nip60/) | You need to build or debug Nostr Cashu wallet behavior. | Practical NDK examples for NIP-60 wallets, NIP-61 nutzaps, and NIP-87 mint discovery. |

## Trust Boundaries

Most skills here are instruction and reference material. A few touch local files, network services, or sensitive implementation domains:

- `design-exploration-capture` may write local notes when it is actively used for design exploration.
- `tts` reads `~/.env.tts` by default, calls your configured Kokoro-compatible endpoint, writes MP3 files under `/tmp`, and may pause/resume Music or Spotify on macOS unless disabled.
- `nip60` is wallet implementation guidance. Real use can involve Nostr keys, encrypted events, public nutzap events, relays, mints, and signed wallet operations.
- `worktreeguard-codex` installs Codex hooks that call the local `wtg` binary during session and tool events. Full enforcement depends on the WorktreeGuard CLI and daemon being installed and trusted.

For `tts`, configure the endpoint before use:

```bash
export KOKORO_API_ENDPOINT="https://<your-host>/v1/audio/speech"
./tts/scripts/tts --no-play "Hello world" af_bella
```

Expected result: the script prints the path to a generated `/tmp/tts_*.mp3` file. Add auth variables only if your endpoint requires them.

## Human Copy Vs Router Metadata

The descriptions in this README are written for people deciding what to try. The `description` fields inside `SKILL.md` files are written for agent routing, so they can be more literal, conditional, and keyword-rich.

When judging a skill, read the human promise here first, then inspect the skill body for the exact trigger rules and boundaries.

## License

MIT. See [LICENSE](LICENSE).
