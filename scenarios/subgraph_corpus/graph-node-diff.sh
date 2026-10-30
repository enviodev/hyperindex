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
(cd "$project" && corepack yarn install --frozen-lockfile --ignore-scripts)

# graph-node gets the manifest as its authors wrote it.
subgraph="corpus/$name"
wait_for curl -s -o /dev/null http://localhost:8020
(
  cd "$project"
  ./node_modules/.bin/graph codegen
  ./node_modules/.bin/graph build
  ./node_modules/.bin/graph create --node http://localhost:8020 "$subgraph"
  ./node_modules/.bin/graph deploy --node http://localhost:8020 --ipfs http://localhost:5001 \
    --version-label v1 "$subgraph"
)

# envio gets the same window: every data source ends at the entry's block, and
# one that starts after it, which writes nothing there, is left out.
node --input-type=module -e '
  import { readFileSync, writeFileSync } from "node:fs";
  import YAML from "'"$root"'/packages/envio/node_modules/yaml/dist/index.js";
  const [file, end] = [process.argv[1], Number(process.argv[2])];
  const manifest = YAML.parse(readFileSync(file, "utf8"));
  manifest.dataSources = manifest.dataSources
    .filter((source) => (source.source.startBlock ?? 0) <= end)
    .map((source) => ({ ...source, source: { ...source.source, endBlock: end } }));
  writeFileSync(file, YAML.stringify(manifest));
' "$project/subgraph.yaml" "$end_block"

rm -rf "$project/node_modules/envio"
ln -s "$root/packages/envio" "$project/node_modules/envio"
envio="$root/packages/envio/bin.mjs"
export ENVIO_SUBGRAPH_RPC="$RPC_URL" ENVIO_HASURA=false ENVIO_PG_SCHEMA="corpus_diff"
# It stops at the end block; the diff fails unless it got there.
(cd "$project" && timeout 1800 node "$envio" start) || true

# graph-node syncs on its own; the diff waits for it to reach envio's block.
cd "$project"
node "$envio" subgraph diff "http://localhost:8000/subgraphs/name/$subgraph" \
  --block "$end_block" --wait 2400 --sample 1000000
