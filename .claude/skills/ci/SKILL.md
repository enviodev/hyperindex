---
name: ci
description: >-
  Use when CI fails and you need to investigate. Fetches the latest failed
  workflow run for the current branch/PR and shows failed job logs.
---

# Investigating CI Failures

## Quick: fetch latest failed job logs for current branch

```bash
# 1. Get current branch
branch=$(git rev-parse --abbrev-ref HEAD)

# 2. Fetch latest run for branch
run_id=$(curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs?branch=${branch}&per_page=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")

# 3. Get failed jobs
curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs/${run_id}/jobs" \
  | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    if j['conclusion'] == 'failure':
        print(f\"FAILED: {j['name']} (id: {j['id']})\")"

# 4. Fetch logs for a failed job (replace JOB_ID)
curl -sfL "https://api.github.com/repos/enviodev/hyperindex/actions/jobs/JOB_ID/logs" | tail -80
```

## One-liner: show all failed step logs

```bash
branch=$(git rev-parse --abbrev-ref HEAD) && \
run_id=$(curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs?branch=${branch}&per_page=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])") && \
curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs/${run_id}/jobs" \
  | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    if j['conclusion'] == 'failure':
        print(f'--- {j[\"name\"]} (id: {j[\"id\"]}) ---')
        for s in j['steps']:
            if s['conclusion'] == 'failure':
                print(f'  Step failed: {s[\"name\"]}')"
```

Then fetch logs: `curl -sfL "https://api.github.com/repos/enviodev/hyperindex/actions/jobs/<JOB_ID>/logs" | tail -80`

## Notes
- GitHub public API is unauthenticated — no token needed for public repos
- Log downloads redirect to Azure blob storage (use `-L` to follow)
- If `gh` is available: `gh run view --log-failed` is simpler
