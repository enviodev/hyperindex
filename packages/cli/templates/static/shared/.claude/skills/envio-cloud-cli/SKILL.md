---
name: envio-cloud-cli
description: >-
  Use when deploying an indexer to Envio Cloud (the hosted service), shipping a
  new version, getting its public GraphQL endpoint, or managing, monitoring and
  debugging hosted indexers: login, linked repos, indexer settings, auto-deploy,
  env vars, deployments, logs, promotion, endpoint security. Step-by-step
  recipes that work from headless and remote agent sessions, CI/CD and scripts.
metadata:
  managed-by: envio
---

# Envio Cloud CLI

Run every command as `npx -y envio-cloud <command>`. Shell state doesn't survive between tool calls, so each recipe sets its own variables at the top. Always pass the indexer and organisation explicitly instead of relying on stored context.

How Envio Cloud works, in four facts:

- An **indexer** points at a branch of a GitHub repo that is linked to an Envio organisation.
- Envio Cloud only learns about commits **pushed to that branch after the indexer was added**. Commits that existed before are invisible: `indexer commits` doesn't list them and `deployment deploy` rejects them.
- Each seen commit can become a **deployment**, with its own GraphQL endpoint. With auto-deploy on, every push deploys. With auto-deploy off, a pushed commit waits as `inactive` until `deployment deploy`.
- **Promotion** marks one deployment as the indexer's production deployment.

## Pick a recipe

