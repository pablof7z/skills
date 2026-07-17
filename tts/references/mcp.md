# TTS MCP

The MCP wrapper is a thin adapter over the durable TTS CLI and queue. It does
not implement a second synthesizer, player, question store, or pairing system.

## Start the server

Resolve `<skill-dir>` to the directory containing `SKILL.md`.

Stdio is the default:

```bash
<skill-dir>/scripts/tts-mcp
```

Authenticated Streamable HTTP runs on loopback by default:

```bash
export TTS_MCP_TOKEN="<at-least-24-random-characters>"
<skill-dir>/scripts/tts-mcp \
  --http \
  --host 127.0.0.1 \
  --port 8781 \
  --path /mcp
```

The endpoint is `http://127.0.0.1:8781/mcp`. Pass the token as
`Authorization: Bearer <token>`. HTTP mode validates Host and Origin headers,
rejects non-loopback binds, and exposes an unauthenticated minimal
`GET /healthz` probe. Public hosting is not implied by HTTP support; it requires
a separate HTTPS and OAuth deployment.

Use `--allow-origin` for an additional trusted browser origin. Use repeatable
`--allow-root` arguments when local MCP callers need to attach server-local
files. Attachment paths outside those roots and all symlink escapes are
rejected.

## Route ownership

The `--route` option controls where synthesis happens:

- `automatic`: ordinary speech follows the root TTS local-or-paired selection.
  Generation uses an approved pair when present and otherwise runs locally.
- `paired`: speech, questions, and generation are explicitly sent through the
  approved signed pairing to the computer that runs TTS.
- `local`: synthesis is forced onto the MCP host.

For an MCP server deployed on an agent environment paired to a TTS computer:

```bash
export TTS_MCP_TOKEN="<at-least-24-random-characters>"
<skill-dir>/scripts/tts-mcp --http --route paired
```

Keep the paired computer's `tts daemon` listener running. The MCP endpoint stays
on the agent environment; tool requests cross the existing Nostr pairing and
are materialized by the paired computer. The caller never receives a laptop
filesystem path.

Host-local attachments are intentionally rejected in explicit paired mode.
They are not silently published or copied to another computer.

Queue inspection and lifecycle tools operate on the state directory visible to
the MCP process. Spoken asks still return their paired answers directly through
the signed reply path.

## Tools

- `tts_speak`: generate and queue an audible update.
- `tts_ask`: present one to three structured questions and wait for a bounded
  answer.
- `tts_generate`: generate without playback, upload the MP3 to Blossom, and
  return only the hosted descriptor.
- `tts_status` and `tts_health`: inspect playback and route health.
- `tts_list_items` and `tts_get_item`: read bounded durable queue views.
- `tts_wait_for_item`: wait for an answer or terminal playback state.
- `tts_archive_items`, `tts_restore_items`, and
  `tts_supersede_questions`: apply audited lifecycle operations.

Persistent playback behavior remains owned by the TTS app Preferences rather
than MCP tools.

## Hosted generation

`tts_generate` is the MCP equivalent of `tts --no-play`, with an external result
contract:

1. It never queues playback.
2. In paired mode, the paired computer performs synthesis and upload.
3. The MP3 is uploaded with Blossom `PUT /upload` to
   `https://blossom.primal.net` by default.
4. The upload uses a short-lived Nostr kind `24242` authorization event scoped
   to the server hostname and exact MP3 SHA-256.
5. The result contains `status`, `url`, `sha256`, `size`, `type`, `uploaded`,
   and `server`; it never contains `output_file`.

Example structured result:

```json
{
  "status": "uploaded",
  "url": "https://blossom.primal.net/<sha256>.mp3",
  "sha256": "<sha256>",
  "size": 12345,
  "type": "audio/mpeg",
  "uploaded": 1784260000,
  "server": "https://blossom.primal.net"
}
```

The paired request and reply are readable signed kind `9` events. The reply
uses native tags for the URL, hash, size, MIME type, upload time, and server; it
does not hide the result in a JSON tag.

## Resources and privacy

The server exposes `tts://status`, `tts://health`, item records, generated audio,
and item attachments as MCP resources. Item views replace filesystem paths with
resource URIs and remove workspace paths, commands, terminal identifiers, and
answer attachment paths.

MCP request logs do not include message or answer bodies. HTTP mode requires a
token because TTS tools can create public audio and cause audible playback.
