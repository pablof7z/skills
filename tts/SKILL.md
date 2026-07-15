---
name: tts
description: Generate spoken updates and answerable spoken questions through a Kokoro-compatible TTS endpoint. Use when the user requests narration, voice updates, spoken progress, audio playback, or TTS questions with suggestions or attachments.
---

# TTS

## Script location

Resolve `<skill-dir>` to the directory containing this `SKILL.md`. Run
`<skill-dir>/scripts/tts`; do not assume the current working directory is the
skill directory or that TTS is on `PATH`.

## Invoke

Every invocation requires a stable agent seed name and subject. For an ordinary
spoken update, put the words to say in `--message`:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "<5-to-10-word subject>" \
  --message "<spoken update>"
```

Keep the seed name and subject stable across the same work session. Write the
subject in 5 to 10 words. Do not repeat the agent identity in the message.

When an update has useful supporting material—screenshots, mockups, a proposal,
detailed findings, or decision context—attach it. Attachments let the user
expand a concise update in different directions: inspect visuals, open an
auxiliary artifact, or hear expanded Markdown or text as a deeper narrated
branch. Treat supporting material as a normal part of a substantive update, not
an exception:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "<5-to-10-word subject>" \
  --message "<spoken update>" \
  --attach "Supporting context" <path>
```

Generation runs in the foreground. If the execution environment supports it,
you can run the whole command in the background; do not detach it with shell
process-management syntax.

After generating the primary audio, the script prepares narrated text
attachments, queues normal playback, and prints JSON with the TTS `id`, output
path, and `queued` status. With `--no-play`, it prints `generated` instead.

## Conditional guidance

- **Questions**: Before using `--ask`, read
  [asking-questions.md](references/asking-questions.md). Bare `--ask` uses
  `--message`; a structured question bundle supplies its own spoken content.
  Submitted answers, selected-suggestion details, and answer-attachment paths
  return in the TTS tool output.
- **Attachments or formatted code**: Read
  [rich-content.md](references/rich-content.md).
- **No-play generation, status inspection, or failures**: Read
  [results-and-troubleshooting.md](references/results-and-troubleshooting.md).
- **Endpoint configuration**: Read [setup.md](references/setup.md).
