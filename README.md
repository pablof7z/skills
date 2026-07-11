# Agent Skills

Installable workflows for coding agents that turn recurring work into one named instruction.

This catalog is for people who use agents often enough to recognize the same hard jobs coming back. A skill is more than a saved prompt: it carries a point of view about the work, the evidence worth gathering, the failure modes to avoid, and what a good result should look like.

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

The agent should inspect the repository before it writes, identify the real audience and trust boundaries, and shape the page around evidence rather than generic documentation structure.

## The Skills

### [TTS: Hear What Your Agents Are Doing](tts/README.md)

Agents already produce useful status updates. `tts` turns them into a shared audio queue you can follow without watching every terminal or letting concurrent sessions speak over each other.

On macOS, it becomes a menu-bar player with optional spoken subjects, a readable transcript, agent and session identity, timeline scrubbing, pause, seek, and replay. Generation failures stay visible to the calling agent before playback moves into the background.

<p align="center">
  <a href="tts/README.md"><img src="assets/tts-menu-player.png" alt="The TTS skill showing a subject, transcript progress, session metadata, and podcast controls" width="240"></a>
</p>

[See the player, workflow, and first spoken update →](tts/README.md)

### [Repo Marketing: Make the Value Visible](repo-marketing/README.md)

Useful software is often buried under a README that starts where the maintainer's mind ended: architecture, setup matrices, and internal nouns. `repo-marketing` works backward from the moment a stranger decides whether this is for them.

It finds the strongest honest hook, proof, first useful loop, trust boundary, and launch gap, then turns those into a front door that earns attention before asking for effort.

[See how a repository becomes a product-shaped project →](repo-marketing/README.md)

### [Design Exploration Capture: Preserve the Path to a Decision](design-exploration-capture/README.md)

The hardest design discussions do not fail from a lack of ideas. They fail when assumptions quietly become decisions, rejected options return without context, or implementation begins before the important uncertainty is gone.

`design-exploration-capture` keeps the exploration alive without letting it become vague: evidence, tensions, risks, alternatives, and decision signals stay distinct until the direction actually converges.

[See how an open question becomes a defensible decision →](design-exploration-capture/README.md)

### [High Level: Understand Without Drowning](high-level/README.md)

Depth is not the same as understanding. `high-level` gives an agent permission to find the real shape of a codebase, protocol, document, or workflow and explain only the concepts needed to reason about it.

The result is a useful mental model, not a file tour, glossary dump, or performance of comprehensiveness.

[See what a good high-level explanation should accomplish →](high-level/README.md)

### [NIP-60: Keep Nostr Cashu Wallet State Coherent](nip60/README.md)

In a Cashu wallet, the hard part is not drawing a balance. It is keeping proofs, mints, encrypted Nostr events, pending operations, nutzaps, and recovery coherent when the network is partial and money is in motion.

`nip60` gives agents a concrete implementation guide for NIP-60 wallets, NIP-61 nutzaps, NIP-87 mint discovery, and the NDK wallet APIs that connect them.

[See the wallet model, flows, and safety boundary →](nip60/README.md)

## Also Included

The repository includes a WorktreeGuard plugin for keeping agent mutations out of protected Git base worktrees and steering implementation into isolated worktrees.

## Trust Boundaries

Most skill folders contain instructions and reference material only. The exceptions are explicit:

- `tts` sends supplied text to the Kokoro-compatible endpoint you configure, writes generated audio under `/tmp`, stores queue state under `~/.local/state/tts`, and may control Music or Spotify on macOS unless disabled.
- `design-exploration-capture` may create or update local exploration notes while a design session is active.
- `nip60` is implementation guidance for software that can touch keys, signed events, relays, mints, and token state. It is not custody software or a security audit.
- The WorktreeGuard plugin installs Codex hooks and writes local policy and audit state.

Installation copies only the skill folders you choose into `~/.agents/skills`. Remove a copied folder to uninstall it. No shared installer or telemetry service is included.

## License

MIT. See [LICENSE](LICENSE).
