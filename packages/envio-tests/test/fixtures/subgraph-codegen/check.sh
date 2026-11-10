#!/usr/bin/env bash
# Regenerate graph-cli goldens and fail if generated/ drifted.
set -euo pipefail
cd "$(dirname "$0")"

pnpm dlx @graphprotocol/graph-cli@0.97.1 codegen

if ! git diff --exit-code -- generated \
  || [[ -n "$(git ls-files --others --exclude-standard -- generated)" ]]; then
  echo "subgraph codegen goldens are stale. Commit the updated generated/ files."
  git diff -- generated || true
  git ls-files --others --exclude-standard -- generated || true
  exit 1
fi
