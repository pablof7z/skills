# Answerable spoken questions

Every question is part of the same durable spoken item. Publication remains
complete even when the bounded answer observation times out.

## One freeform question

Use bare `--ask` and choose an explicit wait from one second through five
minutes:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<stable-agent-name>" \
  --subject "Release Decision" \
  --summary "One release decision remains." \
  --message "Should I publish the release candidate?" \
  --ask \
  --wait 5m
```

Optional suggestions use JSON pairs:

```bash
--suggestions '[["Publish", "Release the verified candidate."], ["Hold", "Keep it private for another review."]]'
```

Do not add an `Other` suggestion. TTS29 clients always permit a valid freeform
answer where appropriate.

## Structured questions

Use `--ask '<json>'` or `--ask @questions.json` for one to three questions. A
choice question requires suggestions; a freeform question must not have them.
Every question needs a very short `short_title` and a complete `title`.

```bash
<skill-dir>/scripts/tts \
  --agent-name "<stable-agent-name>" \
  --subject "Rollout Choices" \
  --summary "Two rollout choices remain." \
  --message "The candidate passed its checks." \
  --wait 5m \
  --ask '{
    "questions_preamble": "Two choices remain before release.",
    "questions": [{
      "short_title": "Rollout",
      "title": "Which rollout should I use?",
      "type": "single_choice",
      "suggestions": [{
        "title": "Progressive",
        "description": "Start with a narrow cohort."
      }, {
        "title": "Immediate",
        "description": "Release to everyone at once."
      }]
    }, {
      "short_title": "Notes",
      "title": "Is there anything else I should include?",
      "type": "freeform"
    }]
  }'
```

Supported types are `single_choice`, `multiple_choice`, and `freeform`.
Question IDs and option IDs are derived deterministically by the adapter. The
optional preamble is appended to the spoken body before the daemon synthesizes
it; individual question titles and descriptions remain structured event data.

## Result semantics

The JSON response always retains `request_id`, `receipt_id`, and `event_id` for
a published item. Its `answer_wait` is one of:

- `not_requested`;
- `answered`, carrying the durable answer bundle;
- `timed_out`, meaning the item remains published without an observed answer;
- `unavailable`, carrying a bounded failure code and message.

Do not retry publication with changed content under the same request ID. The
adapter derives a stable ID from immutable request content by default. Supply
`--request-id` only when the caller already owns a stable retry key.
