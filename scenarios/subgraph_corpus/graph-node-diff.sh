#!/usr/bin/env bash
# A corpus entry indexed by graph-node, over an archive RPC, and by envio, up
# to the entry's endBlock, then compared with `envio subgraph diff`: every
# entity type's ids, and a sample of every type's fields, at that block.
#
#   RPC_URL=https://... scenarios/subgraph_corpus/graph-node-diff.sh <name>
#
# Needs Docker, ENVIO_API_TOKEN for HyperSync, and envio's Postgres on
# localhost:5433.
set -euo pipefail

name="$1"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
compose_file="$root/scenarios/subgraph_test/differential/docker-compose.yml"
work="$(mktemp -d)"
project="$work/project"
read -r repo commit end_block < <(node -e '
  const entry = require(process.argv[1]).find((e) => e.name === process.argv[2]);
  if (!entry) { console.error(`No corpus entry is named ${process.argv[2]}.`); process.exit(1); }
  console.log(entry.repo, entry.commit, entry.endBlock);
' "$here/corpus.json" "$name")

compose() {
  GRAPH_ETHEREUM="mainnet:$RPC_URL" docker compose -f "$compose_file" -p envio-corpus-diff "$@"
}
cleanup() {
  compose logs --no-color graph-node 2>&1 | grep -viE '"level":"debug"| DEBG ' | tail -150 || true
  compose down -v >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

wait_for() {
  for _ in $(seq 1 120); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "Timed out waiting for: $*" >&2
  exit 1
}

compose up -d graph-node

mkdir -p "$project"
git -C "$project" init --quiet
git -C "$project" fetch --quiet --depth 1 "$repo" "$commit"
git -C "$project" checkout --quiet FETCH_HEAD
if grep -q '"packageManager": *"yarn@[2-9]' "$project/package.json"; then
  (cd "$project" && corepack yarn install --immutable --mode=skip-build)
else
  (cd "$project" && corepack yarn install --frozen-lockfile --ignore-scripts)
fi

# A data source without a startBlock starts where the others do, on both
# sides, so graph-node doesn't scan from genesis over a rate-limited RPC.
# envio's copy also ends every source at the window's last block, which stops
# its chain only when nothing is created from a template: those stay open, as
# graph-node's do. A source starting after the window is never reached.
window() {
  node --input-type=module -e '
    import { readFileSync, writeFileSync } from "node:fs";
    import YAML from "'"$root"'/packages/envio/node_modules/yaml/dist/index.js";
    const [file, end, ends] = [process.argv[1], Number(process.argv[2]), process.argv[3] === "ends"];
    const manifest = YAML.parse(readFileSync(file, "utf8"));
    if (manifest.templates?.length) {
      console.error("A subgraph with templates never stops at the end of the window.");
      process.exit(1);
    }
    const first = Math.min(...manifest.dataSources.map((source) => source.source.startBlock ?? Infinity));
    manifest.dataSources = manifest.dataSources
      .map((source) => ({ ...source, source: { startBlock: first, ...source.source } }))
      .map((source) => (ends ? { ...source, source: { ...source.source, endBlock: end } } : source));
    writeFileSync(file, YAML.stringify(manifest));
  ' "$project/subgraph.yaml" "$end_block" "${1:-}"
}

window
subgraph="corpus/$name"
wait_for curl -s -o /dev/null http://localhost:8020
(
  cd "$project"
  # The project's own codegen script, which may write elsewhere than generated/.
  if node -e 'process.exit(require("./package.json").scripts?.codegen ? 0 : 1)'; then
    corepack yarn codegen
  else
    ./node_modules/.bin/graph codegen
  fi
  ./node_modules/.bin/graph build
  ./node_modules/.bin/graph create --node http://localhost:8020 "$subgraph"
  ./node_modules/.bin/graph deploy --node http://localhost:8020 --ipfs http://localhost:5001 \
    --version-label v1 "$subgraph"
)

window ends
rm -rf "$project/node_modules/envio"
ln -s "$root/packages/envio" "$project/node_modules/envio"
envio="$root/packages/envio/bin.mjs"
export ENVIO_SUBGRAPH_RPC="$RPC_URL" ENVIO_HASURA=false ENVIO_PG_SCHEMA="corpus_diff"
# It stops at the end block; the diff fails unless it got there.
(cd "$project" && timeout 1800 node "$envio" start) || true

# graph-node syncs on its own; the diff waits for it to reach envio's block.
cd "$project"
node "$envio" subgraph diff "http://localhost:8000/subgraphs/name/$subgraph" \
  --block "$end_block" --wait "${DIFF_WAIT:-5400}" --sample 1000000
