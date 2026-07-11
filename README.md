# Agent Skills

Installable workflows for coding agents that turn recurring work into one named instruction.

<p align="center">
  <img src="assets/tts-menu-player.png" alt="The TTS skill showing an agent update in its macOS menu-bar player, with transcript progress, session metadata, and podcast controls" width="500">
</p>

The player above comes from [`tts`](tts/): agent updates become a serialized macOS audio queue with a readable transcript, session identity, pause, seek, replay, and media-aware playback.

This catalog is for people who use coding agents often enough to recognize the same work coming back. Instead of rebuilding the prompt every time, install a skill once and invoke a workflow that already knows what to inspect, what to produce, and where its trust boundaries are.

## Try One

Clone the catalog and install `repo-marketing`:

```bash
git clone https://github.com/pablof7z/skills.git
cd skills
mkdir -p ~/.agents/skills
cp -R repo-marketing ~/.agents/skills/
```

Start a new agent session, then say:

```text
$repo-marketing rewrite this README around the shortest convincing proof and first-run path.
```

The agent should inspect the repository, identify the audience and trust boundaries, then return or implement a sharper README instead of producing a generic documentation summary.

Installation only copies the selected skill folder into `~/.agents/skills`. Remove that folder to uninstall it.

## Skills Worth Trying

| Skill | Use it when | What changes |
|---|---|---|
| [`tts`](tts/) | You want agent updates as audio without blocking the agent or letting multiple sessions talk over each other. | Generates speech through your Kokoro endpoint, queues it, and exposes a macOS player with transcript progress and session context. |
| [`repo-marketing`](repo-marketing/) | A useful repository still does not make people want to try it. | Reworks positioning, proof, activation, trust, and launch readiness around the repository that actually exists. |
| [`design-exploration-capture`](design-exploration-capture/) | A design discussion has real alternatives and should not collapse into premature implementation. | Keeps a named decision trail with evidence, tensions, rejected directions, and convergence state. |
| [`high-level`](high-level/) | You need the useful mental model without an internal tour. | Explains the system from the outside in and stops at the right level. |
| [`nip60`](nip60/) | You are building or debugging Cashu wallets and nutzaps on Nostr with NDK. | Gives the agent concrete event, token, mint, relay, and security guidance for NIP-60, NIP-61, and NIP-87 flows. |

The repository also includes the [`worktreeguard-codex`](plugins/worktreeguard-codex/) plugin for keeping agent mutations out of protected Git base worktrees.

## TTS: Agent Updates You Can Follow

`tts` is the most visible example of what a skill can become when the workflow owns the whole loop rather than just a prompt:

- Speech generation stays in the foreground long enough to report endpoint failures and confirm that output exists.
- Playback moves into the background only after generation succeeds.
- One resident macOS process serializes updates from multiple agents.
- The menu-bar player shows the full spoken text, approximate word progress, agent name, voice, harness, workspace, and session identifier.
- Podcast controls provide pause, 15-second seek, timeline scrubbing, and replay.
- Music or Spotify can be paused for speech and resumed afterward.

To run it directly:

```bash
export KOKORO_API_ENDPOINT="https://<your-host>/v1/audio/speech"
./tts/scripts/tts \
  --agent-name nova-summit-482 \
  --introduction "Agent Nova here, working on the repository launch." \
  "The README update is ready for review."
```

On macOS 13 or later with Swift available, the first audible request builds and starts the menu-bar player. The command returns after the endpoint has produced the audio and the item has been accepted for playback. See [`tts/references/setup.md`](tts/references/setup.md) for endpoint configuration.

## Trust Boundaries

Most folders contain agent instructions and reference material only. Skills that execute helpers or touch sensitive domains state those boundaries in their own documentation.

- `tts` sends the supplied text to the Kokoro-compatible endpoint you configure, writes generated audio under `/tmp`, stores queue state under `~/.local/state/tts`, and may control Music or Spotify on macOS unless disabled.
- `design-exploration-capture` may create or update local exploration notes while a design session is active.
- `nip60` covers wallet behavior involving Nostr keys, signed events, relays, mints, and token state; it is implementation guidance, not custody software.
- `worktreeguard-codex` installs Codex hooks and writes local policy/audit state. Read its plugin README before installation.

No shared installer or telemetry service is included. You choose which folders to install and can inspect every instruction, reference, and helper in place.

## License

MIT. See [LICENSE](LICENSE).
