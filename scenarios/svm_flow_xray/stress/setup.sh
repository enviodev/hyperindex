#!/usr/bin/env bash
# Makes stress/ a self-contained run root by symlinking the scenario's shared
# assets up one level. This is required because the SVM config path drops the
# `handlers:` field (to_public_config_json), so the handler auto-loader ALWAYS
# globs ./src/handlers -- running from stress/ makes its stress handler (which
# registers SPL-Token + System) the one that loads, without touching the live
# scenario's src/handlers (the running demo).
#
# Run once after checkout, from this directory:  ./setup.sh
# Requires the parent scenario to have node_modules + .envio (run `pnpm install`
# and `pnpm codegen` in scenarios/svm_flow_xray first).

set -euo pipefail
cd "$(dirname "$0")"

for link in node_modules idls schema.graphql .envio envio-env.d.ts; do
  ln -sfn "../$link" "$link"
done

if [ ! -e ../node_modules/envio ]; then
  echo "WARNING: ../node_modules/envio not found. Run 'pnpm install' in the parent scenario." >&2
fi
if [ ! -e ../.envio/types.d.ts ]; then
  echo "WARNING: ../.envio/types.d.ts not found. Run 'pnpm codegen' in the parent scenario." >&2
fi

echo "stress/ run root ready. Next: ./run-stress.sh"
