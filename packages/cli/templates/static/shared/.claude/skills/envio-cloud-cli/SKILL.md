---
name: envio-cloud-cli
description: >-
  Use when deploying, managing, or monitoring hosted indexers on the Envio
  cloud. The envio-cloud CLI covers auth, indexer settings, env vars,
  deployments, logs, and metrics — from the terminal, CI/CD, or scripts.
metadata:
  managed-by: envio
---

# Envio Cloud CLI

Run with `npx envio-cloud <command>` (or `npm install -g envio-cloud`). Full docs: https://docs.envio.dev/docs/HyperIndex/envio-cloud-cli

## Auth

- `envio-cloud login` — uses a signed-in GitHub CLI (`gh auth token`) automatically if there is one, otherwise opens a browser login (30-day session)
- `envio-cloud login --token <github-token>` or `ENVIO_GITHUB_TOKEN` env var — for CI/CD (scopes: `read:org`, `read:user`, `user:email`)
- `envio-cloud token` / `envio-cloud logout` — inspect / end session

`login` and `token` currently exit 0 even when they fail (bad token, not logged in), so check their output, not the exit code.

## Context

Set defaults once to avoid repeating `--org`/`--indexer` flags:

```bash
envio-cloud config set-org <org>
envio-cloud config set-indexer <indexer>
envio-cloud config get-context
```

## Indexers

- `envio-cloud indexer list [-o json]`
- `envio-cloud indexer get <name>`
- `envio-cloud indexer add --name <name> --repo <repo> --branch <branch> --yes [--dry-run]` — `--branch` defaults to `envio`, not `main`. Without `--yes` it asks to confirm, and in a non-interactive shell it cancels and still exits 0. It also currently exits 0 when the API rejects the indexer, so check the output for `Successfully added indexer`
- `envio-cloud indexer commits <indexer> [--limit 10]` — recent commits and their status: `inactive` (can be deployed with `deployment deploy`), `active` (already deployed), `pending` (still processing), `deploy` (deploying), or a reason it can't deploy: `configFileMissing`, `packageJsonMissing`, `failedToDownload`, `reorgsEnabled`, `versionNotSupported`, `clickhouseConfigMismatch`, `clickhouseVersionNotSupported`
- `envio-cloud indexer settings get|set <indexer>` — branch, config file, root dir, auto-deploy
- `envio-cloud indexer env list|set|delete|import <indexer>` — env vars (keys MUST use the `ENVIO_` prefix; changes apply on next deployment)
- `envio-cloud indexer delete <indexer> --yes` — permanent

## Deployments

All take `<indexer> <commit>`, where `<commit>` is the 7-character short hash that `indexer commits` lists, not the full SHA:

- `envio-cloud deployment status <indexer> <commit> [--watch-till-synced]` — `--watch-till-synced` polls until every chain is synced, with no timeout (wrap it in your own); with `-o json` it is ignored and the command prints the current status once
- `envio-cloud deployment logs <indexer> <commit> [--since 1h] [--build] [--level error,warn] [--follow]` — runtime logs look back 30 minutes by default (`--since` up to `7d`), build logs 24 hours (up to `30d`)
- `envio-cloud deployment deploy <indexer> <commit> --yes` — deploy an `inactive` commit by hand (e.g. with auto-deploy off)
- `envio-cloud deployment metrics <indexer> <commit> [--watch]`
- `envio-cloud deployment endpoint <indexer> <commit>` — GraphQL query URL (alias: `ep`)
- `envio-cloud deployment promote <indexer> <commit> --yes` — promote to production
- `envio-cloud deployment restart <indexer> <commit> --yes` — 10-minute cooldown
- `envio-cloud deployment delete <indexer> <commit> --yes` — permanent

## Scripting

`-o json` outputs `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`, except `repos -o json` and `indexer add -o json`, which print the bare data with no envelope. Exit codes: 0 success, 1 user error, 2 server error — but see the exit-0 failures of `login`, `token` and `indexer add` above. Use `-q` to suppress informational messages.
