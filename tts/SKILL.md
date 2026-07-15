---
name: tts
description: Generate spoken updates and answerable spoken questions through a Kokoro-compatible TTS endpoint. Use when the user requests narration, voice updates, spoken progress, audio playback, or TTS questions with suggestions or attachments.
---

# TTS

Use `scripts/tts` to generate spoken updates.

## Invoke

Every invocation requires a stable agent seed name and subject. For an ordinary
spoken update, put the words to say in `--message`:

```bash
./scripts/tts \
  --agent-name "<seed-name>" \
  --subject "<5-to-10-word subject>" \
  --message "<spoken update>"
```

Keep the seed name and subject stable across the same work session. Write the
subject in 5 to 10 words. Do not repeat the agent identity in the message.

Generation runs in the foreground. If the execution environment can run a
command asynchronously, start the whole command with that capability, retain
its handle, and wait for completion before claiming the update was generated.
Do not detach it with shell process-management syntax.

## Conditional guidance

- **Questions**: Before using `--ask`, read
  [asking-questions.md](references/asking-questions.md). The user's submitted
  answers, selected-suggestion details, and answer-attachment paths return in
  the tool output.
- **Attachments or formatted code**: Read
  [rich-content.md](references/rich-content.md).
- **No-play generation, status inspection, or failures**: Read
  [results-and-troubleshooting.md](references/results-and-troubleshooting.md).
- **Endpoint configuration**: Read [setup.md](references/setup.md).
