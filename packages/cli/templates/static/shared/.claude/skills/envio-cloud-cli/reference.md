# Envio Cloud reference

Facts to look up while following SKILL.md. Plans and prices change; when a number matters to the user's decision, confirm it at https://envio.dev/pricing/hosting.

## What Envio Cloud offers

Use these when the user asks why or whether to host on Envio Cloud, or which plan to pick.

- **Push to deploy.** Envio Cloud builds from GitHub: push to the indexer's branch and it deploys, or deploy chosen commits by hand with auto-deploy off. Monorepos work through the root dir setting, and one repo can hold several indexers.
- **No HyperSync token to manage.** Indexers on Envio Cloud reach HyperSync without `ENVIO_API_TOKEN`.
- **Zero-downtime upgrades** (Production): a new deployment syncs alongside the current one, then promotion switches the static production endpoint to it. Promoting an older deployment rolls back.
- **Built-in operations:** logs, metrics and sync status in the CLI and dashboard; on Production, alerts to Discord, Slack, Telegram or email (set up in the dashboard), backups, and no auto-deletion.
- **Endpoint security:** API-key auth and IP allow-lists per indexer, kept across promotions.
- **Effect API cache** saved and restored from the dashboard, on Production Medium and up.
- **Multichain indexing** on every plan.
- **No lock-in:** the same indexer runs self-hosted with Docker and any RPC. The licence allows self-hosting for your own projects, not reselling it as a hosted service.
- **Dedicated:** direct SQL access, ClickHouse and a hosted analytics portal as add-ons, regions in the US, EU and Japan with automatic failover, a written SLA up to 99.99% uptime, and on-call engineers. Sized and priced per workload: https://envio.dev/pricing/hosting.
- **Subgraph-compatible endpoint** add-on on Production plans, for apps that query a subgraph today.

## Plans

| | Development | Production | Dedicated |
|---|---|---|---|
| Price | Free | From $70/month, 800 indexing hours included | Custom |
| Endpoint | Per deployment, changes with each one | Static production endpoint, zero-downtime promotion | Static, multi-region |
| Lifetime | At most 30 days, see [limits](#limits) | No auto-deletion | No auto-deletion |
| Backups | None | Yes | Multi-region |
| Alerts, IP allow-list, cache management | No | Yes | Yes |
| Use for | Testing and trying things | Anything people rely on | Large or critical workloads |

An indexing hour is one deployment running for one hour; one always-on deployment uses about 730 a month, so running a second deployment alongside (for a zero-downtime upgrade) uses extra hours.

Recommend Production when the user wants a stable URL, a public app, or data that must outlive 30 days. Upgrading is the user's decision: it costs money and happens in the dashboard.

## Limits

- **Per organisation:** 3 Development plan indexers.
- **Per indexer:** 3 deployments. Delete an old one before deploying another.
- **Development plan deletion:** deployments over 20 GB or older than 30 days are deleted. Reaching 100,000 events processed or 5 GB of storage starts a 7-day grace period, then 3 days read-only, then deletion. A deployment with no queries for 7 days gets a warning and is deleted 24 hours later unless it receives a query. Upgrading keeps the indexer running.
- **Builds** stop after about 30 minutes. Failed deployments are marked for deletion after a while.
- **Paused indexers** don't deploy pushes: usually an unpaid bill, or Development limits. The user settles it in the dashboard and contacts Envio.
- **Members** with the `reader` role don't trigger auto-deploys. People must be in the GitHub organisation and added by an Envio organisation admin on the Members page.
- **Renaming the GitHub organisation** stops deployments until Envio fixes it; contact them first.

## Requirements

What a commit needs to build on Envio Cloud (`scripts/cloud.mjs check` covers the first four):

- `package.json` in the indexer's root dir with an exact `envio` version: at least `2.21.5`, not `2.29.x`. Ranges, `latest` and `workspace:*` are rejected.
- Everything the indexer imports or reads is inside the root dir. Only that folder is uploaded.
- Nothing it needs sits in a folder named `generated` or `node_modules`, or in a dot folder other than `.envio`. Dotfiles other than `.npmrc` are skipped too. Skipped files vanish silently and the build fails later.
- Everything is committed and pushed to the indexer's branch.
- Dependencies resolve fresh on every build and the lockfile isn't used, so pin exact versions if a build behaves differently from local.
- The repo is at most 100 MB. Node 24 or newer is recommended.

## Commit statuses

From `npx -y envio-cloud indexer commits <indexer> <org> -o json` (fields `commit_hash`, `commit_message`, `branch`, `created_time`, `status`, `envio_version`):

| Status | Meaning | Do |
|---|---|---|
| `pending` | Still being processed | Wait |
| `deploy` | Deployment starting | Wait |
| `active` | Has a deployment | Wait for sync |
| `inactive` | Not deployed: auto-deploy off, or the deployment / indexing-hour limit | `deployment deploy`, after freeing a slot if at 3 deployments |
| `deletingDeploymemt` | Its deployment is being deleted | Push a new commit to deploy again |
| `configFileMissing` | Config file not found | Fix `--config-file` (relative to the root dir) or `--root-dir` |
| `packageJsonMissing` | No `package.json` in the root dir | Fix `--root-dir` |
| `failedToDownload` | Couldn't fetch the commit from GitHub | Check the root dir and the GitHub App's access, push again |
| `versionNotSupported` | Unsupported `envio` version | Pin a supported exact version |
| `clickhouseConfigMismatch` | `storage.clickhouse` doesn't match the indexer's setup | Align the config with the plan |
| `clickhouseVersionNotSupported` | ClickHouse needs envio 3.0.2+ | Upgrade envio |

## Commands

Deployment commands take `<indexer> <commit> [org]`; most others take `<indexer> [org]`. Every command has `--help` with examples.

- **Auth and context:** `login [--token <t>]`, `logout`, `token`, `config set-org|set-indexer|get-context|clear`
- **Repos:** `repos [-o json]` (connected repos, with their indexers; JSON is a bare list)
- **Indexers:** `indexer list [--org <o>]`, `indexer get`, `indexer add`, `indexer commits [--limit <n>]`, `indexer settings get|set`, `indexer env list|set|delete|import`, `indexer security ...`, `indexer delete --yes`
- **Deployments:** `deployment deploy`, `status [--watch-till-synced]`, `logs [--build] [--level <l>] [--since <d>] [--limit <n>] [--follow]`, `endpoint` (bare URL; exit 2 before the deployment is scheduled), `info` (cache, DB exposure), `tags list|set|remove`, `promote --yes`, `restart --yes`, `delete --yes`

## Scripting

- `-o json` prints `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`. Informational lines go to stderr, so don't merge stderr into JSON you parse (`2>&1`). Check the exit code first: 0 success, 1 user error, 2 server error. Some errors print only to stderr.
- `indexer get -o json` → `data.deployments[]` with `commit_hash`, `prod_status` (`none`, `pending`, `prod`) and `gql_endpoint`. For an indexer that doesn't exist it returns `{"ok": true}` with no `data`.
- `deployment status -o json` → one entry per chain with `block_height`, `latest_processed_block` and `is_ready`. An empty list means no progress yet.
- Commands that ask for confirmation (`add`, `deploy`, `promote`, `restart`, `delete`, `security api-key ...`) take `--yes`. Without an answer they're cancelled and do nothing.
