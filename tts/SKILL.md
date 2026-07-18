---
name: tts
description: Publish durable spoken updates and answerable spoken questions through a standalone TTS29 daemon. Use when the user requests narration, a voice update, spoken progress, cross-device speech, or a bounded spoken question. The skill is a producer adapter only; it does not synthesize, pair devices, own playback, or run Nostr.
---

# TTS

## Invoke the standalone producer

Resolve `<skill-dir>` to the directory containing this file and run
`<skill-dir>/scripts/tts`. Do not assume the current directory or `PATH` contains
the skill.

Every request needs a stable agent name, concise subject, factual preview, and
the words to speak:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<stable-agent-name>" \
  --subject "<2-to-5-word title>" \
  --summary "<one factual preview sentence>" \
  --message "<spoken update>"
```

Keep the same agent name during one workstream. Keep the subject under 10 words
and 80 UTF-8 bytes. Keep the summary under 280 UTF-8 bytes and the primary
message under 300 words; the adapter rejects more than 330 words. Write for
listening: short plain-language paragraphs, no raw logs, and no code that would
be painful to hear.

The command shapes one stable TTS29 producer request and invokes the standalone
`tts29` CLI. It returns durable publication evidence as JSON. It never starts a
player or claims that any device played the item.

## Questions

Before using `--ask`, read
[asking-questions.md](references/asking-questions.md). Every ask requires an
explicit wait no longer than five minutes. A timeout does not undo publication.

## Durable attachments

Before adding supporting artifacts, read
[durable-artifacts.md](references/durable-artifacts.md). The adapter accepts
only complete HTTPS artifact descriptors. It deliberately refuses local file
paths because artifact upload belongs to the standalone daemon/product, not the
installed skill.

## Setup and failures

- Read [setup.md](references/setup.md) when the CLI, socket, group, or identity
  is not configured.
- Read [results-and-troubleshooting.md](references/results-and-troubleshooting.md)
  when publication or an answer wait fails.
- Hosted HTTPS MCP is owned and deployed by the standalone
  [TTS29 product](https://github.com/pablof7z-agent/tts29), not this skill.

## Product boundary

The skill owns only request validation and shaping. `tts29d` owns Kokoro,
Blossom, durable jobs, membership repair, NMP publication, receipts, and bounded
answer observation. Apple and compatible NIP-29 clients independently project
and play the durable queue. Do not add pairing, local synthesis, queue state,
playback policy, Nostr code, or an MCP server to this skill.
