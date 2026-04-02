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

HyperIndex uses Vitest with `createTestIndexer()` from `generated`. The simplest way to start is auto-exit mode — no block ranges needed. The indexer automatically finds the first block with events and processes it.

```ts
import { describe, it } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer Testing", () => {
  it("Should process first two blocks with events", async (t) => {
    const indexer = createTestIndexer();

    t.expect(
      await indexer.process({ chains: { 1: {} } }),
      "Should find the first block with an event on chain 1 and process it."
    ).toMatchInlineSnapshot(``);

    t.expect(
      await indexer.process({ chains: { 1: {} } }),
      "Should find the second block with an event on chain 1 and process it."
    ).toMatchInlineSnapshot(``);
  });
});
```

Run `pnpm test` — Vitest auto-fills the snapshots on first run. Review and commit.

## Process API

### Auto-exit (recommended for getting started)

Processes the first block with matching events, then exits. Each subsequent call continues from where the previous one stopped.

```ts
const result = await indexer.process({
  chains: {
    1: {},           // auto-detect first block with events on chain 1
    8453: {},        // same for chain 8453
  },
});
```

### Explicit block range

Process a specific block range. Use when you need deterministic, pinned snapshots.

```ts
const result = await indexer.process({
  chains: {
    1: { startBlock: 10_000_000, endBlock: 10_000_100 },
  },
});
```

### Simulate (mock events)

Feed synthetic events without hitting the network. Best for unit-testing handler logic.

```ts
await indexer.process({
  chains: {
    1: {
      simulate: [
        {
          contract: "ERC20",
          event: "Transfer",
          params: { from: addr1, to: addr2, value: 100n },
        },
      ],
    },
  },
});
```

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
t.expect(result.changes).toMatchInlineSnapshot(`...`);
```

Run `pnpm test` — Vitest auto-fills the snapshot on first run. Review the snapshot, then commit.

### Partial Matching (for specific checks)

```ts
t.expect(result.changes).toContainEqual(
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
t.expect(result.changes[0].Pair?.sets).toHaveLength(1);
```

### Asserting Contract Addresses

```ts
t.expect(indexer.chains[1].MyContract.addresses).toContain("0x1234...");
```

### Reading Entities After Processing

```ts
const pool = await indexer.Pool.get(poolId);
t.expect(pool?.token0_id).toBe("0xabc...");
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

## Advanced: Finding Block Ranges with HyperSync

Auto-exit mode eliminates the need for manual block discovery in most cases. Use this when you need specific block ranges for pinned snapshots.

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

Full HyperSync query reference: https://docs.envio.dev/docs/HyperSync-LLM/hypersync-complete

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
