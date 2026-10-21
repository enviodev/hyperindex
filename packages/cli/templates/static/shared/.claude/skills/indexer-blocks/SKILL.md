---
name: indexer-blocks
description: >-
  Use when processing every block (or every Nth block) for time-series data,
  periodic snapshots, or block-level aggregations. indexer.onBlock API, where
  filter with block-number range and stride, and block handler context.
metadata:
  managed-by: envio
---

# Block Handlers

Process every block (or every Nth block) using `indexer.onBlock`. No contract
address or `config.yaml` entry needed.

## Handler

Branch by `chain.id` with a `switch` so the type system flags any
unconfigured chain via the `default: never` exhaustiveness check:

```ts
import { indexer } from "envio";

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
| `fields` | `{ block?: BlockField[] }` | no | Block fields the handler reads besides the number, e.g. `{ block: ["timestamp", "hash"] }`. Selecting any makes the indexer fetch every block the handler runs on, so keep `_every` as large as the use case allows. Reading a field not listed is a type error. `config.yaml` `field_selection` does not apply to block handlers. |

## Block fields

```ts
indexer.onBlock(
  { name: "Timestamps", where: () => ({ block: { number: { _every: 1000 } } }), fields: { block: ["timestamp"] } },
  async ({ block, context }) => {
    context.BlockTime.set({ id: `${block.number}`, timestamp: block.timestamp });
  }
);
```

In `createTestIndexer`, give the fields of a block as its own simulate item: `simulate: [{ block: { number: 1000, timestamp: 1700000000 } }]`. A block without one gets the same defaults as an event's block.

## Other ecosystems

- **Fuel**: same `indexer.onBlock` API; filter is keyed by `block.height` instead of `block.number`, and `fields.block` selects from `id` and `time`.
- **SVM**: use `indexer.onSlot`; filter shape is `{slot: {_gte?, _lte?, _every?}}` and the handler arg is `{slot: number, context}`. With `fields: { block: ["time", "hash", ...] }` it also gets `block` — and runs only on slots that produced a block, since a skipped slot has none. In `createTestIndexer` that means the slots given a `{ block: { slot, ... } }` simulate item.

## Notes

- `indexer.onBlock` self-registers — no `config.yaml` entry needed
- No events or contract address required
- The handler context has the same entity API as event handlers
- If `where` returns `false` for every configured chain, a warning is logged at registration time
- For per-event startBlock (not stride), use `indexer.onEvent` with `where.block.number._gte` (see `indexer-filters`). Event filters accept `_gte` only; `_lte`/`_every` are reserved for `onBlock`.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
