# Rich Content

Read this reference when a spoken update includes attachments or formatted
code.

## Attachments

Use repeatable `--attach "Label" path` pairs and pass the primary body with
`--message`:

```bash
./scripts/tts \
  --agent-name "<seed-name>" \
  --subject "Supporting artifacts for the implementation update" \
  --message "The implementation is ready. I attached the proposal and mockup." \
  --attach "Architectural proposal" ./proposal.md \
  --attach "Mockup" ./mockup.svg
```

Prefer short human labels such as `Mockup`, `Architectural proposal`, or
`Detailed findings`. Do not expose raw filenames when a clearer label exists.

Markdown and text attachments are copied into durable storage and narrated
before the command returns. Images and SVGs preview inline, Mermaid (`.mmd`)
files render as diagrams with source fallback, existing audio is playable, and
other files open in their default application.

Treat attachments as optional branches. Do not attach routine logs, duplicate
the primary message, or create supplemental files merely to make an update look
substantial.

## Formatted code

Use a language-tagged fenced block for code that should remain visible but not
be spoken. Follow it with a `["…"]` speech-only description:

````markdown
Here is the proposed API:

```ts
const event = new NDKEvent();
await event.sign();
```
["The example creates an event and signs it without broadcasting."]
````

Tagged code blocks are syntax-highlighted and skipped in speech. The bracketed
description is spoken but hidden from the transcript. Read-along highlighting
resumes with the next visible spoken word.

Use an untagged fenced block only when the literal snippet, path, or command
should be read aloud as plain text.
