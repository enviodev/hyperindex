---
name: indexing-blocks
description: >-
  Use when processing every block (or every Nth block) for time-series data,
  periodic snapshots, or block-level aggregations. indexer.onBlock API, where
  filter with block-number range and stride, and block handler context.
---

# Block Handlers

Process every block (or every Nth block) using `indexer.onBlock`. No contract
address or `config.yaml` entry needed.

## Handler

Branch by `chain.id` with a `switch` so the type system flags any
unconfigured chain via the `default: never` exhaustiveness check:

```ts
import { indexer } from "generated";

indexer.onBlock(
  {
    name: "BlockTracker",
    where: ({ chain }) => {
      switch (chain.id) {
        case 1:
          return { block: { number: { _gte: 18000000, _every: 100 } } };
        case 8453:
          return { block: { number: { _every: 50 } } };
        default: {
          // Exhaustiveness check: TypeScript errors here if a new chain ID
          // is added to config.yaml but not handled above.
          const _exhaustive: never = chain.id;
          return false;
        }
      }
    },
  },
  async ({ block, context }) => {
    context.BlockSnapshot.set({
      id: `${block.number}`,
      blockNumber: BigInt(block.number),
    });
  }
);
```

## Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `name` | `string` | yes | Handler name for logging |
| `where` | `({ chain }) => boolean \| filter` | no | Predicate evaluated once per configured chain at registration. Return `false` to skip a chain, `true` / omit to match every block, or `{block: {number: {_gte?, _lte?, _every?}}}` to restrict range and stride. `_every` aligns relative to `_gte`, preserving `(blockNumber - _gte) % _every === 0`. |

## Other ecosystems

- **Fuel**: same `indexer.onBlock` API; filter is keyed by `block.height` instead of `block.number`.
- **SVM**: use `indexer.onSlot`; filter shape is `{slot: {_gte?, _lte?, _every?}}` and the handler arg is `{slot: number, context}` (no `block` wrapper).

## Notes

- `indexer.onBlock` self-registers — no `config.yaml` entry needed
- No events or contract address required
- The handler context has the same entity API as event handlers
- If `where` returns `false` for every configured chain, a warning is logged at registration time

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
