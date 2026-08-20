#!/usr/bin/env bash
# End-to-end ERC-20 write benchmark: pg-only entities vs clickhouse-only entities.
# Usage: ./run.sh <pg|ch> <start_block> <end_block> [label]
set -euo pipefail

VARIANT="$1"
START="$2"
END="$3"
LABEL="${4:-$VARIANT}"

cd "$(dirname "$0")"
BENCH_DIR="$PWD"
OUT_DIR="$BENCH_DIR/results"
mkdir -p "$OUT_DIR"

CONFIG="config.$VARIANT.generated.yaml"
# Indentation is captured rather than matched, and the result is checked: a
# rewrite that quietly matched nothing would benchmark the committed block range
# under the requested label, so pg and ch could be compared over different data.
sed -e "s/^\( *\)start_block:.*/\1start_block: $START/" \
    -e "s/^\( *\)end_block:.*/\1end_block: $END/" \
    "config.$VARIANT.yaml" > "$CONFIG"
for field in "start_block: $START" "end_block: $END"; do
  grep -q "$field" "$CONFIG" || { echo "run.sh: failed to set '$field' in $CONFIG" >&2; exit 1; }
done

export ENVIO_CONFIG="$CONFIG"
export ENVIO_PG_SCHEMA="bench_$VARIANT"
export ENVIO_CLICKHOUSE_DATABASE="envio_bench_$VARIANT"
export ENVIO_HASURA=false
export ENVIO_TUI=false
export LOG_LEVEL=warn

PORT=$((9898 + RANDOM % 100))
export ENVIO_INDEXER_PORT=$PORT

node node_modules/.bin/envio codegen >/dev/null 2>&1

METRICS_FILE="$OUT_DIR/$LABEL.metrics.prom"
LOG_FILE="$OUT_DIR/$LABEL.log"
: > "$METRICS_FILE"

START_TS=$(date +%s.%N)
node node_modules/.bin/envio start -r > "$LOG_FILE" 2>&1 &
INDEXER_PID=$!

# Poll metrics; keep the most recent successful scrape so the final numbers
# survive the process exiting between scrapes.
(
  while kill -0 "$INDEXER_PID" 2>/dev/null; do
    if curl -s --max-time 2 "http://127.0.0.1:$PORT/metrics" -o "$METRICS_FILE.tmp" 2>/dev/null; then
      if [ -s "$METRICS_FILE.tmp" ]; then mv "$METRICS_FILE.tmp" "$METRICS_FILE"; fi
    fi
    sleep 0.5
  done
) &
POLLER_PID=$!

set +e
wait "$INDEXER_PID"
EXIT_CODE=$?
set -e
END_TS=$(date +%s.%N)
kill "$POLLER_PID" 2>/dev/null || true
wait "$POLLER_PID" 2>/dev/null || true

WALL=$(awk -v a="$START_TS" -v b="$END_TS" 'BEGIN{printf "%.2f", b-a}')

echo "=== $LABEL: exit=$EXIT_CODE wall=${WALL}s blocks=$START..$END"
python3 - "$METRICS_FILE" "$LABEL" "$WALL" "$EXIT_CODE" <<'PY'
import re, sys, json, os
path, label, wall, exit_code = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
text = open(path).read() if os.path.exists(path) else ""
def scalar(name):
    m = re.search(r'^%s(?:\{[^}]*\})? ([0-9.eE+-]+)$' % re.escape(name), text, re.M)
    return float(m.group(1)) if m else None
def labelled(name, key):
    out = {}
    for m in re.finditer(r'^%s\{([^}]*)\} ([0-9.eE+-]+)$' % re.escape(name), text, re.M):
        lm = re.search(r'%s="([^"]+)"' % key, m.group(1))
        if lm:
            out[lm.group(1)] = float(m.group(2))
    return out
# A run that processed nothing is a result, not a missing scrape: `or None`
# would report both as null and hide a stalled run from anyone comparing the
# pg and ch outputs.
progress = labelled("envio_progress_events", "chainId")
events = sum(progress.values()) if progress else None
writes = labelled("envio_storage_write_total", "storage")
secs = labelled("envio_storage_write_seconds", "storage")
res = {
    "label": label,
    "wall_seconds": wall,
    "exit_code": exit_code,
    "events_processed": events,
    "events_per_second": round(events / wall, 1) if events is not None and wall > 0 else None,
    "progress_block": labelled("envio_progress_block", "chainId"),
    "write_seconds": secs,
    "write_total": writes,
    "write_ms_per_batch": {k: round(1000 * secs[k] / writes[k], 1) for k in secs if writes.get(k)},
    "stalled_on_write_seconds": scalar("envio_processing_stalled_on_storage_write_seconds"),
    "processing_seconds": scalar("envio_processing_seconds"),
    "preload_seconds": scalar("envio_preload_seconds"),
    "stalled_on_fetch_seconds": scalar("envio_processing_stalled_on_fetch_seconds"),
    "elapsed_seconds": scalar("envio_process_elapsed_seconds"),
}
print(json.dumps(res, indent=2))
json.dump(res, open(os.path.join(os.path.dirname(path), label + ".json"), "w"), indent=2)
PY

exit "$EXIT_CODE"
