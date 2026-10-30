# Envio Cloud reference

Facts to look up while following SKILL.md. Plans and prices change; confirm any number that matters at https://envio.dev/pricing/hosting.

## What Envio Cloud offers

For when the user asks why host on Envio Cloud, or which plan to pick.

- **Push to deploy** from GitHub, or deploy chosen commits by hand with auto-deploy off. Monorepos work through the root dir; one repo can hold several indexers.
- **HyperSync without `ENVIO_API_TOKEN`.**
- **Zero-downtime upgrades** (Production): a new deployment syncs alongside, then promotion moves the static endpoint to it. Promoting an older one rolls back.
- **Operations:** logs, metrics and sync status in the CLI and dashboard. Production adds alerts (Discord, Slack, Telegram, email), backups and no auto-deletion.
- **Endpoint security:** API keys and IP allow-lists per indexer, kept across promotions.
- **Effect API cache** save and restore, Production Medium and up.
- **Multichain** on every plan.
- **No lock-in:** the same indexer runs self-hosted with Docker and any RPC (for your own projects, not resold as a hosted service).
- **Dedicated:** SQL access, ClickHouse, an analytics portal, US/EU/Japan regions with failover, SLA up to 99.99%, on-call engineers. Priced per workload.
- **Subgraph-compatible endpoint** add-on on Production.

## Plans

| | Development | Production | Dedicated |
|---|---|---|---|
| Price | Free | From $70/month, 800 indexing hours included | Custom |
| Endpoint | Per deployment, changes each time | Static, zero-downtime promotion | Static, multi-region |
| Lifetime | At most 30 days, see [limits](#limits) | No auto-deletion | No auto-deletion |
| Backups | None | Yes | Multi-region |
| Alerts, IP allow-list, cache | No | Yes | Yes |
| For | Testing | Anything people rely on | Large or critical workloads |

One deployment running an hour is one indexing hour; an always-on deployment uses about 730 a month, so a second one alongside (for an upgrade) costs extra.

Recommend Production for a stable URL, a public app, or data that must outlive 30 days. Upgrading costs money, so it's the user's call, made in the dashboard.

## Limits

- **Per organisation:** 3 Development indexers.
- **Per indexer:** 3 deployments; delete one before deploying another.
- **Development deletion:** over 20 GB or older than 30 days. At 100,000 events or 5 GB: 7 days' grace, 3 days read-only, then deletion. No queries for 7 days: a warning, then deletion 24 hours later unless queried. Upgrading keeps it running.
- **Builds** stop after about 30 minutes. Failed deployments are deleted after a while.
- **Paused indexers** don't deploy: usually an unpaid bill or Development limits. The user settles it in the dashboard and contacts Envio.
- **Members** with the `reader` role don't trigger auto-deploys. Members must be in the GitHub organisation and added by an Envio admin on the Members page.
- **Renaming the GitHub organisation** stops deployments until Envio fixes it; contact them first.

## Requirements

What a commit needs to build (`scripts/cloud.mjs check` covers the first four):

- `package.json` in the root dir with an exact `envio` version, at least `2.21.5` and not `2.29.x`. No ranges, `latest` or `workspace:*`.
- Everything the indexer imports or reads is inside the root dir; only that folder is uploaded.
- Nothing it needs is in `generated`, `node_modules`, or a dot folder other than `.envio`. Dotfiles other than `.npmrc` are skipped. Skipped files vanish silently and the build fails later.
- Everything is committed and pushed to the indexer's branch.
- The lockfile isn't used, so pin exact dependency versions if a build differs from local.
- Repo at most 100 MB. Node 24+ recommended.

## Commit statuses

From `npx -y envio-cloud indexer commits <indexer> <org> -o json` (fields `commit_hash`, `commit_message`, `branch`, `created_time`, `status`, `envio_version`):

| Status | Meaning | Do |
|---|---|---|
| `pending` | Processing | Wait |
| `deploy` | Deployment starting | Wait |
| `active` | Deployed | Wait for sync |
| `inactive` | Not deployed: auto-deploy off, or a deployment / indexing-hour limit | `deployment deploy`, after freeing a slot if at 3 |
| `deletingDeploymemt` | Deployment being deleted | Push a new commit |
| `configFileMissing` | Config file not found | Fix `--config-file` (relative to the root dir) or `--root-dir` |
| `packageJsonMissing` | No `package.json` in the root dir | Fix `--root-dir` |
| `failedToDownload` | Couldn't fetch from GitHub | Check the root dir and the GitHub App's access, push again |
| `versionNotSupported` | Unsupported `envio` version | Pin a supported exact version |
| `clickhouseConfigMismatch` | `storage.clickhouse` doesn't match the indexer | Align the config with the plan |
| `clickhouseVersionNotSupported` | ClickHouse needs envio 3.0.2+ | Upgrade envio |

## Commands

Deployment commands take `<indexer> <commit> [org]`; most others `<indexer> [org]`. Every command has `--help`.

- **Auth and context:** `login [--token <t>]`, `logout`, `token`, `config set-org|set-indexer|get-context|clear`
- **Repos:** `repos [-o json]` (connected repos and their indexers; JSON is a bare list)
- **Indexers:** `indexer list [--org <o>]`, `get`, `add`, `commits [--limit <n>]`, `settings get|set`, `env list|set|delete|import`, `security ...`, `delete --yes`
- **Deployments:** `deployment deploy`, `status [--watch-till-synced]`, `logs [--build] [--level <l>] [--since <d>] [--limit <n>] [--follow]`, `endpoint` (bare URL; exit 2 until scheduled), `info` (cache, DB exposure), `tags list|set|remove`, `promote --yes`, `restart --yes`, `delete --yes`

## Scripting

- `-o json` prints `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`. Info lines go to stderr; don't merge it (`2>&1`) into JSON you parse. Check the exit code first: 0 ok, 1 user error, 2 server error. Some errors print only to stderr.
- `indexer get -o json` → `data.deployments[]` with `commit_hash`, `prod_status` (`none`, `pending`, `prod`), `gql_endpoint`. A missing indexer returns `{"ok": true}` with no `data`.
- `deployment status -o json` → one entry per chain with `block_height`, `latest_processed_block`, `is_ready`. An empty list means no progress yet.
- Commands that confirm (`add`, `deploy`, `promote`, `restart`, `delete`, `security api-key ...`) take `--yes`; unanswered, they cancel.
