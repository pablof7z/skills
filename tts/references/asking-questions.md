# Asking Questions

Read this reference before using `--ask`.

## Contents

- [One question](#one-question)
- [Structured question bundles](#structured-question-bundles)
- [Suggestions and answer UI](#suggestions-and-answer-ui)
- [Attachments](#attachments)
- [Completion and lifecycle](#completion-and-lifecycle)

Always pass the stable agent seed name and session subject required by the root
skill.

## One question

Use bare `--ask` with `--message` for one question. Offer optional answer ideas
with `--suggestions` as JSON title-and-description pairs:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "Choosing the implementation ownership boundary" \
  --ask \
  --wait 5m \
  --suggestions '[["Use the existing model", "Keep the current ownership boundary."], ["Split the model", "Give questions an independent lifecycle."]]' \
  --message "Which direction should I take?"
```

Use suggestions only when they help the user answer faster or expose a real
tradeoff. Titles should be short; descriptions should explain the consequence.

## Structured question bundles

Use `--ask '<json>'` or `--ask @questions.json` for one or more related optional
questions. Always provide the main spoken update with `--message`; it gives the
user the reasoning and context that comes before the questions. The player
keeps that primary message visible above the question UI. Positional message
text is not accepted for structured asks. The JSON requires a nonempty
`questions` array and may include:

- An optional root `questions_preamble` that transitions from the update into
  the questions.
- Per-question `short_title`, `title`, `description`, `type`, `attachments`, and
  `suggestions`.
- Per-suggestion `title`, `description`, and `attachments`.

Use `questions_preamble` only when a transition adds clarity. It is spoken
immediately after `--message`, so make it a short high-level explanation of
what remains to decide without restating the update or listing the questions.
For example: `There are two release details to settle before I finish.` Root
`title`, `description`, and `attachments` are not supported.

Every question requires both `short_title` and `title`. Keep `short_title` very
short—usually two to four words—because it labels a narrow tab. Put the full,
natural question in `title`; do not shorten the actual question to fit the tab.
Individual question titles and descriptions are displayed but are not spoken.

Question `type` defaults to `single_choice`. Use `multiple_choice` only when
several suggestions may be selected.

```bash
<skill-dir>/scripts/tts \
  --agent-name "<seed-name>" \
  --subject "Choosing the rollout and notification plan" \
  --message "The release candidate passed its automated checks. I narrowed the remaining decisions to rollout risk and who needs advance notice." \
  --wait 5m \
  --ask '{
    "questions_preamble": "There are two release details to settle before I finish.",
    "questions": [{
      "short_title": "Rollout",
      "title": "Which rollout should I use?",
      "suggestions": [{
        "title": "Progressive",
        "description": "Start with a narrow cohort."
      }]
    }, {
      "short_title": "Notifications",
      "title": "Which teams should I notify?",
      "type": "multiple_choice",
      "suggestions": [{"title": "Support"}, {"title": "Operations"}]
    }]
  }'
```

Attachment entries may be path strings or objects with `path` plus optional
`label` and `description`.

## Suggestions and answer UI

The player always gives the user a freeform answer editor. Never add `Something
else`, `Other`, or an equivalent catch-all suggestion.

- Single-choice questions present suggestions as radio-style choices.
- Multiple-choice questions present suggestions as checkboxes.
- Suggestions are editable starting points, not locked answers. Editing replaces
  the suggestion's displayed title and description in place.
- Freeform answers and suggestions open the same modeless editor, so the user can
  continue using the question window and its attachments. `Done` applies the
  edit; `Cancel`, the close control, and Escape discard it. Applied drafts are
  restored when the editor is reopened. Dropped or selected files are accepted.
- For multiple choice, freeform text becomes an additional note alongside the
  selected suggestions.
- The user submits the entire bundle atomically. A blank question is skipped.

## Attachments

Add context attachments only when they materially help the decision:

- Question attachments provide context for one question.
- Suggestion attachments provide evidence or detail for one proposed answer.

If the main spoken update itself needs attachments, use the ordinary
top-level `--attach` option rather than putting attachments in the ask JSON.

These sources are copied durably, remain scoped to their owner, and are not read
as part of the main spoken question. Users can also drop files into their
freeform answer or attach them while editing a suggestion.

## Completion and lifecycle

The question remains visible after playback until the user submits it, hides it,
or it is superseded. The command remains active until submission or
supersession or until its bounded wait expires.

Every `--ask` requires `--wait <duration>`, such as `--wait 30s`, `--wait 5m`,
or `--wait 1h`. Choose the interval based on whether the answer blocks useful
work. The command blocks during that interval. If the user answers, its final
output contains the submitted answers, selected suggestion IDs, each selected
suggestion's final `title` and `description` under `selected_suggestions`, and
answer-attachment paths.

If the interval expires first, the command returns a `pending` result instead
of hanging indefinitely. That result tells you how long it waited and includes
an exact `wait_command`. Decide whether the answer is important at that point:
continue other work without waiting, or run the supplied command to block for
another explicitly bounded interval. Queue waits always require `--timeout`;
there is no indefinite wait form.

`--ask` is incompatible with `--no-play`.

Inspect or manage pending questions only when needed:

```bash
<skill-dir>/scripts/tts-menu queue list --mine
<skill-dir>/scripts/tts-menu queue get <id>
<skill-dir>/scripts/tts-menu queue wait <id> --timeout 5m
<skill-dir>/scripts/tts-menu queue archive <id> --reason "No longer relevant."
<skill-dir>/scripts/tts-menu queue restore <id>
<skill-dir>/scripts/tts-menu queue supersede <old-id> \
  --superseded-by <replacement-id> \
  --reason "The replacement includes the missing nuance."
```

Archiving hides a question but does not cancel its pending answer. Only pending
questions may be superseded. If an answer and supersession race, the first
terminal operation wins.
