---
name: indexing-blocks
description: >-
  Use when processing every block (or every Nth block) for time-series data,
  periodic snapshots, or block-level aggregations. indexer.onBlock (EVM/Fuel)
  and indexer.onSlot (SVM) APIs, where filter with range and stride, and
  handler context.
---

# Block / Slot Handlers

Process every block (or every Nth block) using `indexer.onBlock` on EVM/Fuel, or every slot using `indexer.onSlot` on SVM. No contract address or config.yaml entry needed.

## EVM handler

```ts
import { indexer } from "generated";

indexer.onBlock(
  {
    name: "BlockTracker",
    where: ({ chain }) => {
      if (chain.id !== 1) return false;
      return { block: { number: { _gte: 18000000, _every: 100 } } };
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

## Fuel handler

Fuel filters on `block.height` (not `number`), matching the handler-arg field:

```ts
indexer.onBlock(
  {
    name: "FuelHeightSampler",
    where: ({ chain }) =>
      chain.id === 9889 ? { block: { height: { _every: 10 } } } : false,
  },
  async ({ block, context }) => { /* block.height */ }
);
```

## SVM handler

SVM uses `indexer.onSlot` with a `slot`-keyed filter:

```ts
indexer.onSlot(
  {
    name: "SlotSampler",
    where: ({ chain }) =>
      chain.id === 0 ? { slot: { _gte: 250_000_000, _every: 100 } } : false,
  },
  async ({ slot, context }) => { /* slot is a number */ }
);
```

## Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `name` | `string` | yes | Handler name for logging |
| `where` | `({ chain }) => boolean \| filter` | no | Predicate evaluated once per configured chain at registration. Return `false` to skip a chain, `true` / omit to match every block/slot. Filter shape: EVM `{block: {number: {_gte?, _lte?, _every?}}}`, Fuel `{block: {height: {_gte?, _lte?, _every?}}}`, SVM `{slot: {_gte?, _lte?, _every?}}`. `_every` aligns relative to `_gte`, preserving `(n - _gte) % _every === 0`. |

## Notes

- `indexer.onBlock` / `indexer.onSlot` self-register — no config.yaml entry needed
- No events or contract address required
- The handler context has the same entity API as event handlers
- `block` object provides `number` (EVM) or `height` (Fuel); SVM provides `slot: number` at the top level
- If `where` returns `false` for every configured chain, a warning is logged at registration time

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
