# Trust And Proof

Use when the repo makes claims about speed, security, privacy, local-first
behavior, maturity, compatibility, adoption, freshness, editions, provenance,
locale/market fit, or sensitive data.

## Hero Proof

Add at least one proof artifact near the first screen:

- GIF
- screenshot
- terminal recording
- short architecture diagram
- before/after image
- benchmark table
- generated output example
- one-line integration snippet
- sample report
- sample config
- small demo video

If the project has a UI, TUI, visual output, workflow, or generated artifact,
include visual proof above the fold.

## Claim-Proof Fit

Do not let one screenshot, benchmark, badge, or demo carry every claim.

Build a claim-proof map:

| Claim | Proof required | Evidence in repo | Gap |
| --- | --- | --- | --- |
| Sub-60ms startup | benchmark setup, sample size, p95/p99, hardware | docs/benchmarks.md | |
| 100% local/private | data boundary, storage path, telemetry statement, threat limits | SECURITY.md + README trust note | |
| Production-grade | real adoption, deployment history, package stats, case study | current README | needs source |
| Works with 11 agents | compatibility matrix or install/test path per host | docs/install.md | |

Use the right evidence for the claim:

| Claim type | Matching proof |
| --- | --- |
| Speed or scale | benchmark numbers, hardware/context, p50/p95/p99 when relevant, comparison baseline |
| Security or privacy | trust boundary, threat model, audit, signed releases, checksums, reproducible-build status, data-flow statement |
| Local-first | what stays local, where state is stored, what network calls happen, opt-in cloud paths |
| Compatibility | tested platform matrix, supported versions, host-specific install snippets, CI coverage |
| AI quality | sample outputs, evals, reviewer loop, before/after example, failure cases |
| Maturity or stability | release channel, beta/canary/stable labels, breaking-change policy, version guarantees |
| Adoption or production proof | real usage numbers, provenance, package downloads, case studies, credible users |
| Coverage | exact language/provider/platform count and how that count is maintained or tested |

Rules:

- Remove or soften any front-door claim with no matching proof.
- Put the strongest matching proof near the claim.
- Name benchmark conditions when the number affects adoption.
- For privacy/security tools, include limitations alongside proof.
- For beta, canary, preview, or pre-1.0 projects, state what is stable and what may break.

## Freshness, Edition, And Provenance Ledger

Fast-moving repos often fail because the reader cannot tell what is current,
stale, reproducible, paid, or experimental. This is a trust surface.

Use a ledger for:

- living catalogs, prompt archives, provider lists, model/tool matrices, benchmark tables
- demo galleries where cost, provider choice, source assets, or reproducibility matters
- community/pro/enterprise splits or local/hosted editions
- beta, canary, preview, experimental, unreleased, or internal-only packages
- claims based on production provenance, press coverage, recent updates, or recovered artifacts

Example:

| Surface | Current status | Evidence | Reader decision |
| --- | --- | --- | --- |
| Community Edition | Free, local, open source | release link | Good for local notes |
| Pro | Paid, separate workflow | pricing/features link | Use for team exports and speaker ID |
| `@pkg/charts` | Canary only, no stable release | package note | Do not depend on it for stable production |
| Demo trailer | Prompt, pipeline, tools, and cost listed | video + run notes | Reproduce or compare cost |

Rules:

- Put the ledger above setup when freshness or edition determines whether the reader should try the repo.
- Do not let badges substitute for the ledger.
- For catalogs and archives, date each entry or group and distinguish official, recovered, generated, archived, and community-submitted material.
- For demos, include prompt or scenario, pipeline/tool path, provider/model choices, cost when material, source assets, and whether generated media, real footage, or hand-authored assets are used.
- For products with editions, separate free/open/local from paid/hosted/pro/enterprise and label planned features as planned.
- If status can change, show the update path: policy, cadence, diff links, changelog, or source-of-truth file.

## Locale And Market Fit

Some repos are globally useful in shape but local in their first integrations.
A strong README separates the universal workflow from regional adapters.

Use when the repo depends on:

- regional job boards, social networks, marketplaces, government sources, finance sources, health sources, or media platforms
- country-specific accounts, phone numbers, identity flows, proxies, compliance assumptions, payment rails, or package managers
- language-specific prompts, examples, skills, docs, or user-facing commands
- translated READMEs where each language needs the same adoption-critical truth

Good:

```md
## Fit Check

- The application workflow is language- and country-agnostic.
- The bundled search adapters target Denmark: Jobindex, Jobnet, and Akademikernes Jobbank.
- Replace or add adapters for your local boards with `/add-portal`.
```

Rules:

- Put the market boundary near setup when it decides whether the reader can use the repo today.
- Name the universal core separately from local integrations.
- Do not hide a regional constraint inside a feature list.
- If translations exist, keep each translation honest about install, trust, pricing, and fit constraints.
- If the useful activation phrase is in a specific language, show it in that language and explain which hosts or agents can execute it.
- For region-specific platforms, include account/login/proxy/cookie expectations and risks such as account restriction or rate limiting.

## Trust Adjacency

If the first command or demo touches code, local files, browser state, cloud
APIs, secrets, Docker, private data, wallets, relays, security targets, or
identity material, place a short trust boundary directly beside that command.

Example:

```md
This reads files under `./app`, writes results to `tool_runs/`, starts a Docker sandbox, and sends prompts to the model provider configured in `TOOL_LLM`.
```

Required for repos that:

- execute shell commands
- read/write arbitrary files
- touch credentials, cookies, wallets, relays, signatures, or identity material
- use browser sessions or private data
- send network requests on behalf of the user
- install services, hooks, plugins, or agent entries
- store local memory, transcripts, recordings, indexes, caches, credentials, or reports

Include:

- what it reads
- what it writes
- where state lives
- what leaves the machine
- what credentials are read and where they stay
- telemetry behavior
- known limitations

## Install Footprint And Reversibility

For installers, MCP servers, agent skills, plugins, hooks, CLIs, browser tools,
or local apps that modify user state, include:

- files, configs, hooks, services, credentials, caches, and local state created
- how to inspect or dry-run when available
- update path
- disable/uninstall path
- whether user data is kept or removed

Good:

```md
## Install Footprint

- Adds an MCP server entry to your agent config.
- Installs the binary under `~/.local/bin`.
- Stores indexes under `~/.cache/tool`.
- Run `tool uninstall` to remove config entries; add `--purge` to delete cached data.
```
