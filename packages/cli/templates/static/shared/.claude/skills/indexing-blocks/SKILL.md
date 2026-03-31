---
name: indexing-blocks
description: >-
  Use when processing every block (or every Nth block) for time-series data,
  periodic snapshots, or block-level aggregations. onBlock API, interval
  option, and block handler context.
---

# Block Handlers

Process every block (or every Nth block) using `onBlock` from `generated`. No contract address or config.yaml entry needed.

## Handler

```ts
import { onBlock } from "generated";

onBlock(
  { name: "BlockTracker", chain: 1, interval: 100 },
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
| `chain` | `number` | yes | Chain ID to process |
| `interval` | `number` | no | Process every Nth block (default: 1) |
| `startBlock` | `number` | no | Inclusive start block |
| `endBlock` | `number` | no | Inclusive end block |

## Notes

- `onBlock` self-registers — no config.yaml entry needed
- No events or contract address required
- EVM chains only
- The handler context has the same entity API as event handlers
- `block` object provides `number` and `timestamp` (more fields may be added)

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
