# Prime Context

## Research a topic once, reuse it for the rest of the session

Agents that investigate the same subject twice in a week waste the second pass reconstructing what the first pass already learned. Worse, the reconstruction is rarely as careful: sources get skipped, uncertainty gets flattened, and the second answer quietly drifts from the first.

`prime-context` gives topic research a durable, owned home instead of letting it evaporate at the end of a session.

When asked to prime a topic, the calling agent delegates to a subagent that first searches its own research root for a matching prior entry — by directory name, topic, aliases, and note content — before doing any new work. If a match exists, it is read and reused. If not, the subagent investigates with primary sources, records what is sourced versus inferred, and writes a single new note. The calling agent then reads the resulting note itself, states a short confirmation, and treats the topic as primed for the rest of the session — updating the record with follow-up notes as new evidence surfaces.

## What the skill protects

- **Continuity:** research survives across sessions instead of starting from zero each time.
- **Ownership:** notes live under the calling agent's own home directory, never a shared or ambiguous location.
- **Source discipline:** every note cites where a finding came from and separates fact from inference.
- **No duplication:** one subagent owns the prior-entry check and the write, so concurrent lookups cannot fork the record.
- **Honest brevity:** the user gets a terse confirmation, not a dump of the full research file.

## Prime a topic

```text
$prime-context prime context on the NIP-60 wallet recovery flow before we touch it.
```

The agent resolves its own identity, finds or creates its private research root via `home-directory`, and either reuses a matching note or investigates fresh. Later in the same session, if new evidence changes what was loaded, the agent records a follow-up note rather than treating the finding as a passing detail.

Read [SKILL.md](SKILL.md) for the note contract, ownership resolution, and the rules for capturing later discoveries.
