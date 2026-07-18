# Results and troubleshooting

## Successful publication

The adapter prints the standalone CLI's JSON response. A successful result has
`status: published`, the stable request ID, NMP receipt ID, signed event ID, and
the bounded answer-wait result. These prove durable publication; they do not
prove that a player was open or that a person heard the item.

## Common failures

- `TTS29_CLI` unavailable: install the standalone product or correct the
  executable path.
- `TTS29_SOCKET` missing or connection refused: configure and start `tts29d`.
- `TTS29_GROUP_ID` rejected: make the adapter group match the daemon group.
- request conflict: reuse a request ID only with byte-for-byte equivalent
  immutable input and the same author.
- membership or receipt rejection: inspect the daemon's retained NMP evidence;
  do not add a raw Nostr fallback to the skill.
- synthesis, Blossom, or journal failure: diagnose the standalone daemon
  capability and retry the same immutable request.
- `timed_out` answer wait: publication succeeded. Continue useful work or issue
  a new explicit observation through a supported TTS29 surface; do not infer an
  answer.

The retired `tts-menu`, pairing, local queue, playback, generation-only, and
skill-hosted MCP commands are not diagnostic fallbacks. Use standalone TTS29
client and daemon tooling instead.
