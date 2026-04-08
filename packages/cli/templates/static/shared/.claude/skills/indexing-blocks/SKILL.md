---
name: indexing-blocks
description: >-
  Use when processing every block (or every Nth block) for time-series data,
  periodic snapshots, or block-level aggregations. indexer.onBlock API, where
  filter with block-number range and stride, and block handler context.
---

# Block Handlers

Process every block (or every Nth block) using `indexer.onBlock`. No contract address or config.yaml entry needed.

## Handler

```ts
import { indexer } from "generated";

indexer.onBlock(
  {
    name: "BlockTracker",
    where: ({ chain }) => {
      if (chain.id !== 1) return false;
      return { block: { number: { _every: 100 } } };
    },
  },
  async ({ block, context }) => {
    context.BlockSnapshot.set({
      id: `${block.number}`,
      blockNumber: BigInt(block.number),
      timestamp: BigInt(block.timestamp),
    });
  }
);
```

## Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `name` | `string` | yes | Handler name for logging |
| `where` | `({ chain }) => boolean \| filter` | no | Predicate evaluated once per configured chain at registration. Return `false` to skip a chain, `true` / omit to match every block, or `{block: {number: {_gte?, _lte?, _every?}}}` to restrict range and stride. `_every` aligns relative to `_gte`, preserving `(blockNumber - _gte) % _every === 0`. |

## Notes

- `indexer.onBlock` self-registers — no config.yaml entry needed
- No events or contract address required
- EVM chains only
- The handler context has the same entity API as event handlers
- `block` object provides `number` and `timestamp` (more fields may be added)

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
