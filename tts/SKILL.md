---
name: tts
description: Generate spoken updates, hosted MP3 files, and answerable spoken questions through local or paired playback and MCP. Use when the user requests narration, voice updates, generated audio, spoken progress, audio playback, or TTS questions with suggestions or attachments.
---

# TTS

## Script location

Resolve `<skill-dir>` to the directory containing this `SKILL.md`. Run
`<skill-dir>/scripts/tts`; do not assume the current working directory is the
skill directory or that TTS is on `PATH`.

## Invoke

Every invocation requires a stable agent seed name, title, and one-line preview
summary. For an ordinary spoken update, put the words to say in `--message`:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "<2-to-5-word title>" \
  --summary "<one-line player preview>" \
  --message "<spoken update>"
```

Keep the seed name and title stable across the same work session. Aim for a
2-to-5-word title and never exceed 10 words. Use a clean topic label for
conceptual material. When work has a concrete outcome, combine the specific
topic with its meaningful state, such as `NMP Boundaries Untangled` or
`MCP Audio Verified`. Avoid generic workflow labels such as `update`, `recap`,
`verify`, `implementation`, and `final` unless they are genuinely the subject.

Write the summary as one concise factual sentence stating what changed or why
it matters. The player shows it as preview text, but it is not synthesized.
Do not repeat the title in the summary or the agent identity in the message.

Keep the primary `--message` under 600 words. The runtime permits a 10 percent
tolerance but rejects a primary message over 660 words. For a longer update,
keep the concise, automatically played main corpus in `--message`, then split
the rest into labeled narrated chapter attachments with repeated `--attach`
pairs. Each Markdown or text attachment may contain up to 2,000 narrated words
after formatting-only content is removed. Split longer narration into focused
labeled attachments. Attach raw logs and diagnostic captures with a non-text
extension when they should remain available to open without being narrated.

When an update has useful supporting material—screenshots, mockups, a proposal,
detailed findings, or decision context—attach it. Attachments let the user
expand a concise update in different directions: inspect visuals, open an
auxiliary artifact, or hear expanded Markdown or text as a deeper narrated
branch. Treat supporting material as a normal part of a substantive update, not
an exception. Link directly to an attachment from the primary message with
`[Attachment label](attachment:)`; the visible label must exactly match one
`--attach` label:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "<2-to-5-word title>" \
  --summary "<one-line player preview>" \
  --message "Open the [Supporting context](attachment:)." \
  --attach "Supporting context" <path>
```

Generation runs in the foreground. If the execution environment supports
asynchronous commands, it can keep the command running while you do other work.
Use the environment's execution handle and completion-wait mechanism; do not
detach the command with shell process-management syntax.

The ordinary command selects local synthesis or an approved paired laptop
automatically; agents do not choose a playback transport. A `--no-play`
request always uses a configured local Kokoro endpoint: it never traverses a
paired connection or appears in the player. Local synthesis returns the TTS
`id`, output path, and `queued` status after generation and attachment
preparation; `--no-play` returns `generated`. Paired delivery returns its
request identifier and delivery status without exposing files on the laptop.

## Conditional guidance

- **Pairing administration or diagnostics**: Read
  [paired-laptop.md](references/paired-laptop.md) only when the user asks to
  pair, inspect, target, or manage a remote computer. Ordinary speech routes
  automatically.
- **Questions**: Before using `--ask`, read
  [asking-questions.md](references/asking-questions.md). Both bare and structured
  asks require `--message` for the main spoken update and `--wait` for an
  agent-chosen bounded blocking interval.
  Submitted answers, selected-suggestion details, and answer-attachment paths
  return in the TTS tool output.
- **Attachments, Markdown structure, or formatted code**: Read
  [rich-content.md](references/rich-content.md).
- **No-play generation, status inspection, or failures**: Read
  [results-and-troubleshooting.md](references/results-and-troubleshooting.md).
- **Endpoint configuration**: Read [setup.md](references/setup.md).
- **MCP clients or HTTP deployment**: Read [mcp.md](references/mcp.md). The MCP
  wrapper supports stdio, pairing-code OAuth over loopback Streamable HTTP,
  redacted inbound-header diagnostics, explicit paired routing, and
  generation-only MP3 results hosted on Blossom.
