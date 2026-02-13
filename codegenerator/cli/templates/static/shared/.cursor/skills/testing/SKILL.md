---
name: testing
description: >-
  Write and run tests for HyperIndex indexers using Vitest and createTestIndexer().
  Covers test setup, processing block ranges, asserting entity changes with
  toMatchInlineSnapshot, and TDD workflow. Use when writing tests, debugging
  handler output, or verifying indexer behavior.
---

# HyperIndex Testing

## Setup

HyperIndex uses Vitest with `createTestIndexer()` from `generated`.

```ts
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Handler tests", () => {
  it("processes events correctly", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: { startBlock: 10_000_000, endBlock: 10_000_100 },
      },
    });

    expect(result.changes).toMatchInlineSnapshot(`...`);
  });
});
```

## Process API

```ts
const result = await indexer.process({
  chains: {
    // Chain ID → block range
    1: { startBlock: 10_000_000, endBlock: 10_000_100 },
    // Multiple chains supported
    137: { startBlock: 50_000_000, endBlock: 50_000_050 },
  },
});
```

## result.changes Structure

`result.changes` is an array of block-level change objects:

```ts
[
  {
    block: 10000050,
    chainId: 1,
    Token: {
      sets: [
        { id: "1-0x...", symbol: "UNI", decimals: 18n },
      ],
    },
    Pair: {
      sets: [
        { id: "1-0x...", token0_id: "0x...", token1_id: "0x..." },
      ],
    },
  },
]
```

Each block entry contains entity names as keys, with `sets` arrays showing entities that were created or updated.

## Assertion Patterns

### Snapshot Testing (recommended for full verification)

```ts
expect(result.changes).toMatchInlineSnapshot(`...`);
```

Run `pnpm test` — Vitest auto-fills the snapshot on first run. Review the snapshot, then commit.

### Partial Matching (for specific checks)

```ts
expect(result.changes).toContainEqual(
  expect.objectContaining({
    Pair: {
      sets: expect.arrayContaining([
        expect.objectContaining({
          id: "1-0xb4e16d0168e52d35cacd2c6185b44281ec28c9dc",
          token0_id: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        }),
      ]),
    },
  })
);
```

### Count Assertions

```ts
expect(result.changes[0].Pair?.sets).toHaveLength(1);
```

## TDD Workflow

1. **Write a failing test** with expected entity output
2. **Implement the handler** until the test passes
3. **Capture the snapshot** — run `pnpm test` to fill `toMatchInlineSnapshot`
4. **Review and commit** the snapshot for regression testing
5. **Repeat** for each handler/event type

## Running Tests

```bash
pnpm test              # Run all tests
pnpm test -- --watch   # Watch mode
pnpm test -- -u        # Update snapshots
```

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
