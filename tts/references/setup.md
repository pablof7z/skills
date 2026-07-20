# TTS29 adapter setup

Install and start the standalone product from
<https://github.com/pablof7z/tts29>. The skill does not build it on first
use.

## Required

- Put the standalone `tts29` local producer CLI on `PATH`, or set
  `TTS29_CLI` to its executable path.
- Set `TTS29_SOCKET` to the private Unix socket owned by the running `tts29d`.
- Set `TTS29_GROUP_ID` to the daemon's configured NIP-29 group.

```bash
export TTS29_SOCKET="$HOME/.local/state/tts29/daemon.sock"
export TTS29_GROUP_ID="tts"
```

The daemon separately owns its NMP identity, Kokoro endpoint, Blossom endpoint,
journal, and store configuration. Do not copy those settings or secrets into
the skill directory.

## Optional

- `TTS29_VOICE` selects the Kokoro voice. Without it, the adapter derives one
  stable voice from `--agent-name`.
- `TTS29_REQUEST_ID` supplies a caller-owned retry key. Prefer the adapter's
  deterministic content-derived ID unless another system already owns one.
- `AGENT_NSEC` asks the daemon to publish this request as the agent identity.
  The adapter passes the environment through without reading or printing it.
- `--socket`, `--voice`, and `--request-id` override their corresponding
  process values for one invocation.

The configured group must match the daemon. The daemon identity must have
authority to add request-scoped agent publishers; TTS29 observes and repairs
membership through NMP before publication.

## Hosted assistants

Deploy the standalone `tts29-mcp` HTTPS/OAuth process. Do not run an MCP server
from the installed skill. Both local CLI and hosted MCP ingress converge on the
same daemon request lifecycle.
