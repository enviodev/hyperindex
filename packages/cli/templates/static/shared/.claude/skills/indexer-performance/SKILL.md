---
name: indexer-performance
description: >-
  Use when optimizing indexer speed or tuning sync performance. HyperSync,
  batch size, WebSocket realtime config, and preload optimization.
metadata:
  managed-by: envio
---

# Performance Tuning

## HyperSync (Default — Fastest)

HyperSync is the default data source for supported chains. Up to 1000x faster than RPC. No configuration needed — automatic for supported networks.

## Batch Size

```yaml
full_batch_size: 5000  # Target events per batch (default: 5000)
```

Reduce if handlers make many slow Effect API calls that can't be batched.

## WebSocket for Realtime Indexing

Add `ws:` for lower-latency new block detection via `eth_subscribe("newHeads")`:

```yaml
rpc:
  - url: ${ENVIO_RPC_ENDPOINT}
    ws: ${ENVIO_WS_ENDPOINT}
    for: realtime
```

## Database Indexes

Add `@index` to schema fields for faster queries — see `indexer-schema` for full syntax (single-field, composite, DESC direction).

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
