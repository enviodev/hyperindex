#!/usr/bin/env bash
# Usage: run.sh <case> <job>
# One warm-up run (discarded), then h1 h2 h2big h2big h2 h1 on this runner.
# Prints one RESULT line per measured run.
set -u
case=$1; job=$2
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
bench="$RUNNER_TEMP/bench"
out="$RUNNER_TEMP/out"; mkdir -p "$out"

project="$bench/cases/$case/envio"
(cd "$project" && pnpm install --frozen-lockfile > /dev/null)
pkg=$(readlink -f "$project/node_modules/envio")
addon_dir=$(readlink -f "$project/node_modules/.pnpm/envio-linux-x64@3.19.0/node_modules/envio-linux-x64")
rm -rf "$pkg/src" && cp -r "$repo/packages/envio/src" "$pkg/src"
rm -f "$addon_dir/envio.node" && cp "$repo/target/release/libenvio.so" "$addon_dir/envio.node"

index=0
for http in warmup h1 h2 h2big h2big h2 h1; do
  index=$((index + 1))
  tag="$case.$job.$index.$http"
  version=$http; [ "$http" = warmup ] && version=h1
  ss_log="$out/$tag.ss"
  ( while true; do echo "@ $(date +%s)"; ss -tinH state established '( dport = :443 )'; sleep 2; done ) > "$ss_log" 2>/dev/null &
  sampler=$!
  (cd "$bench" && ENVIO_HTTP_VERSION=$version ENVIO_HTTP_TRACE="$out/$tag.trace" \
    node "cases/$case/run.ts" envio) > "$out/$tag.log" 2>&1 || true
  kill $sampler
  [ "$http" = warmup ] && continue
  result=$(grep -o 'BENCHMARK_RESULT .*' "$out/$tag.log" | cut -c18-)
  if [ -z "$result" ]; then
    echo "RESULT	$case	$job	$index	$http	failed"
    tail -30 "$out/$tag.log"
    continue
  fi
  echo "RESULT	$case	$job	$index	$http	$(echo "$result" | jq -r '[([.windowRuns[].eventsPerSec|floor]|join("/")), (.rangeSeconds*10|floor/10), .correctness]|@tsv')	$("$here/analyze.sh" "$out/$tag.trace" "$ss_log")"
done