| Goal | Recipe |
|---|---|
| Anything, first time in a session | [0. Preflight](#0-preflight) |
| Not logged in | [1. Log in](#1-log-in) |
| Put an indexer on Envio Cloud for the first time | [2. Add an indexer](#2-add-an-indexer), then [3. Ship a commit](#3-ship-a-commit) |
| Deploy new code to an existing indexer | [3. Ship a commit](#3-ship-a-commit) |
| A deployment fails, stalls or returns wrong data | [4. Debug a deployment](#4-debug-a-deployment) |
| Change env vars, branch, auto-deploy, access | [5. Change settings](#5-change-settings) |
| Anything not covered here | [When stuck](#when-stuck) |

## What to do without asking

Go ahead without confirming: every read-only command; the login link flow; adding an indexer, deploying, and promoting when the user asked you to deploy; pushing a commit to the branch you're working on to trigger a deployment.

Confirm with the user first: `indexer delete`, `deployment delete`; `deployment promote`, `deployment restart` or `indexer settings set` on an indexer you didn't create in this session; `--tier production`; `--access-type private`; `indexer security` changes. Say what you're about to do and why.

The steps that only the user can do: approve the login link, link a repository to the organisation, and push or merge on a branch you can't write to. Ask for them with a link and one sentence on why, then keep going once they're done.

## 0. Preflight

One call that shows where you are:

```bash
npx -y envio-cloud token 2>&1 | sed -E 's/[A-Za-z0-9_-]{30,}/<redacted>/g'
npx -y envio-cloud config get-context 2>&1
npx -y envio-cloud repos 2>&1 | head -30
```

- "You are not currently logged in" → [1. Log in](#1-log-in).
- `repos` lists the repositories linked to the organisation. Your repo missing → the user has to link it (see step 2).
- The context organisation defaults to the user's personal organisation after login. The organisation that owns a repo usually has the id of the repo's GitHub owner (`enviodev/foo` → `enviodev`); `npx -y envio-cloud indexer list` shows every organisation the account can see.

## 1. Log in

With a GitHub token (`ENVIO_GITHUB_TOKEN` set, or one the user gives you, scopes `read:org`, `read:user`, `user:email`):

```bash
npx -y envio-cloud login --token "$ENVIO_GITHUB_TOKEN"
```

Otherwise use browser login. **It works from headless and remote sessions**: the CLI creates a login session on Envio's side, prints a URL and polls until someone approves it. Nothing redirects to `localhost`, and the browser doesn't need to be on the same machine. Start it in the background, then read the link:

```bash
BROWSER=echo npx -y envio-cloud login > envio-login.log 2>&1   # run in the background; it polls until approved
```

```bash
for i in $(seq 1 30); do grep -q 'login?cli=' envio-login.log && break; sleep 1; done
grep -o 'https://envio.dev/app/login?cli=[A-Za-z0-9]*' envio-login.log
```

Send the link to the user: "Open this link and sign in to let this session use your Envio account." The login process exits 0 once they approve. It first tries the GitHub CLI's token, so a 401 note before the link is harmless.

Never hand the deployment back to the user as "run these commands yourself" without offering the link first.

Check: `npx -y envio-cloud config get-context` prints `Logged in as: <user>`. Credentials are stored in `~/.envio-cloud/auth.json` for 30 days.

## 2. Add an indexer

```bash
ORG=<org>                # GitHub owner of the repo, see Preflight
IDX=<indexer-name>
REPO=<repo-name>         # without the owner
BRANCH=main              # the branch to deploy from
ROOT=./                  # directory holding config.yaml, e.g. indexer/
AUTO=true                # false: pushes wait as 'inactive' until you deploy them
```

1. **Repo linked?** `npx -y envio-cloud repos --org "$ORG"` lists `$REPO`. If not, stop and ask the user: "Link `<owner>/<repo>` to the `<org>` organisation at https://envio.dev/app (this installs the Envio GitHub app on the repo), then tell me." Re-check after they reply.
2. **Name free?** `npx -y envio-cloud indexer list --org "$ORG" | grep -w "$IDX"` prints nothing.
3. **Dry run**, then add. Pass every flag below: the CLI's defaults are `--branch envio`, `--root-dir ./`, `--auto-deploy=true`.

   ```bash
   npx -y envio-cloud indexer add --org "$ORG" --name "$IDX" --repo "$REPO" \
     --branch "$BRANCH" --root-dir "$ROOT" --config-file config.yaml \
     --auto-deploy="$AUTO" --description "<one line>" --dry-run
   ```

   Read the printed summary; if it's right, run the same command with `-y` instead of `--dry-run`.

   Add `--env-file <path>` when the indexer reads env vars; every key MUST start with `ENVIO_`. `--tier` defaults to `development` and `--access-type` to `public`; change them only when the user asks.
4. **Check:** `npx -y envio-cloud indexer settings get "$IDX" "$ORG"` shows the branch, root dir and auto-deploy you meant.

The indexer now exists with **no deployments**. Continue with [3. Ship a commit](#3-ship-a-commit): the first deployment always needs a fresh push.

## 3. Ship a commit

Works for the first deployment and every later one, with auto-deploy on or off.

```bash
ORG=<org>; IDX=<indexer-name>
```

**3a. Push.** The commit must reach the indexer's deploy branch after the indexer was added. If you can push there, push a real change (for a first deployment, documenting it in the README is a fine one). If you can't, ask the user to push or merge, and wait.

```bash
C=$(git rev-parse --short=7 HEAD)    # the commit on the deploy branch
```

**3b. Wait until Envio Cloud sees it.** Usually under a minute.

```bash
for i in $(seq 1 18); do
  out=$(npx -y envio-cloud indexer commits "$IDX" "$ORG" --limit 5 2>&1)
  echo "$out" | grep -q "$C" && break; sleep 10
done
echo "$out"
```

Not listed after 3 minutes → check that you pushed to the deploy branch (`indexer settings get`) and that the repo is still linked (`repos`).

**3c. Deploy it.** Look at the commit's status in the output above:

- `inactive` (auto-deploy off, or it was skipped): deploy it.

  ```bash
  npx -y envio-cloud deployment deploy "$IDX" "$C" "$ORG" --yes
  ```

- Any other status: auto-deploy already started it. Nothing to do.

**3d. Wait for the build and sync.** Don't use `--watch-till-synced` or `metrics --watch` in an agent session: they never return on their own, and the watch can hang silently behind a proxy. Poll instead, in rounds that fit a tool call's time limit:

```bash
for i in $(seq 1 16); do
  out=$(npx -y envio-cloud deployment status "$IDX" "$C" "$ORG" 2>&1)
  echo "$out" | grep -q 'Overall completion: 100.00%' && break
  sleep 30
done
echo "$out"
npx -y envio-cloud deployment logs "$IDX" "$C" "$ORG" --level error --limit 20 2>&1
```

Not at 100% yet → run the round again. Errors in the logs, or no progress across two rounds → [4. Debug a deployment](#4-debug-a-deployment). Building takes a few minutes; syncing depends on the start block and event volume.

**3e. Verify the endpoint.**

```bash
E=$(npx -y envio-cloud deployment endpoint "$IDX" "$C" "$ORG" -q)
echo "$E"
curl -s "$E" -H 'content-type: application/json' -d '{"query":"{ _meta { isReady progressBlock } }"}'
```

Then query one real entity and compare the result with a local run when you have one. When a browser app on another origin will call it, check CORS:

```bash
curl -s -i -X OPTIONS "$E" -H 'Origin: https://<app-origin>' \
  -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type' \
  | grep -i -E '^HTTP|access-control-allow-origin'
```

The endpoint URL contains a per-deployment id, so it changes with every deployment. Re-fetch it after each ship and update whatever consumes it (app env vars, CI variables, docs).

**3f. Promote** when this deployment should be the indexer's production one (see [What to do without asking](#what-to-do-without-asking)):

```bash
npx -y envio-cloud deployment promote "$IDX" "$C" "$ORG" --yes
```

**3g. Report** to the user: organisation and indexer, commit and branch, auto-deploy on or off, sync state, the GraphQL endpoint, whether it's promoted, and anything left for them to do.

## 4. Debug a deployment

```bash
ORG=<org>; IDX=<indexer-name>; C=<commit>
npx -y envio-cloud indexer get "$IDX" "$ORG"                                   # which deployments exist
npx -y envio-cloud deployment logs "$IDX" "$C" "$ORG" --build --level error    # build failed?
npx -y envio-cloud deployment logs "$IDX" "$C" "$ORG" --level error,warn --since 1h
npx -y envio-cloud deployment metrics "$IDX" "$C" "$ORG"                        # per-chain progress, HyperSync on/off
```

| Symptom | Cause | Fix |
|---|---|---|
| `indexer get` shows "No deployments found" | No push since the indexer was added | [3a. Push](#3-ship-a-commit) |
| `deployment deploy` says "commit ... not found" | Envio Cloud never saw that commit: pushed before the indexer existed, to another branch, or wrong hash | Push to the deploy branch, then use the 7-character hash from `indexer commits` |
| Commit listed `inactive` and nothing happens | Auto-deploy is off | `deployment deploy` |
| `indexer add` rejects the repo | Repo not linked to the organisation | User links it at https://envio.dev/app; check with `repos` |
| Indexer added to the wrong organisation | No `--org`; it fell back to the context or the personal org | Re-add with `--org`, delete the stray one after confirming with the user |
| Build log errors | Same failure as locally | Reproduce locally with `pnpm codegen` and `pnpm test` from the indexer's root dir, fix, ship a new commit |
| Runtime error in logs | Handler or config bug | Reproduce locally with `pnpm dev` or a test; see the `indexer-troubleshooting` skill |
| Env var undefined at runtime | Missing `ENVIO_` prefix, or set after the deployment started | `indexer env list`; fix, then ship a new commit |
| `WARN Block #N is not available on the ... source yet` | Normal near the chain head | Nothing |
| `--watch-till-synced` hangs | Watch connection dropped | Poll as in 3d |
| Logs empty | Default lookback is 30 min for runtime logs | `--since 24h` |

`deployment restart` restarts the same build (10-minute cooldown between restarts); it doesn't pick up new code. Ship a new commit for that.

## 5. Change settings

```bash
ORG=<org>; IDX=<indexer-name>
npx -y envio-cloud indexer settings get "$IDX" "$ORG"
```

- **Env vars** (keys MUST start with `ENVIO_`): `indexer env set "$IDX" "$ORG" ENVIO_KEY=value`, or `indexer env import "$IDX" "$ORG" --file .env`. They apply to the next deployment only, so [ship a commit](#3-ship-a-commit) afterwards.
- **Deploy branch:** `indexer settings set "$IDX" "$ORG" --branch <branch>`. Commits already on that branch are not deployed; the next push is.
- **Auto-deploy:** `indexer settings set "$IDX" "$ORG" --auto-deploy=false` (or `=true`). Off means you choose what runs: pushes appear as `inactive` and you deploy them with 3c.
- **Root dir / config file / description / access type:** `--root-dir`, `--config-file`, `--description`, `--access-type` on `settings set`.
- **Endpoint access:** `indexer security get "$IDX" "$ORG"`. API-key auth lives under `indexer security api-key` (clients then send `Authorization: Bearer <token>`); the IP allow-list under `security enable` / `add-ip`. Changing either can break existing clients, so confirm first.
- **Deployment tags:** `deployment tags set "$IDX" <commit> "$ORG" env=staging`.

## When stuck

1. **CLI help is the source of truth** and includes examples: `npx -y envio-cloud <command> --help`, e.g. `npx -y envio-cloud deployment deploy --help`. Top-level overview: `npx -y envio-cloud --help`.
2. **Docs:** search with `envio tools search-docs "envio cloud <topic>"` and read a hit with `envio tools fetch-docs <url>` (the `envio-docs` skill). Start pages: https://docs.envio.dev/docs/HyperIndex/hosted-service and https://docs.envio.dev/docs/HyperIndex/envio-cloud-cli.
3. **Dashboard:** https://envio.dev/app shows the same indexers, deployments and logs, and is where repos get linked. Point the user there for anything the CLI can't do.
4. **Ask the user** with what you tried, the exact error, and the one thing you need from them.

## Scripting notes

- `-o json` prints `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`. Exit codes: 0 success, 1 user error, 2 server error.
- `indexer get -o json` → `data.deployments[]` with `commit_hash` (7 characters), `prod_status`, `gql_endpoint`.
- Informational lines like `Using organisation '<org>' (from context)` go to the same output and break JSON parsing when you merge stderr with `2>&1`. Pass `-q`, or don't merge stderr.
- Most commands take the organisation as a trailing positional argument or `--org`; deployment commands take `<indexer> <commit> [org]`.
