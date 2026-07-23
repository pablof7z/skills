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

### [Runbook: Learn Procedures From Real Work](runbook/SKILL.md)

Recurring requests should get easier without letting yesterday's procedure
override today's user instruction or live source of truth. `runbook` stores a
compact, revisable procedure in an agent-owned directory and ships a local
helper for finding, capturing, reviewing, and validating it.

[See the runbook workflow and safety boundary →](runbook/SKILL.md)

### [TTS: Publish to a Durable Spoken Queue](tts/README.md)

The `tts` skill is a thin producer adapter for the standalone
[TTS29](https://github.com/pablof7z-agent/tts29) product. An agent publishes one
durable spoken item or bounded question; iPhone, macOS, and compatible NIP-29
clients independently reconstruct and play the shared queue.

[See the adapter boundary and first publication →](tts/README.md)

### [Repo Marketing: Make the Value Visible](repo-marketing/README.md)

Useful software is often buried under a README that starts where the maintainer's mind ended: architecture, setup matrices, and internal nouns. `repo-marketing` works backward from the moment a stranger decides whether this is for them.

It finds the strongest honest hook, proof, first useful loop, trust boundary, and launch gap, then turns those into a front door that earns attention before asking for effort.

[See how a repository becomes a product-shaped project →](repo-marketing/README.md)

### [Meta Feedback: Turn Skill Friction into Evidence](meta-feedback/SKILL.md)

Skills rarely fail in clean, repeatable ways. An instruction is ambiguous, a trigger misses, or a user has to correct the agent—and the useful evidence disappears into the session.

`meta-feedback` records that concrete incident beside the target skill as a canonical Markdown issue, including the context, impact, workaround, and exact skill revision. Repeated incidents accumulate without pretending one observation proves the fix.

[See how real skill friction becomes a durable issue →](meta-feedback/SKILL.md)

### [Design Exploration Capture: Preserve the Path to a Decision](design-exploration-capture/README.md)

The hardest design discussions do not fail from a lack of ideas. They fail when assumptions quietly become decisions, rejected options return without context, or implementation begins before the important uncertainty is gone.

`design-exploration-capture` keeps the exploration alive without letting it become vague: evidence, tensions, risks, alternatives, and decision signals stay distinct until the direction actually converges.

[See how an open question becomes a defensible decision →](design-exploration-capture/README.md)

### [High Level: Understand Without Drowning](high-level/README.md)

Depth is not the same as understanding. `high-level` gives an agent permission to find the real shape of a codebase, protocol, document, or workflow and explain only the concepts needed to reason about it.

The result is a useful mental model, not a file tour, glossary dump, or performance of comprehensiveness.

[See what a good high-level explanation should accomplish →](high-level/README.md)

### [Home Directory: Keep Agent-Private State Together](home-directory/SKILL.md)

Session handles come and go, but an agent's private notes, helper scripts,
drafts, and lightweight caches should not scatter across a new directory every
time. `home-directory` resolves one durable `~/.agents/home/{identifier}` path
from the stable agent identity and keeps session identity out of that choice.

[See the private-state boundary and resolver →](home-directory/SKILL.md)

### [NIP-60: Keep Nostr Cashu Wallet State Coherent](nip60/README.md)

In a Cashu wallet, the hard part is not drawing a balance. It is keeping proofs, mints, encrypted Nostr events, pending operations, nutzaps, and recovery coherent when the network is partial and money is in motion.

`nip60` gives agents a concrete implementation guide for NIP-60 wallets, NIP-61 nutzaps, NIP-87 mint discovery, and the NDK wallet APIs that connect them.

[See the wallet model, flows, and safety boundary →](nip60/README.md)

## Also Included

The repository includes a WorktreeGuard plugin for keeping agent mutations out of protected Git base worktrees and steering implementation into isolated worktrees.

## Trust Boundaries

Most skill folders contain instructions and reference material only. The exceptions are explicit:

- `tts` sends one validated request to the private Unix socket of a separately
  installed TTS29 daemon. It does not read daemon credentials, synthesize or
  store audio, pair devices, own playback, or implement Nostr.
- `meta-feedback` writes or appends Markdown issues under the target skill's `meta-feedback/` directory. It does not edit the target skill, change issue status, or publish feedback to GitHub.
- `design-exploration-capture` may create or update local exploration notes while a design session is active.
- `home-directory` creates the selected private agent directory under `~/.agents/home`; its resolver does not read or publish the directory's contents.
- `nip60` is implementation guidance for software that can touch keys, signed events, relays, mints, and token state. It is not custody software or a security audit.
- `runbook` writes only to the selected runbook directory and makes no network requests.
- The WorktreeGuard plugin installs Codex hooks and writes local policy and audit state.

Installation copies skill folders into `~/.agents/skills`. Remove a copied
folder to uninstall it. The fleet installer below uses the same copy model and
adds no telemetry service.

## Install The Catalog Across Computers

`scripts/install-fleet` installs every top-level skill on the current computer
and any SSH targets you name:

```bash
scripts/install-fleet customer@23.88.91.234 pablo@157.180.102.242
```

The command fetches the latest merged `origin/main` and deploys it from a
temporary archive, so a dirty or behind local checkout is left untouched. It
overwrites stale catalog files without keeping backups, preserves explicitly
excluded machine-owned state such as legacy TTS sessions and skill feedback,
then validates installed skill entrypoints and reports the exact commit.

## License

MIT. See [LICENSE](LICENSE).
