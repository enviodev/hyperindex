---
name: ci
description: >-
  Use when CI fails and you need to investigate. Fetches the latest failed
  workflow run for the current branch/PR and shows failed job logs.
---

# Investigating CI Failures

Start by running the commands below directly (not as a script) to fetch the latest CI status.

## Step 1: Get run ID and failed jobs

```bash
branch=$(git rev-parse --abbrev-ref HEAD) && \
run_id=$(curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs?branch=${branch}&per_page=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])") && \
echo "Run ID: $run_id" && \
curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs/${run_id}/jobs" \
  | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    status = '✓' if j['conclusion'] == 'success' else '✗' if j['conclusion'] == 'failure' else '?'
    print(f'{status} {j[\"name\"]} (id: {j[\"id\"]})')
    if j['conclusion'] == 'failure':
        for s in j['steps']:
            if s['conclusion'] == 'failure':
                print(f'  Step failed: {s[\"name\"]}')"
```

## Step 2: Get error annotations for a failed job

```bash
curl -sf "https://api.github.com/repos/enviodev/hyperindex/check-runs/JOB_ID/annotations" \
  | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(f'{a[\"path\"]}:{a[\"start_line\"]} - {a[\"message\"][:300]}')"
```

## Step 3: Get full logs (requires auth)

```bash
# If gh is available and authenticated:
gh run view RUN_ID --log-failed

# Otherwise use WebFetch on the job URL for a summary:
# https://github.com/enviodev/hyperindex/actions/runs/RUN_ID/job/JOB_ID
```

## Notes
- Steps 1-2 use unauthenticated GitHub API (works for public repos)
- Log downloads (step 3) require authentication
- Annotations give exact file:line and error messages — usually enough to diagnose
