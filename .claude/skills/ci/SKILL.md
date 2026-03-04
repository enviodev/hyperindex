---
name: ci
description: >-
  Use when CI fails and you need to investigate. Fetches the latest failed
  workflow run for the current branch or PR and shows failed job logs.
---

# Investigating CI Failures

Use `gh` CLI for all GitHub API calls — it handles auth and repo detection.

## Step 1: Find the failed run

```bash
# Get the latest failed run for the current branch
gh run list --branch "$(git rev-parse --abbrev-ref HEAD)" --status failure --limit 5
```

If the user mentions a PR number, use `--commit` with the PR's head SHA instead,
or look up the PR branch:

```bash
gh pr view PR_NUMBER --json headRefName --jq .headRefName
```

## Step 2: View failed job logs

This is the most useful command — shows only output from failed steps:

```bash
gh run view RUN_ID --log-failed
```

The output can be large. Focus on the last 200 lines per job, or grep for
`error`, `FAILED`, `assert`, or `panic`.

## Step 3: Check annotations (supplementary)

Annotations give file:line locations when available (e.g., lint errors, compiler
errors), but many failures (tests, build) produce no annotations:

```bash
gh api "repos/{owner}/{repo}/check-runs/JOB_ID/annotations"
```

## Diagnosis checklist

- Read the error message carefully — most CI failures are test failures or build errors
- Check if the failure is flaky by looking at the same workflow on the base branch
- If logs are truncated, re-run with `gh run rerun RUN_ID --failed` and watch live
