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
  },
});
```

## Finding Block Ranges with HyperSync

**Do NOT web-search for block ranges.** Use HyperSync directly to find blocks where your contracts/events actually occur. The HyperSync API key from `.env` (`ENVIO_API_TOKEN`) works for these queries.

### Step 1: Identify What to Query

From `config.yaml`, extract:
- Contract addresses
- Event signatures (topic0 hashes)
- Chain ID → HyperSync endpoint: `https://{chainId}.hypersync.xyz` (e.g., chain 1 → `https://1.hypersync.xyz`)

Common chain IDs: 1 (Ethereum), 8453 (Base), 42161 (Arbitrum), 10 (Optimism), 137 (Polygon), 56 (BSC), 43114 (Avalanche), 100 (Gnosis), 59144 (Linea), 534352 (Scroll), 81457 (Blast), 42220 (Celo).

### Step 2: Query HyperSync for Matching Blocks

```bash
curl --request POST \
  --url https://1.hypersync.xyz/query \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $ENVIO_API_TOKEN" \
  --data '{
    "from_block": 0,
    "logs": [
      {
        "address": ["0xYOUR_CONTRACT_ADDRESS"],
        "topics": [
          ["0xYOUR_EVENT_TOPIC0"]
        ]
      }
    ],
    "field_selection": {
      "log": ["block_number"]
    }
  }'
```

This returns the earliest blocks matching your filter. Use `from_block` to paginate forward.

### Step 3: Pick a Tight Block Range

From the response, pick a small range (50–200 blocks) around the first few matching blocks. This keeps tests fast and deterministic.

### Advanced: Multi-Topic and Transaction Queries

Query by topic combinations (e.g., Transfer events to/from an address) and transactions:

```bash
curl --request POST \
  --url https://1.hypersync.xyz/query \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $ENVIO_API_TOKEN" \
  --data '{
    "from_block": 0,
    "logs": [
      {
        "topics": [
          ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
          [],
          ["0x0000000000000000000000001e037f97d730Cc881e77F01E409D828b0bb14de0"]
        ]
      },
      {
        "topics": [
          ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
          ["0x0000000000000000000000001e037f97d730Cc881e77F01E409D828b0bb14de0"],
          []
        ]
      }
    ],
    "transactions": [
      { "from": ["0x1e037f97d730Cc881e77F01E409D828b0bb14de0"] },
      { "to": ["0x1e037f97d730Cc881e77F01E409D828b0bb14de0"] }
    ],
    "field_selection": {
      "block": ["number", "timestamp", "hash"],
      "log": ["block_number", "log_index", "transaction_index", "data", "address", "topic0", "topic1", "topic2", "topic3"],
      "transaction": ["block_number", "transaction_index", "hash", "from", "to", "value", "input"]
    }
  }'
```

Full HyperSync query reference: https://docs.envio.dev/docs/HyperSync-LLM/hypersync-complete

## result.changes Structure

`result.changes` is an array of block-level change objects:

```ts
[
  {
    block: 12369739,
    blockHash: "0xe8228e3e736a42c7357d2ce6882a1662c588ce608897dd53c3053bcbefb4309a",
    chainId: 1,
    eventsProcessed: 1,
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

Each block entry includes `block`, `blockHash`, `chainId`, `eventsProcessed`, plus entity names as keys with `sets` arrays showing entities that were created or updated. Dynamic contract registrations appear under `addresses.sets`.

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

### Asserting Contract Addresses

```ts
expect(indexer.chains[1].MyContract.addresses).toContain("0x1234...");
```

### Reading Entities After Processing

```ts
const pool = await indexer.Pool.get(poolId);
expect(pool?.token0_id).toBe("0xabc...");
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
