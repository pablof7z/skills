---
name: deploy-nsites
description: Deploy static websites as nsites with the nsyte CLI while targeting caller-selected Nostr relays and Blossom servers. Use when Codex needs to initialize, preview, publish, or verify an nsite; configure `.nsite/config.json`; override relay or Blossom destinations for one deployment; or diagnose whether manifests and blobs reached the requested endpoints.
---

# Deploy nsites

Publish a static build directory to explicit Nostr relay and Blossom storage targets. Keep signing material private and distinguish a successful command from verified delivery to every requested endpoint.

Read [references/nsyte-cli.md](references/nsyte-cli.md) before installing nsyte, editing persistent configuration, choosing compatibility fallbacks, or using commands beyond the core workflow below.

## Establish the deployment contract

Collect or discover:

- the project root and exact static build directory;
- one or more `wss://` relay URLs;
- one or more `https://` Blossom server URLs;
- whether targets should apply only to this invocation or persist in `.nsite/config.json`;
- the signer route: a stored NIP-46 bunker, an interactive secret prompt, or a named environment variable containing a CI credential;
- whether this is the root site or a named site.

Require the relay and Blossom lists before publishing. Do not invent endpoints, add nsyte fallbacks, or replace an unreachable target without the user's direction. Default to per-invocation overrides when persistence was not requested.

Treat “relay” as the Nostr destination for signed site events and “Blossom server” as the HTTP storage destination for file blobs. nsyte calls the latter `servers` in its config and CLI.

## Inspect nsyte and the project

Run from the project root because nsyte resolves `.nsite/config.json` there.

```bash
command -v nsyte
nsyte --version
nsyte deploy --help
nsyte status --help
```

Confirm that the installed CLI exposes `deploy --relays`, `deploy --servers`, `deploy --dry-run`, and `status`. If nsyte is missing or too old, report the exact missing capability and ask before installing or upgrading a global binary.

Inspect the build directory before uploading. Confirm that it exists, is non-empty, contains the expected entry point, and does not accidentally include configuration, source maps, credentials, or private artifacts.

## Configure destinations

For a one-off deployment, leave project configuration unchanged and pass both lists explicitly:

```bash
nsyte deploy "$DEPLOY_DIR" \
  --relays "$RELAY_CSV" \
  --servers "$BLOSSOM_CSV"
```

Construct each comma-separated value directly from the validated URL list. Do not use `eval` or interpolate a credential into a generated command string.

For persistent configuration, create `.nsite/config.json` with `nsyte init` when appropriate, or edit the existing JSON while preserving unrelated fields. Set only these target fields unless the user asked for other changes:

```json
{
  "$schema": "https://nsyte.run/schemas/config.schema.json",
  "relays": ["wss://relay.example"],
  "servers": ["https://blossom.example"]
}
```

Then run:

```bash
nsyte validate
```

Never print the full config if it contains `privateKey`, a bunker URL, or another credential. Never commit signing material. Continue to pass `--relays` and `--servers` explicitly during the requested deployment so the execution record names the actual destinations.

## Handle signing safely

Prefer a stored NIP-46 bunker configured by `nsyte init` or `nsyte bunker use`. For interactive use, prefer `--prompt-sec` when the installed CLI supports it. For non-interactive deployment, accept the name of a pre-populated secret variable and expand it only at execution. In this example the caller selected `NSYTE_DEPLOY_SECRET`:

```bash
nsyte deploy "$DEPLOY_DIR" \
  --relays "$RELAY_CSV" \
  --servers "$BLOSSOM_CSV" \
  --non-interactive \
  --sec "${NSYTE_DEPLOY_SECRET}"
```

Do not request that a user paste an `nsec`, `nbunksec`, bunker URL, or hex key into chat. Do not echo, log, inspect, or persist the value. Disable shell tracing around any command that expands it.

## Preview and publish

Run the explicit secret scan first, even though current nsyte versions also scan during deployment:

```bash
nsyte scan "$DEPLOY_DIR" --scan-level medium
```

Preview with the exact targets and site options intended for the live run:

```bash
nsyte deploy "$DEPLOY_DIR" \
  --relays "$RELAY_CSV" \
  --servers "$BLOSSOM_CSV" \
  --dry-run
```

Review the preview for the expected site identity, manifest kind, file set, relay list, and Blossom list. If the user asked to deploy, proceed with the same arguments minus `--dry-run`; that request authorizes publication and does not require a redundant confirmation. If the user asked only to configure or preview, stop before the live command.

Do not add `--use-fallback-relays`, `--use-fallback-servers`, `--use-fallbacks`, `--force`, `--skip-secrets-scan`, or metadata-publication flags unless explicitly requested and justified by the task.

## Verify the real targets

Treat the live deploy exit code as necessary but insufficient evidence. Preserve the non-secret output and check that it reports successful blob uploads and relay publication without rejected targets.

Query the same relay set after deployment:

```bash
nsyte status --relays "$RELAY_CSV" --full
```

Use `nsyte debug --relays "$RELAY_CSV" --verbose` when status reports missing events or blobs. `status` should show the manifest found on the selected relays and per-server file availability, including the requested Blossom servers carried by the manifest/config.

Report requested and confirmed destinations separately:

- relay URLs requested, accepted during deploy, and observed during status;
- Blossom URLs requested, uploaded successfully, and confirmed available;
- root or named site identity and the deployed directory;
- any rejection, missing blob, unavailable endpoint, or verification command absent from the installed version.

Call the result complete only when every requested target is confirmed. Report partial delivery precisely instead of collapsing it into success.

## Respect destructive and metadata boundaries

Do not run `delete`, `undeploy`, legacy `purge`, or blob deletion commands unless the user explicitly asks to remove published data.

Do not publish profile, relay-list, server-list, or app-handler metadata merely because those destinations were used for deployment. These are separate signed events. Profile, relay-list, and server-list publication is valid only for a root site.
