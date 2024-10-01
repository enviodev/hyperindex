# GitHub Cache Cleanup Guide

This guide outlines the steps to update and clean the GitHub cache for the `hyperindex` repository. Follow these instructions to authenticate with GitHub, install the GitHub CLI if needed, and clear specific cache entries.

### Prerequisites

- Ensure you have the [GitHub CLI (`gh`)](https://cli.github.com/) installed.

## Steps

### 1. Authenticate with GitHub

```bash
gh auth login
gh --version # sanity check version
```

### 2. List GitHub Action Caches

To view a list of caches in the `hyperindex` repository:

```bash
gh api \
  -H "Accept: application/vnd.github+json" \
  /repos/enviodev/hyperindex/actions/caches
```

### 3. Delete GitHub Action Caches

To delete specific caches, first identify the cache IDs from the previous step (manually for now, but if needed a jq script could be made). Then, use the following script to delete caches by ID:

```bash
# List of cache IDs you want to delete
cache_ids=(111 222 333 444 555)

# Loop through the list and delete each cache
for id in "${cache_ids[@]}"
do
  gh api \
    --method DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    /repos/enviodev/hyperindex/actions/caches/$id
  echo "Deleted cache with ID $id"
done
```
