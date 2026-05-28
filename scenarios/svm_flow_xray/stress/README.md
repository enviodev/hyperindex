# SVM stress test harness

Repeatable stress test for the Envio HyperIndex Solana indexer: characterizes
the memory / throughput behavior of matching ultra-high-frequency programs
(SPL-Token + System) in the **in-memory test harness**
(`createTestIndexer().process()`), which retains every entity write in memory and
is the path that OOMs in practice. See `Solana Issues.md` P1.

## Safety

- Never runs `envio start`. The in-memory harness never touches Postgres, so the
  live demo DB (schema `public` on :5433 + Hasura :8080) is untouched.
- Every cell is time-boxed (`STRESS_BUDGET_MS` + a hard `timeout`).
- The matrix ramps window size up and stops escalating on the first crash.

## Layout

- `gen-config.mjs` - emits a config YAML for one matrix cell to `.generated/`.
- `run-one.mjs` - runs ONE cell, prints a JSON metrics line.
- `run-stress.sh` - runs the full matrix (ramped, time-boxed), prints a table.
- `setup.sh` - symlinks the parent scenario's shared assets so `stress/` is a
  self-contained run root (its `src/handlers/` registers SPL-Token + System).
- `src/handlers/flow.ts` - stress handler (DeFi + SPL-Token + System).

## Run

```sh
cd scenarios/svm_flow_xray        # ensure node_modules + .envio exist
pnpm install && pnpm codegen      # if not already done
cd stress
./setup.sh
./run-stress.sh
```

## Matrix

- **A** program set: `defi` {Jupiter,Kamino,Drift,Raydium} vs `defi+hf` (+SPL-Token,+System)
- **B** window: 5, 25, 100, 400 slots from start_block 420,650,000
- **C** `token_balance_fields`: true vs false

## Why the harness has a boundary-hang / sidecar count

Two SVM test-path quirks, both worth fixing upstream:

1. `process({chains:{0:{}}})` (empty chain config) enters auto-exit mode and
   queries to HEAD (~1.27M slots ahead), which times out. The config `end_block`
   does NOT bound the test-harness query. The harness passes the window
   explicitly via `process({chains:{0:{startBlock,endBlock}}})`.
2. Even with an explicit `endBlock`, the run loops at the window boundary without
   resolving `process()`: the SVM chunk-range upper bound is computed as
   `endBlock-1` while the exit check wants `committedProgressBlockNumber >=
   endBlock`, so progress can never reach `endBlock`. The harness races
   `process()` against a budget and reads a live matched-instruction count the
   handler writes to `STRESS_COUNT_FILE`.

## Findings (2026-05-28, against solana-demo2 / 213.190.30.141)

See `Solana Issues.md` P1 for the full results table and conclusion. Headlines:

- Program set (Variable A) dominates: at a 400-slot window, defi-only matched
  ~4.6k instructions at ~390 MB RSS; defi+hf matched ~321k instructions at
  ~1.73 GB RSS (~70x more matches, RSS 4.5x). RSS scales with matched-instruction
  count, confirming the consumer-side (in-memory entity-write) OOM driver.
- Variable C (token_balance_fields) could not be exercised: the demo endpoint
  returns ZERO token_balances at every slot tested, so the per-tx fan-out that
  would dominate on a real endpoint is absent here.
- The reachable endpoint also serves only a small fraction of chain data and
  intermittently 503s under load (see Solana Issues P0/P1 notes).
