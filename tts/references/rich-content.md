# Rich Content

Read this reference when a spoken update includes attachments or formatted
code.

## Attachments

Use repeatable `--attach "Label" path` pairs and pass the primary body with
`--message`:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "Implementation Artifacts" \
  --summary "The proposal and mockup provide the supporting implementation context." \
  --message "The implementation is ready. I attached the proposal and mockup." \
  --attach "Architectural proposal" ./proposal.md \
  --attach "Mockup" ./mockup.svg
```

Prefer short human labels such as `Mockup`, `Architectural proposal`, or
`Detailed findings`. Do not expose raw filenames when a clearer label exists.

To open an attachment directly from the primary message, use a Markdown link
whose visible text exactly matches the attachment label and whose destination
is `attachment:`:

```markdown
The decision and tradeoffs are in the [Architectural proposal](attachment:).
```

Pair that message with `--attach "Architectural proposal" ./proposal.md`.
Keep the label in the visible link text; do not put a path or label after
`attachment:`. The player only activates a unique exact label match, so a
missing or duplicated label stays inert rather than opening the wrong file.

Markdown and text attachments are copied into durable storage and narrated
before the command returns. Images and SVGs preview inline, Mermaid (`.mmd`)
files render as diagrams with source fallback, existing audio is playable, and
other files open in their default application.

Each narrated Markdown or text attachment has a hard limit of 2,000 words after
formatting-only content is removed. Summarize or split longer narration into
focused attachments. Raw logs, process samples, and similar evidence should use
a non-text extension so they remain available as files without being narrated.

Treat attachments as optional branches. Do not attach routine logs, duplicate
the primary message, or create supplemental files merely to make an update look
substantial.

## Spoken Markdown

Use short Markdown headings and lists when they make the visible transcript
easier to scan. Phrase headings as natural spoken labels. They do not need
manual terminal punctuation: the runtime keeps the original Markdown visible
while removing formatting markers and preserving audible pauses between
headings, paragraphs, and list items.

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
