#!/usr/bin/env bash
# Stress-test matrix for the Envio HyperIndex Solana indexer.
#
# Characterizes the OOM / throughput behavior of matching ultra-high-frequency
# programs (SPL-Token + System) in the IN-MEMORY test harness, which retains
# every entity write (createTestIndexer().process). See Solana Issues P1.
#
#   Variable A  program set : defi {Jupiter,Kamino,Drift,Raydium}
#                             defi+hf {+ SPL-Token + System}
#   Variable B  window      : 5, 25, 100, 400 slots from start_block 420,650,000
#   Variable C  token_balance_fields : true | false
#
# SAFETY: never runs `envio start`; the in-memory harness never touches Postgres,
# so the live demo DB (schema public on :5433 + Hasura :8080) is untouched. Each
# cell is time-boxed and the matrix RAMPS UP window size, stopping escalation on
# the first OOM/crash.
#
# Run from this directory:  ./run-stress.sh
# Override:  PROGRAM_SETS, WINDOWS, TB_VALUES, BUDGET_MS via env.

set -uo pipefail
cd "$(dirname "$0")"

START=420650000
GEN=.generated
mkdir -p "$GEN"

# The reachable demo endpoint (solana-demo2, pinned in /etc/hosts) serves no
# token_balances and intermittently 503s under load. High client retries absorb
# transient 503s so the indexer doesn't fall back to the broken SVM RPC source.
export ENVIO_HYPERSYNC_CLIENT_MAX_RETRIES="${ENVIO_HYPERSYNC_CLIENT_MAX_RETRIES:-12}"
export ENVIO_HYPERSYNC_CLIENT_TIMEOUT_MILLIS="${ENVIO_HYPERSYNC_CLIENT_TIMEOUT_MILLIS:-25000}"
export LOG_LEVEL="${LOG_LEVEL:-silent}"

PROGRAM_SETS="${PROGRAM_SETS:-defi defi+hf}"
WINDOWS="${WINDOWS:-5 25 100 400}"
TB_VALUES="${TB_VALUES:-true false}"
BUDGET_MS="${BUDGET_MS:-180000}"
# Hard ceiling per cell so a hang can't wedge the box; budget should fire first.
HARD_TIMEOUT="${HARD_TIMEOUT:-300}"

ENDPOINT="https://solana.hypersync.xyz"

endpoint_ok() {
  for _ in 1 2 3 4 5; do
    code="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "$ENDPOINT/height" 2>/dev/null)"
    [ "$code" = "200" ] && return 0
    sleep 3
  done
  return 1
}

printf '%-9s %-7s %-4s | %-14s %-7s %-9s %-13s %-9s\n' \
  PROGRAMS WINDOW TB OUTCOME WALL_S PEAK_MB MATCHED_IX TB_ROWS
printf '%s\n' "-------------------------------------------------------------------------------------"

RESULTS_FILE="$GEN/results.jsonl"
: >| "$RESULTS_FILE"

for ps in $PROGRAM_SETS; do
  for tb in $TB_VALUES; do
    oomed=0
    for w in $WINDOWS; do
      if [ "$oomed" = "1" ]; then
        printf '%-9s %-7s %-4s | %-14s %-7s %-9s %-13s %-9s\n' \
          "$ps" "$w" "$tb" "skip(after-oom)" "-" "-" "-" "-"
        continue
      fi

      if ! endpoint_ok; then
        printf '%-9s %-7s %-4s | %-14s %-7s %-9s %-13s %-9s\n' \
          "$ps" "$w" "$tb" "endpoint-503" "-" "-" "-" "-"
        continue
      fi

      end=$((START + w))
      cfg="$GEN/cfg_${ps//+/_}_${w}_${tb}.yaml"
      node gen-config.mjs "$ps" "$w" "$tb" "$cfg" 2>/dev/null
      cnt="$GEN/count_${ps//+/_}_${w}_${tb}.json"
      rm -f "$cnt"

      out="$(
        ENVIO_CONFIG="$cfg" \
        STRESS_START="$START" STRESS_END="$end" \
        STRESS_BUDGET_MS="$BUDGET_MS" \
        STRESS_COUNT_FILE="$(pwd)/$cnt" \
        timeout "$HARD_TIMEOUT" node run-one.mjs 2>/dev/null
      )"
      rc=$?

      if [ -z "$out" ]; then
        # No JSON line: hard timeout or crash before reporting. Recover the live
        # count if the handler managed to write one.
        live="$(cat "$cnt" 2>/dev/null || echo '{}')"
        mi="$(printf '%s' "$live" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).matchedIx||0)}catch{console.log(0)}})')"
        oc="killed"; [ "$rc" = "124" ] && oc="hard-timeout"
        printf '%-9s %-7s %-4s | %-14s %-7s %-9s %-13s %-9s\n' \
          "$ps" "$w" "$tb" "$oc" "-" "-" "$mi" "-"
        echo "{\"programSet\":\"$ps\",\"windowSlots\":$w,\"tb\":$tb,\"outcome\":\"$oc\",\"matchedInstructions\":$mi}" >> "$RESULTS_FILE"
        oomed=1
        continue
      fi

      echo "$out" >> "$RESULTS_FILE"
      oc="$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.outcome)})')"
      ws="$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.wallS)})')"
      pm="$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.peakRssMB)})')"
      mi="$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.matchedInstructions)})')"
      tr="$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.tokenBalanceRows)})')"

      printf '%-9s %-7s %-4s | %-14s %-7s %-9s %-13s %-9s\n' \
        "$ps" "$w" "$tb" "$oc" "$ws" "$pm" "$mi" "$tr"

      case "$oc" in
        oom|worker-exit|hard-timeout|killed) oomed=1 ;;
      esac
    done
  done
done

printf '%s\n' "-------------------------------------------------------------------------------------"
echo "Raw results: $RESULTS_FILE"
echo "Outcomes: pass/boundary-hang/budget = measured OK; oom/worker-exit/killed = crashed;"
echo "          endpoint-503/endpoint-fallback = demo endpoint unavailable (re-run)."
