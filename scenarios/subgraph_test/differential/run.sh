#!/usr/bin/env bash
# Indexes one chain with graph-node and with envio and diffs what they store.
#
# The chain is a local anvil, driven through the contracts behind the
# scenario's ABIs; the subgraph is the scenario itself, with only its factory
# address and start block rewritten. Needs Docker and network access for the
# images, solc and graph-cli.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scenario="$(dirname "$here")"
work="$(mktemp -d)"
project="$work/project"

GRAPH_CLI="@graphprotocol/graph-cli@0.97.1"
FOUNDRY="ghcr.io/foundry-rs/foundry:stable"
RPC="http://localhost:8545"
# anvil's first dev account, which deploys the factory at a fixed address.
KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SUBGRAPH="differential/scenario"

compose() { docker compose -f "$here/docker-compose.yml" -p envio-subgraph-differential "$@"; }
# The image's entrypoint is `sh -c`, which would take only the first word. A
# proxy and its CA, when the host has them, are how forge reaches solc.
foundry() {
  docker run --rm --network host --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$work/contracts:/contracts" -w /contracts \
    -e HTTPS_PROXY -e https_proxy -e NO_PROXY -e no_proxy \
    ${SSL_CERT_FILE:+-v "$SSL_CERT_FILE:/etc/ssl/certs/host-ca.crt:ro" -e SSL_CERT_FILE=/etc/ssl/certs/host-ca.crt} \
    --entrypoint "$1" "$FOUNDRY" "${@:2}"
}
cast() { foundry cast "$@" --rpc-url "$RPC"; }
send() { cast send --private-key "$KEY" "$@" >/dev/null; }

cleanup() {
  if [[ "${KEEP:-}" != "1" ]]; then
    compose down -v >/dev/null 2>&1 || true
    rm -rf "$work"
  fi
}
trap cleanup EXIT

compose up -d
cp -r "$here/contracts" "$work/contracts"
until cast block-number >/dev/null 2>&1; do sleep 1; done

foundry forge build --quiet
factory="$(foundry forge create src/Factory.sol:Factory --broadcast --rpc-url "$RPC" \
  --private-key "$KEY" --json | sed -n 's/.*"deployedTo": *"\([^"]*\)".*/\1/p')"

# Two pairs, swaps on both, and enough empty blocks for the every-5 block
# handler to fire.
send "$factory" "createPair(address,address)" 0x00000000000000000000000000000000000000a1 0x00000000000000000000000000000000000000b1
pair1="$(cast compute-address "$factory" --nonce 1 | awk '{print $NF}')"
send "$pair1" "swap(uint256)" 7
send "$factory" "createPair(address,address)" 0x00000000000000000000000000000000000000a2 0x00000000000000000000000000000000000000b2
pair2="$(cast compute-address "$factory" --nonce 2 | awk '{print $NF}')"
send "$pair2" "swap(uint256)" 11
send "$pair1" "swap(uint256)" 13
cast rpc anvil_mine 12 >/dev/null
head="$(cast block-number)"

mkdir -p "$project"
cp -r "$scenario"/{subgraph.yaml,schema.graphql,abis,src,generated,package.json} "$project/"
ln -s "$scenario/node_modules" "$project/node_modules"
sed -i "s/address: \".*\"/address: \"$factory\"/; s/startBlock: .*/startBlock: 0/" "$project/subgraph.yaml"

until curl -s -o /dev/null http://localhost:8020; do sleep 1; done
(
  cd "$project"
  pnpm dlx "$GRAPH_CLI" build --skip-migrations >/dev/null
  pnpm dlx "$GRAPH_CLI" create --node http://localhost:8020 "$SUBGRAPH" >/dev/null
  pnpm dlx "$GRAPH_CLI" deploy --node http://localhost:8020 --ipfs http://localhost:5001 \
    --version-label v1 --skip-migrations "$SUBGRAPH" >/dev/null
)

graph_url="http://localhost:8000/subgraphs/name/$SUBGRAPH"
# The index node answers even for a subgraph that failed on its first block,
# which its own GraphQL endpoint doesn't.
status() {
  curl -s http://localhost:8030/graphql -H 'content-type: application/json' -d '{"query":
    "{ indexingStatuses { health fatalError { message } chains { latestBlock { number } } } }"}'
}
synced=""
for _ in $(seq 1 120); do
  current="$(status || true)"
  if [[ "$current" == *'"health":"failed"'* ]]; then
    echo "graph-node failed to index the scenario: $current" >&2
    exit 1
  fi
  number="$(sed -n 's/.*"latestBlock":{"number":"\([0-9]*\)".*/\1/p' <<<"$current")"
  if [[ -n "$number" && "$number" -ge "$head" ]]; then
    synced=1
    break
  fi
  sleep 1
done
[[ -n "$synced" ]] || { echo "graph-node didn't reach block $head: $current" >&2; exit 1; }

mkdir -p "$project/test"
cp "$here/differential.test.ts" "$project/test/"
sed "s#\.\./\.\./packages#$(cd "$scenario/../../packages" && pwd)#" \
  "$scenario/vitest.config.ts" >"$project/vitest.config.ts"

cd "$project"
ENVIO_SUBGRAPH_RPC="{\"url\":\"$RPC\",\"for\":\"sync\"}" \
  GRAPH_QUERY_URL="$graph_url" END_BLOCK="$head" \
  ./node_modules/.bin/vitest run
