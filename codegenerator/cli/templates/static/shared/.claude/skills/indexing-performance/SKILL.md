---
name: indexing-performance
description: >-
  Use when optimizing indexer speed or tuning sync performance. HyperSync vs
  RPC, batch size, RPC tuning parameters, database indexes (@index with DESC),
  WebSocket config, and preload optimization.
---

# Performance Tuning

## HyperSync (Default — Fastest)

HyperSync is the default data source for supported chains. Up to 1000x faster than RPC. No configuration needed — automatic for supported networks.

## Batch Size

```yaml
full_batch_size: 5000  # Target events per batch (default: 5000)
```

Reduce if handlers make many slow Effect API calls that can't be batched.

## RPC Tuning

When using RPC as a data source, tune these parameters per chain:

```yaml
chains:
  - id: 1
    rpc:
      - url: ${RPC_URL}
        for: sync                    # sync | live | fallback
        ws: ${WS_URL}               # WebSocket for lower-latency live block detection
        initial_block_interval: 5000 # Starting blocks per query
        backoff_multiplicative: 0.8  # Scale factor after RPC error (0.5-0.9)
        acceleration_additive: 1000  # Blocks added per successful query
        interval_ceiling: 10000      # Max blocks per query
        backoff_millis: 5000         # Wait after error before retry (ms)
        query_timeout_millis: 20000  # Cancel RPC request after this (ms)
        fallback_stall_timeout: 5000 # Switch to next RPC after stall (ms)
        polling_interval: 1000       # Check for new blocks every N ms (default: 1000)
```

### RPC `for` Options

| Value | Description |
|-------|-------------|
| `sync` | RPC as main data source for both historical and live |
| `live` | HyperSync for historical, switch to RPC for live (lower latency) |
| `fallback` | Backup when primary stalls (default when HyperSync available) |

### WebSocket for Live Indexing

Add `ws:` for lower-latency new block detection via `eth_subscribe("newHeads")`:

```yaml
rpc:
  - url: ${ENVIO_RPC_ENDPOINT}
    ws: ${ENVIO_WS_ENDPOINT}
    for: live
```

## Database Indexes

Add `@index` to schema fields for faster queries:

```graphql
type Transfer {
  id: ID!
  from: String! @index
  to: String! @index
  value: BigInt!
  timestamp: BigInt! @index
}
```

### Composite Index with DESC

```graphql
type Trade @index(fields: ["poolId", ["date", "DESC"]]) {
  id: ID!
  poolId: String!
  date: BigInt!
  volume: BigDecimal!
}
```

- Fields default to ASC; use `["field", "DESC"]` for descending
- IDs and `@derivedFrom` fields are automatically indexed
- Index impact: 1M+ records go from 5+ seconds → ~5ms for queries

## Development Mode

Disable reorg rollback during development for faster historical sync:

```yaml
rollback_on_reorg: false  # Default: true. Turn off during development only.
```

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
