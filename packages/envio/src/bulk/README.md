# Bulk Mode (write-only ClickHouse firehose)

A write-only indexer mode that bypasses handlers, the in-memory store, entity
history, and Postgres bulk writes. Designed for backfilling raw event data
(ERC20 Transfers as the v1 basecase) into ClickHouse at maximum throughput.

## What it does

- Spawns N Node.js worker threads, each owning a non-overlapping block range.
- Each worker pulls events from HyperSync (own client, own TCP), decodes
  them, and streams rows to ClickHouse via `JSONCompactEachRow`.
- ClickHouse table is auto-created (`ReplacingMergeTree`, partitioned by
  month, sorted by `(chain_id, block_number, log_index)`, bloom-filter skip
  indexes on `from`/`to`/`tx_hash`).
- Postgres is untouched in v1 (system metadata still sits in PG when you
  switch back to normal mode for live indexing).

## What it skips (vs. normal `envio start`)

- Handler invocation
- `InMemoryStore` and `LoadLayer`
- `entity_history` writes
- Reorg/rollback bookkeeping (only safe within `[start, head − reorgDepth]`)
- Postgres entity tables and `raw_events`

## How to run

Set the env vars and start:

```bash
export ENVIO_BULK_MODE=1
export ENVIO_BULK_SHARDS=8                    # default 8
export ENVIO_BULK_TABLE=erc20_transfers       # default erc20_transfers
export ENVIO_BULK_TO_BLOCK=19000000           # required if config.yaml has no endBlock
export ENVIO_API_TOKEN=...                    # your HyperSync token
export ENVIO_CLICKHOUSE_HOST=http://localhost:8123
export ENVIO_CLICKHOUSE_DATABASE=envio_bulk
export ENVIO_CLICKHOUSE_USERNAME=default
export ENVIO_CLICKHOUSE_PASSWORD=

pnpm envio start
```

The same `config.yaml` you'd use for normal indexing works — bulk mode reads
HyperSync URL, contract addresses, and event signatures from there. v1 takes
the **first contract** and **first event signature** of each chain and writes
that into a single ClickHouse table.

## Verify the data

```sql
-- ClickHouse
SELECT count(), uniqExact(tx_hash) FROM erc20_transfers;
SELECT min(block_number), max(block_number) FROM erc20_transfers;
SELECT contract, count() FROM erc20_transfers GROUP BY contract;
```

## Architecture sketch

```
BulkMode.start            (main thread)
  ├── BulkConfig.buildFromConfig
  ├── initClickHouse                      (CREATE DATABASE + CREATE TABLE)
  └── for each chain in parallel:
        runChain
          ├── makeShardPlan               (even split by block range)
          ├── spawn N workers
          │     └── BulkWorkerEntry → BulkWorker.runFromWorkerThread
          │           ├── HyperSyncClient.make
          │           ├── ClickHouse.createClient
          │           └── loop:
          │                 HyperSync.GetLogs.query →
          │                 decoder.decodeEvents →
          │                 encodeRow →
          │                 chClient.insert(JSONCompactEachRow) →
          │                 postMessage(progress)
          └── startProgressLogger          (stdout updates / 1s)
```

## Limitations (v1, hackathon-quality)

- Hardcoded ERC20 Transfer schema. Other event shapes need a new column list
  + encode function in `BulkSchema.res`.
- No resume — a kill mid-run will redo whatever ranges were unfinished.
  ReplacingMergeTree handles dedup by `(chain_id, block, log_index)` so the
  data ends up correct; only the wall time is wasted.
- No PG shard-progress table yet (planned).
- Even-split sharding — the last shard (closest to head, denser activity)
  typically dominates total time. Density-aware splitting is a follow-up.
- Single event per contract per chain.
- No dynamic contract registration.

## Performance targets

Baseline `envio start` for ERC20 backfill: ~30–60k events/sec.

Expected with bulk mode on a 16-vCPU host with 8 shards:
- Single-threaded: 8–15× baseline (~300–600k ev/s)
- 8-shard: 30–70× baseline (~1.5–3M ev/s)

Cap is HyperSync API rate limit per token, ClickHouse ingest rate, and the
network bandwidth between indexer and CH.

## Files

| File | Role |
|---|---|
| `BulkSchema.res` | Hardcoded ERC20 Transfer schema + DDL generator |
| `BulkConfig.res` | Reads env vars + `Config.t` to build per-chain plan |
| `BulkWorker.res` | Worker thread loop (HyperSync → decode → CH) |
| `BulkWorkerEntry.res` | Worker thread shim called by `Worker(...)` |
| `BulkMode.res` | Main thread coordinator: spawns workers, logs progress |

Hooked into `Bin.res`: when `ENVIO_BULK_MODE=1`, the `Start` command routes
to `BulkMode.start` instead of `Main.start`.
