---
name: envio-cloud-cli
description: >-
  Use when deploying an indexer to Envio Cloud (the hosted service), shipping a
  new version, getting its GraphQL endpoint, or managing, monitoring and
  debugging hosted indexers: login, linked repos, settings, auto-deploy, env
  vars, deployments, logs, promotion, rollback, endpoint security. Works from
  headless and remote agent sessions, CI/CD and scripts.
metadata:
  managed-by: envio
---

# Envio Cloud CLI

Run as `npx -y envio-cloud <command>`; `<command> --help` shows its flags and examples. Always pass the organisation, as the last argument or `--org`: it is the repo owner's GitHub name (`enviodev/foo` → `enviodev`). Without it, commands use the user's personal one.

How it works:

- An **indexer** follows one branch of a GitHub repo. Envio Cloud only sees commits **pushed to that branch after the indexer was added**.
- With auto-deploy on (the default), a push deploys. With it off, the commit waits as `inactive` until `deployment deploy`.
- A deployment is named by its commit's first 7 characters: `git rev-parse HEAD | cut -c1-7`.
- Each deployment has its own GraphQL URL. On Production plans, `deployment promote` points the static production endpoint at it; promoting an older one rolls back.
- Indexers on Envio Cloud don't need a HyperSync `ENVIO_API_TOKEN`.

## Ask first

Go ahead with read-only commands, login, adding a free Development indexer, and deploying or promoting when the user asked you to deploy.

Confirm first: deleting anything, `--tier production` (paid), `indexer security` changes, and `promote`, `restart` or `settings set` on an indexer you didn't create.

Only the user can approve the login link, install the Envio Deployments GitHub App on a repo, or upgrade a plan. Give them the link and continue once they're done.

If the indexer will be used beyond testing, tell the user that Development deployments are deleted after at most 30 days, have no backups, and get a new URL on every deploy.

## Log in

`npx -y envio-cloud token` prints `GitHub User: <user>` when logged in. To log in, start `npx -y envio-cloud login > envio-login.log 2>&1` as a background process. It uses `ENVIO_GITHUB_TOKEN` or the GitHub CLI's token when there is one. Otherwise it prints a link and waits until someone approves it, which works from headless and remote sessions too:

```bash
for i in $(seq 30); do grep -A1 'visit:' envio-login.log && break; sleep 1; done
```

Send the user the link. Login is done when the process exits and `token` shows the user. On "session expired", run `logout`, then log in again.

## Add an indexer

1. `npx -y envio-cloud repos --org <org>` must list the repo. If not, ask the user to install the Envio Deployments GitHub App on it from https://envio.dev/app.
2. Make sure the commit can build:
   - `package.json` pins an exact `envio` version: no range, `latest` or `workspace:*`; at least `2.21.5`, not `2.29.x`.
   - Only the root dir is uploaded, without `generated`, `node_modules`, dot folders other than `.envio`, and dotfiles other than `.npmrc`. Everything the indexer reads must be inside the root dir and outside those.
   - The lockfile is ignored, so pin exact dependency versions if the cloud build differs from local.
3. Add it, checking the `--dry-run` summary first, then run again with `--yes` instead. The branch defaults to `envio`, so always pass yours:

   ```bash
   npx -y envio-cloud indexer add --org <org> --name <indexer> --repo <repo> --branch <branch> --dry-run
   ```

   Also `--root-dir <dir>` when `package.json` isn't at the repo root, and `--env-file <path>` for env vars (every key must start with `ENVIO_`).

A new indexer has no deployments until the next push (an empty commit works).

## Ship a commit

1. Push to the indexer's branch. If you can't push there, ask the user to.
2. Find the commit in `npx -y envio-cloud indexer commits <indexer> <org> -o json` and act on its `status`:

   | Status | Do |
   |---|---|
   | not listed | Wait. Still missing after a few minutes: it was pushed before the indexer existed, or to another branch (`indexer settings get`) |
   | `pending`, `deploy` | Wait |
   | `active` | Deployed: go to step 3 |
   | `inactive` | `npx -y envio-cloud deployment deploy <indexer> <commit> <org> --yes`. Still `inactive` after that: at 3 deployments, ask before `deployment delete <indexer> <old-commit> <org> --yes`; otherwise push a new commit |
   | `deletingDeploymemt` (spelled so) | Push a new commit |
   | anything else | The name says what's wrong (`versionNotSupported`, `configFileMissing`, ...): fix it and push |

3. Check `npx -y envio-cloud deployment status <indexer> <commit> <org> -o json` until every chain has `is_ready: true`, waiting a minute between checks. No progress for 10 minutes: [debug](#debug). Never use `--watch-till-synced` in an agent session: it has no time limit, and stopping it leaves it running in the background.
4. `npx -y envio-cloud deployment endpoint <indexer> <commit> <org>` prints the GraphQL URL. Query a real entity on it, with `Authorization: Bearer <key>` if the indexer has API keys (`indexer security get`).
5. On Production: `npx -y envio-cloud deployment promote <indexer> <commit> <org> --yes`. Consumers use the static production endpoint, which only the dashboard shows: ask the user for it.

## Debug

```bash
npx -y envio-cloud deployment logs <indexer> <commit> <org> --build --level error   # build failed?
npx -y envio-cloud deployment logs <indexer> <commit> <org> --level error,warn --since 1h
```

| Symptom | Fix |
|---|---|
| `deployment deploy` says "commit ... not found" | Envio Cloud never saw it: push, then use the hash from `indexer commits` |
| Builds locally, fails on Envio Cloud | A file it needs isn't uploaded (see [Add an indexer](#add-an-indexer)): move it inside the root dir, or widen `--root-dir` |
| Pushes stopped deploying | The pusher has the `reader` role, or the indexer is paused (billing or plan limits): ask the user to check the dashboard |
| Env var undefined at runtime | Key lacks the `ENVIO_` prefix, or was set after the deployment: fix it and push |
| No runtime logs | They default to the last 30 minutes: `--since 24h` |

`deployment restart` reruns the same build, so new code or env vars need a new commit.

## Settings

`npx -y envio-cloud indexer settings get|set <indexer> <org>` (`--branch`, `--root-dir`, `--auto-deploy=false`) and `indexer env set|import` apply to the next deployment. `indexer security` (API keys, IP allow-list) applies at once and can lock out existing clients.

## Scripting

With `-o json`, check the exit code first: 0 ok, 1 user error, 2 server error.

## More

- All Envio Cloud docs in one file (plans, limits, every command): `curl -s https://docs.envio.dev/llms-envio-cloud.txt | grep -n -i -C3 "<topic>"`.
- Prices: https://envio.dev/pricing/hosting. Alerts, members and billing: the dashboard at https://envio.dev/app.
- Stuck: Envio's Discord, https://discord.gg/envio.
