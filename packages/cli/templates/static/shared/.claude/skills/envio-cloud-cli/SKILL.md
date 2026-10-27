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

- `envio-cloud login` — uses a signed-in GitHub CLI (`gh auth token`) if there is one, otherwise opens a browser login (30-day session)
- `envio-cloud login --token <github-token>` or `ENVIO_GITHUB_TOKEN` env var — for CI/CD (scopes: `read:org`, `read:user`, `user:email`)
- `envio-cloud token` / `envio-cloud logout` — inspect / end session

## Context

Set defaults once to avoid repeating `--org`/`--indexer` flags:

```bash
envio-cloud config set-org <org>
envio-cloud config set-indexer <indexer>
envio-cloud config get-context
```

## Changing cloud state

`indexer add`, `deployment deploy`, `promote`, `restart` and `delete` change what runs on Envio Cloud. Each asks for confirmation, and `--yes` skips it. Ask the user before running any of them.

## Indexers

- `envio-cloud indexer list [-o json]`
- `envio-cloud indexer get <name>`
- `envio-cloud indexer add --name <name> --repo <repo> --branch <branch> --yes [--dry-run]` — `--branch` defaults to `envio`, not `main`
- `envio-cloud indexer commits <indexer>` — recent commits and whether each one deployed
- `envio-cloud indexer settings get|set <indexer>` — branch, config file, root dir, auto-deploy
- `envio-cloud indexer env list|set|delete|import <indexer>` — env vars (keys MUST use the `ENVIO_` prefix; changes apply on next deployment)
- `envio-cloud indexer delete <indexer> --yes` — permanent

## Deployments

All take `<indexer> <commit>`, where `<commit>` is the short hash that `indexer commits` lists:

- `envio-cloud deployment status <indexer> <commit> [--watch-till-synced]`
- `envio-cloud deployment logs <indexer> <commit> [--since 1h] [--build] [--level error,warn] [--follow]`
- `envio-cloud deployment deploy <indexer> <commit> --yes` — deploy a commit by hand (e.g. with auto-deploy off)
- `envio-cloud deployment metrics <indexer> <commit> [--watch]`
- `envio-cloud deployment endpoint <indexer> <commit>` — GraphQL query URL (alias: `ep`)
- `envio-cloud deployment promote <indexer> <commit> --yes` — promote to production
- `envio-cloud deployment restart <indexer> <commit> --yes` — 10-minute cooldown
- `envio-cloud deployment delete <indexer> <commit> --yes` — permanent

## Scripting

`-o json` outputs `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`. Exit codes: 0 success, 1 user error, 2 server error. Use `-q` to suppress informational messages.
