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
./scripts/tts \
  --agent-name "<seed-name>" \
  --subject "Choosing the implementation ownership boundary" \
  --ask \
  --suggestions '[["Use the existing model", "Keep the current ownership boundary."], ["Split the model", "Give questions an independent lifecycle."]]' \
  --message "Which direction should I take?"
```

Use suggestions only when they help the user answer faster or expose a real
tradeoff. Titles should be short; descriptions should explain the consequence.

## Structured question bundles

Use `--ask '<json>'` or `--ask @questions.json` for one or more related optional
questions. The bundle fields provide the spoken content, so do not combine a
structured `--ask` with `--message`. The JSON requires a nonempty `questions`
array and may include:

- Root `title`, `description`, and `attachments` shared by the bundle.
- Per-question `title`, `description`, `type`, `attachments`, and `suggestions`.
- Per-suggestion `title`, `description`, and `attachments`.

Question `type` defaults to `single_choice`. Use `multiple_choice` only when
several suggestions may be selected.

```bash
./scripts/tts \
  --agent-name "<seed-name>" \
  --subject "Choosing the rollout and notification plan" \
  --ask '{
    "title": "Release choices",
    "attachments": [{"path": "./context.md", "label": "Release context"}],
    "questions": [{
      "title": "Which rollout should I use?",
      "suggestions": [{
        "title": "Progressive",
        "description": "Start with a narrow cohort."
      }]
    }, {
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
- Suggestions are editable starting points, not locked answers. Editing exposes
  both the title and description.
- Freeform answers and suggestions open the same full editor, retain saved
  drafts when reopened, and accept dropped or selected files.
- For multiple choice, freeform text becomes an additional note alongside the
  selected suggestions.
- The user submits the entire bundle atomically. A blank question is skipped.

## Attachments

Add context attachments only when they materially help the decision:

- Root attachments provide context for the whole bundle.
- Question attachments provide context for one question.
- Suggestion attachments provide evidence or detail for one proposed answer.

These sources are copied durably, remain scoped to their owner, and are not read
as part of the main spoken question. Users can also drop files into their
freeform answer or attach them while editing a suggestion.

## Completion and lifecycle

The question remains visible after playback until the user submits it, hides it,
or it is superseded. The command remains active until submission or
supersession. Run it with the execution environment's asynchronous capability
when other work should continue. The tool output includes question status,
submitted answers, selected suggestion IDs, each selected suggestion's final
`title` and `description` under `selected_suggestions`, and answer-attachment
paths.

`--ask` is incompatible with `--no-play`.

Inspect or manage pending questions only when needed:

```bash
./scripts/tts-menu queue list --mine
./scripts/tts-menu queue get <id>
./scripts/tts-menu queue wait <id>
./scripts/tts-menu queue archive <id> --reason "No longer relevant."
./scripts/tts-menu queue restore <id>
./scripts/tts-menu queue supersede <old-id> \
  --superseded-by <replacement-id> \
  --reason "The replacement includes the missing nuance."
```

Archiving hides a question but does not cancel its pending answer. Only pending
questions may be superseded. If an answer and supersession race, the first
terminal operation wins.
