# nsyte CLI reference

Use this reference for command selection and version-sensitive behavior. Prefer the installed command's `--help` output when it conflicts with this snapshot, then consult the current official documentation before changing the workflow.

## Authoritative sources

- Documentation: <https://nsyte.run/docs/>
- Configuration: <https://nsyte.run/docs/usage/configuration>
- Deploy command: <https://nsyte.run/docs/usage/commands/deploy>
- Deployment guide: <https://nsyte.run/docs/guides/deployment>
- Security guide: <https://nsyte.run/docs/guides/security>
- Source repository: <https://github.com/sandwichfarm/nsyte>

This reference was checked against those sources on 2026-08-04.

## Destination mapping

| User concept | Config field | Deploy flag | Expected scheme |
| --- | --- | --- | --- |
| Nostr relay | `relays` | `--relays` / `-r` | `wss://` |
| Blossom server | `servers` | `--servers` / `-s` | `https://` |

Both flags accept comma-separated URLs. Config fields accept arrays of URLs. Do not confuse Blossom servers with Nostr relays: files go to Blossom, while signed site-manifest events go to relays.

## Current deployment surface

The current documented workflow supports:

```text
nsyte deploy <folder>
  --relays <comma-separated-relays>
  --servers <comma-separated-servers>
  [--sec <credential> | --prompt-sec | stored bunker]
  [--name <site-name>]
  [--fallback <file>]
  [--dry-run]
  [--non-interactive]
```

`--dry-run` previews events and upload changes without publishing. `--no-config` ignores the project config, including useful signer and site settings, so use it only when the caller explicitly wants a fully flag-driven deployment.

Current deployment scans for secrets by default. Keep the explicit `nsyte scan` preflight because it creates a clear stop before signing or network publication.

## Persistent configuration

`.nsite/config.json` is project-relative. A minimal target configuration is:

```json
{
  "$schema": "https://nsyte.run/schemas/config.schema.json",
  "relays": [
    "wss://relay.example"
  ],
  "servers": [
    "https://blossom.example"
  ]
}
```

Validate it with `nsyte validate`. Preserve fields such as `id`, `fallback`, `bunkerPubkey`, `profile`, and app-handler configuration when changing only destinations.

Treat legacy `privateKey` fields as secrets. Do not print or commit the file when one is present. Prefer a bunker stored through the platform keychain instead of adding key material to project configuration.

## Authentication choices

Prefer, in order:

1. a stored NIP-46 bunker selected for the project;
2. `--prompt-sec` for an attended deployment;
3. `--sec "${NSYTE_DEPLOY_SECRET}"` for CI or another non-interactive environment, when the caller selected that variable name.

The unified `--sec` flag accepts nsec, nbunksec, bunker URL, or hex formats in current releases. Older releases used separate credential flags and may lack `--prompt-sec`, `--dry-run`, or `status`. Do not silently downgrade the safety workflow to match an old binary; surface the mismatch and offer the official upgrade path.

The official install command currently documented for macOS and Linux is:

```bash
curl -fsSL https://nsyte.run/get/install.sh | bash
```

Inspect scripts before piping them to a shell when the environment or user policy requires it. Ask before installing or replacing a global binary.

## Site and metadata kinds

- Root site: kind `15128`.
- Named site (`--name` or a non-empty config `id`): kind `35128`.
- Relay-list metadata: kind `10002`, root sites only.
- Blossom server-list metadata: kind `10063`, root sites only.
- Profile metadata: kind `0`, root sites only.
- NIP-89 app handler: kind `31990`.

Using a relay or server for deployment does not imply permission to publish its corresponding metadata list.

## Verification

Use `nsyte status --relays <relays> --full` after publishing. Current `status` reports relay coverage, manifest history, and per-Blossom-server availability. Use `nsyte debug --relays <relays> --verbose` to diagnose relay events, published server lists, server reachability, and sampled blob integrity.

Check the actual output rather than assuming that exit code zero means every endpoint accepted the publication. Record relay rejections and partial Blossom uploads separately.

If the installed version lacks `status`, report that post-deploy target verification is incomplete. Do not claim modern `status` evidence from `list` or `debug` alone.
