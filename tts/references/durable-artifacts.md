# Durable artifacts

TTS29 publishes complete artifact descriptors. The installed skill does not
read, copy, synthesize, upload, or host a local attachment.

Pass a descriptor as inline JSON or from a JSON file:

```bash
<skill-dir>/scripts/tts \
  --agent-name "<stable-agent-name>" \
  --subject "Design Review" \
  --summary "The durable design artifact is ready." \
  --message "The design is ready for review." \
  --artifact '{
    "url": "https://cdn.example/design.pdf",
    "sha256": "<64 lowercase hex characters>",
    "media_type": "application/pdf",
    "byte_count": 12345,
    "label": "Design proposal"
  }'

<skill-dir>/scripts/tts ... --artifact @artifact.json
```

Each descriptor requires exactly:

- an HTTPS URL;
- the exact lowercase SHA-256 digest;
- a MIME type;
- a byte count from 1 through 250 MiB; and
- a nonempty human label.

At most 12 descriptors may accompany one item. TTS29 validates the same
contract again before publication.

Legacy `--attach "Label" ./local-file` input is intentionally rejected. A
future product-owned upload surface may turn local bytes into a descriptor; do
not rebuild Blossom credentials, signing, upload, or local durable storage in
this skill.
