# High Level

## Understanding is compression without distortion

Technical explanations often fail in two opposite ways. They either flatten the system into a slogan that cannot support a decision, or reproduce so much internal detail that the reader has to rebuild the mental model themselves.

`high-level` asks an agent to do the compression work.

The agent inspects enough evidence to find the system's real shape, then explains the problem it solves, the few moving parts that matter, what flows between them, and which details can safely be ignored on a first pass. Internal names appear only when they earn their place.

## What a good answer gives you

- A one-sentence gist that is specific enough to be useful.
- A small mental model organized by responsibility, not by directory layout.
- The central flow or boundary that makes the rest of the system make sense.
- Honest uncertainty about what was not inspected.
- One useful next place to look when deeper understanding is warranted.

This is particularly useful before a design review, while entering an unfamiliar repository, when evaluating a protocol, or whenever the detailed explanation arrived before the basic one.

## Ask at the right altitude

```text
$high-level explain how this repository turns a generated audio file into serialized menu-bar playback.
```

Or:

```text
$high-level give me the mental model for this architecture without walking every module.
```

The skill is deliberately bounded. It should orient you well enough to reason, ask a sharper question, or choose the next investigation. It should not perform comprehensiveness for its own sake.

Read [SKILL.md](SKILL.md) for the evidence order, output shape, and stopping rules.
