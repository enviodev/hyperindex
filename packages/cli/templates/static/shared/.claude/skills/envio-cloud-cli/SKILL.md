---
name: envio-cloud-cli
description: >-
  Use when deploying an indexer to Envio Cloud (the hosted service), shipping a
  new version, getting its GraphQL endpoint, choosing a plan, or managing,
  monitoring and debugging hosted indexers: login, linked repos, settings,
  auto-deploy, env vars, deployments, logs, promotion, rollback, endpoint
  security. Step-by-step recipes with a helper script, for headless and remote
  agent sessions, CI/CD and scripts.
metadata:
  managed-by: envio
---

# Envio Cloud CLI

Run commands as `npx -y envio-cloud <command>`. Shell state doesn't survive between tool calls, so each recipe sets its own variables. Always pass the indexer and organisation explicitly.

`scripts/cloud.mjs`, next to this file, does the polling: `node <this-skill-dir>/scripts/cloud.mjs help` (from an indexer's root: `node .claude/skills/envio-cloud-cli/scripts/cloud.mjs`). Each command waits up to 100 s, which fits a 2-minute tool call; with a 10-minute tool call, pass `--timeout 540`. Exit code `75` means "still in progress, run it again".

How Envio Cloud works:

- An **indexer** points at a branch of a GitHub repo linked to an Envio organisation. The organisation's id is the repo owner's GitHub name (`enviodev/foo` → `enviodev`).
- Envio Cloud only sees commits **pushed to that branch after the indexer was added**. Changing the branch doesn't deploy what's already on it.
- Each seen commit gets a status (`indexer commits`). With auto-deploy on, a push deploys; with it off, the commit waits as `inactive` until `deployment deploy`.
- Each deployment has its own GraphQL URL. On Production plans, **promoting** a deployment points the static production endpoint at it with zero downtime; promoting an older one rolls back.
- Indexers on Envio Cloud don't need a HyperSync `ENVIO_API_TOKEN`.

## Pick a recipe

| Goal | Recipe |
|---|---|
| Anything, first time in a session | [0. Preflight](#0-preflight) |
| Not logged in, or "session expired" | [1. Log in](#1-log-in) |
| First deployment of an indexer | [2. Add an indexer](#2-add-an-indexer), then [3. Ship a commit](#3-ship-a-commit) |
| Deploy new code | [3. Ship a commit](#3-ship-a-commit) |
| Make a deployment the production one, or roll back | [3f. Promote](#3-ship-a-commit) |
| A deployment fails, stalls or returns wrong data | [4. Debug a deployment](#4-debug-a-deployment) |
| Change env vars, branch, auto-deploy, access | [5. Change settings](#5-change-settings) |
| Pick a plan, or explain what Envio Cloud offers | [reference.md](reference.md#plans) |
| Anything else | [When stuck](#when-stuck) |

## What to do without asking

Go ahead: read-only commands; the login link flow; adding an indexer on the Development plan, deploying and promoting when the user asked you to deploy; pushing to the branch you're working on.

Confirm first: `indexer delete`, `deployment delete` (also at the 3-deployment limit); `deployment promote`, `deployment restart` or `indexer settings set` on an indexer you didn't create in this session; any paid plan (`--tier production`); `--access-type private`; `indexer security` changes. Say what you'll do and why.

Only the user can: approve the login link, install the Envio Deployments GitHub App on a repo, add people to the organisation, upgrade a plan, push to a branch you can't write to. Ask with a link and one sentence on why, then continue once they're done.

If the result will be used beyond testing (a public app, a shared demo), tell the user what the Development plan means: deployments are deleted after at most 30 days, there are no backups, and the URL changes with every deployment. Production plans fix all three ([reference.md](reference.md#plans)).

## 0. Preflight

```bash
npx -y envio-cloud token 2>&1 | sed -E 's/[A-Za-z0-9_-]{30,}/<redacted>/g'
npx -y envio-cloud config get-context 2>&1
npx -y envio-cloud repos 2>&1 | head -30
```

- "not logged in" or "session expired" → [1. Log in](#1-log-in).
- `repos` lists the repos connected to the organisation. Yours is missing → step 2.1.
- `config get-context` shows the default organisation, which after login is the user's personal one. Pass the organisation explicitly instead.

## 1. Log in

With a GitHub token (`ENVIO_GITHUB_TOKEN`, or one the user gives you; scopes `read:org`, `read:user`, `user:email`):

```bash
npx -y envio-cloud login --token "$ENVIO_GITHUB_TOKEN"
```

Otherwise use browser login. **It works from headless and remote sessions**: the CLI prints a link and polls until someone approves it; nothing redirects to `localhost`. Start it in the background:

```bash
BROWSER=echo npx -y envio-cloud login > envio-login.log 2>&1   # background; polls until approved
```

```bash
for i in $(seq 1 30); do grep -q 'login?cli=' envio-login.log && break; sleep 1; done
grep -o 'https://envio.dev/app/login?cli=[^[:space:]]*' envio-login.log
```

Send the link: "Open this link and sign in to let this session use your Envio account." The process exits 0 once approved. It tries the GitHub CLI's token first, so a 401 note before the link is harmless, and no link usually means that token worked: read the log before asking for anything. Never hand the deployment back to the user without offering the link first.

The session lasts 30 days. On "session expired", run `npx -y envio-cloud logout`, then log in again.

Check: `npx -y envio-cloud config get-context` prints `Logged in as: <user>`.

## 2. Add an indexer

```bash
ORG=<org>                # GitHub owner of the repo
IDX=<indexer-name>
REPO=<repo-name>         # without the owner
BRANCH=main              # the branch you'll push to
ROOT=./                  # directory holding package.json and config.yaml, e.g. indexer/
AUTO=true                # false: pushes wait as 'inactive' until you deploy them
```

1. **Repo connected?** `npx -y envio-cloud repos --org "$ORG"` lists `$REPO`. If not, ask the user: "Install the Envio Deployments GitHub App on `<owner>/<repo>` from https://envio.dev/app (Install App in the menu next to your username), then tell me." Check again when they reply.
2. **Deployable?** From the repo root: `node <this-skill-dir>/scripts/cloud.mjs check "$ROOT"`. It checks the [requirements](reference.md#requirements): an exact `envio` version, files outside the root dir or in skipped folders, uncommitted changes. Fix every `problem:` line, then run `pnpm codegen` and `pnpm test` in the root dir.
3. **Name free?** `npx -y envio-cloud indexer list --org "$ORG" | grep -w "$IDX"` prints nothing. The Development plan allows 3 indexers per organisation.
4. **Dry run, then add.** Pass every flag; the defaults are `--branch envio`, `--root-dir ./`, `--auto-deploy=true`.

   ```bash
   npx -y envio-cloud indexer add --org "$ORG" --name "$IDX" --repo "$REPO" \
     --branch "$BRANCH" --root-dir "$ROOT" --config-file config.yaml \
     --auto-deploy="$AUTO" --description "<one line>" --dry-run
   ```

   If the summary is right, run it again with `--yes` instead of `--dry-run`. **Always pass `--yes`**: without it a non-interactive run cancels and adds nothing.

   Add `--env-file <path>` when the indexer reads env vars; every key MUST start with `ENVIO_`. `--tier` defaults to `development`, `--access-type` to `public`.
5. **Check:** `npx -y envio-cloud indexer settings get "$IDX" "$ORG"` shows the branch, root dir and auto-deploy you meant.

The indexer has **no deployments** yet: continue with [3. Ship a commit](#3-ship-a-commit). The first deployment always needs a fresh push.

## 3. Ship a commit

For the first deployment and every later one, with auto-deploy on or off.

```bash
ORG=<org>; IDX=<indexer-name>
CLOUD=<this-skill-dir>/scripts/cloud.mjs   # e.g. <indexer-root>/.claude/skills/envio-cloud-cli/scripts/cloud.mjs
```

**3a. Push** to the indexer's branch: a real change (for a first deployment, documenting it in the README works), or `git commit --allow-empty -m "Redeploy"` to redeploy unchanged code. If you can't push there, ask the user to push or merge, and wait.

```bash
C=$(git rev-parse HEAD | cut -c1-7)   # Envio Cloud matches exactly 7 characters
```

**3b. Wait for Envio Cloud to pick it up, and deploy if needed.**

```bash
node "$CLOUD" wait-commit "$IDX" "$C" "$ORG" --deploy
```

It prints the commit's status as it changes. `--deploy` deploys the commit if it's `inactive` (auto-deploy off). A rejected commit (wrong root dir, unsupported envio version, ...) ends with the fix; see [commit statuses](reference.md#commit-statuses). Exit 0 means `active`.

**3c. Wait for the build and sync.**

```bash
node "$CLOUD" wait-synced "$IDX" "$C" "$ORG"
```

It prints per-chain progress, then the GraphQL URL once every chain is ready. On exit 75, run it again. Builds take a few minutes (30-minute limit); sync time depends on the start block and event volume. No progress after two rounds → [4. Debug a deployment](#4-debug-a-deployment). In an agent session, use `wait-synced` rather than `deployment status --watch-till-synced`, which has no time limit.

**3d. Verify the data.** Query one real entity on the URL and compare it with a local run if you have one. If a browser app on another origin will call it, check CORS:

```bash
E=$(npx -y envio-cloud deployment endpoint "$IDX" "$C" "$ORG")
curl -s -i -X OPTIONS "$E" -H 'Origin: https://<app-origin>' \
  -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type' \
  | grep -i -E '^HTTP|access-control-allow-origin'
```

**3e. Update what uses the URL.** A deployment's URL changes with every deployment. On a Production plan, give consumers the static production endpoint (shown on the indexer's page at https://envio.dev/app) and promote each new deployment. On Development, update the consumers (app env vars, CI variables, docs) after every ship.

**3f. Promote** the synced deployment to make it the production one; promote an older one to roll back.

```bash
npx -y envio-cloud deployment promote "$IDX" "$C" "$ORG" --yes
```

It takes a few minutes: `prod_status` goes from `pending` to `prod` in `indexer get -o json`.

**3g. Report** to the user: organisation and indexer, commit and branch, plan, auto-deploy on or off, sync state, the URL to use, whether it's promoted, and what's left for them. On Development, mention the 30-day limit.

## 4. Debug a deployment

```bash
ORG=<org>; IDX=<indexer-name>; C=<commit>
npx -y envio-cloud indexer commits "$IDX" "$ORG" -o json                       # did the push deploy, and if not, why
npx -y envio-cloud indexer get "$IDX" "$ORG"                                   # which deployments exist
npx -y envio-cloud deployment logs "$IDX" "$C" "$ORG" --build --level error    # build failed?
npx -y envio-cloud deployment logs "$IDX" "$C" "$ORG" --level error,warn --since 1h
npx -y envio-cloud deployment status "$IDX" "$C" "$ORG"                         # per-chain progress
```

| Symptom | Cause | Fix |
|---|---|---|
| "No deployments found" | No push since the indexer was added | Push (3a) |
| Commit not in `indexer commits` | Pushed before the indexer existed, to another branch (case matters), or the GitHub App lost access | Push to the right branch; check `repos` |
| Commit `inactive` | Auto-deploy off, or the 3-deployment / indexing-hour limit | `wait-commit --deploy`; at the limit, ask before deleting an old deployment |
| Pushes stopped deploying | Pusher has the `reader` role, the indexer is paused (unpaid, or over Development limits), or the GitHub organisation was renamed | Ask the user; see [reference.md](reference.md#limits) |
| `deployment deploy` says "commit ... not found" | Envio Cloud never saw that commit | Push, then use the hash from `indexer commits` |
| `deploy` accepted but nothing starts | The commit's code is no longer available | Push a new commit (an empty one works) |
| `indexer add` printed "Operation cancelled." | No `--yes` | Run it again with `--yes` |
| Indexer in the wrong organisation | No `--org`, so it used the default | Re-add with `--org`; ask before deleting the stray one |
| Build fails on Envio Cloud, works locally | Lockfile ignored, files outside the root dir or in skipped folders, uncommitted files | `cloud.mjs check`; pin exact dependency versions; reproduce with `pnpm codegen` |
| "Failed to apply schema" | The schema can't be applied to the database | Read the build log lines above the error, fix `schema.graphql`, push |
| Runtime error in logs | Handler or config bug | Reproduce locally with `pnpm dev` or a test; see the `indexer-troubleshooting` skill |
| Env var undefined at runtime | Missing `ENVIO_` prefix, or set after the deployment started | `indexer env list`; fix, then ship a new commit |
| `deployment status` asks to upgrade envio | The indexer's `envio` is too old to report progress | Upgrade `envio` in `package.json`, push |
| `WARN Block #N is not available on the ... source yet` | Normal near the chain head | Nothing |
| `deployment endpoint` exits 2 | The deployment isn't scheduled yet | Wait until the commit is `active` |
| Logs empty | Runtime logs default to the last 30 minutes | `--since 24h` |

`deployment restart` restarts the same build (10-minute cooldown); for new code or env vars, ship a new commit.

## 5. Change settings

```bash
ORG=<org>; IDX=<indexer-name>
npx -y envio-cloud indexer settings get "$IDX" "$ORG"
```

- **Env vars** (keys MUST start with `ENVIO_`): `indexer env set "$IDX" "$ORG" ENVIO_KEY=value`, or `indexer env import "$IDX" "$ORG" --file .env`. They apply to the next deployment, so [ship a commit](#3-ship-a-commit) afterwards.
- **Branch:** `indexer settings set "$IDX" "$ORG" --branch <branch>`. The next push to it deploys; commits already there don't.
- **Auto-deploy:** `indexer settings set "$IDX" "$ORG" --auto-deploy=false` (or `=true`). Off means pushes wait as `inactive` until `wait-commit --deploy`.
- **Root dir, config file, description, access type:** `--root-dir`, `--config-file`, `--description`, `--access-type` on `settings set`. After changing the root dir, push a new commit.
- **Endpoint access:** `indexer security get "$IDX" "$ORG"`. API keys are under `indexer security api-key` (clients send `Authorization: Bearer <token>`); the IP allow-list under `security add-ip`, then `security enable`. Rules are per indexer and carry over to promoted deployments. They can break existing clients, so confirm first.

## When stuck

1. **CLI help** is authoritative and has examples: `npx -y envio-cloud <command> --help`.
2. **Envio Cloud docs in one file:** `curl -s https://docs.envio.dev/llms-envio-cloud.txt | grep -n -i -C3 "<topic>"`.
3. **Docs search:** `envio tools search-docs "envio cloud <topic>"`, then `envio tools fetch-docs <url>` (the `envio-docs` skill), or the docs MCP server: `claude mcp add --transport http envio-docs https://docs.envio.dev/mcp`. Start pages: https://docs.envio.dev/docs/HyperIndex/envio-cloud-troubleshooting and https://docs.envio.dev/docs/HyperIndex/envio-cloud-cli.
4. **Dashboard:** https://envio.dev/app shows the same indexers, deployments and logs, plus alerts, members, billing and the static production endpoint.
5. **People:** Envio's Discord, https://discord.gg/envio. Tell the user what you tried, the exact error, and the one thing you need.
