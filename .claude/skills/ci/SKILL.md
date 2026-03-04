---
name: ci
description: >-
  Use when CI fails and you need to investigate. Fetches the latest failed
  workflow run for the current branch or PR and shows failed job logs.
---

# Investigating CI Failures

This repo is public, so unauthenticated GitHub API calls work. Use `gh` if
available, otherwise fall back to `curl` + `python3`.

## Step 1: Find the failed run and its jobs

```bash
branch=$(git rev-parse --abbrev-ref HEAD) && \
curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs?branch=${branch}&status=failure&per_page=5" \
  | python3 -c "
import sys, json
runs = json.load(sys.stdin)['workflow_runs']
if not runs:
    print('No failed runs found'); sys.exit(0)
for r in runs[:5]:
    print(f'{r[\"id\"]}  {r[\"name\"]}  {r[\"created_at\"]}  {r[\"html_url\"]}')"
```

Then list jobs for the failed run:

```bash
curl -sf "https://api.github.com/repos/enviodev/hyperindex/actions/runs/RUN_ID/jobs" \
  | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    mark = 'FAIL' if j['conclusion'] == 'failure' else 'ok'
    print(f'[{mark}] {j[\"name\"]} (job id: {j[\"id\"]})')
    if j['conclusion'] == 'failure':
        for s in j['steps']:
            if s['conclusion'] == 'failure':
                print(f'       step failed: {s[\"name\"]}')"
```

## Step 2: Get failed job logs

Use `gh` if available (best output), otherwise use WebFetch on the job URL:

```bash
# Option A: gh (if available)
gh run view RUN_ID --log-failed

# Option B: WebFetch the job page for a summary
# https://github.com/enviodev/hyperindex/actions/runs/RUN_ID/job/JOB_ID
```

The output can be large. Focus on the last 200 lines per job, or grep for
`error`, `FAILED`, `assert`, or `panic`.

## Step 3: Check annotations (supplementary)

Annotations give file:line locations when available (e.g., lint errors, compiler
errors), but many failures (tests, build) produce no annotations:

```bash
curl -sf "https://api.github.com/repos/enviodev/hyperindex/check-runs/JOB_ID/annotations" \
  | python3 -c "
import sys, json
anns = json.load(sys.stdin)
if not anns:
    print('No annotations found')
else:
    for a in anns:
        print(f'{a[\"path\"]}:{a[\"start_line\"]} - {a[\"message\"][:300]}')"
```

## Diagnosis checklist

- Read the error message carefully — most CI failures are test failures or build errors
- Check if the failure is flaky by looking at the same workflow on the base branch
- If logs are truncated and `gh` is available, re-run with `gh run rerun RUN_ID --failed`
