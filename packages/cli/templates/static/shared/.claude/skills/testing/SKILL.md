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

## Entity State API

Preset state before processing and read entities after.

```ts
// Preset state before processing
indexer.EntityName.set({ id: "...", field: value });

// Read state after processing
await indexer.EntityName.get("id");        // returns entity | undefined
await indexer.EntityName.getOrThrow("id"); // throws if not found
await indexer.EntityName.getAll();         // returns all entities of this type
```

## result.changes

`result.changes` is an array of per-block change objects. Each entry has `block`, `chainId`, `eventsProcessed`, plus entity names as keys with `sets` arrays of created/updated entities. Dynamic contract registrations appear under `addresses.sets`.

## Assertions

```ts
// Snapshot (recommended — captures full output, auto-filled on first run)
t.expect(result.changes).toMatchInlineSnapshot(`...`);

// Entity assertions
const pool = await indexer.Pool.getOrThrow(poolId);
t.expect(pool).toEqual({ id: poolId, token0_id: "0xabc..." });

// Count
t.expect(result.changes[0]?.Pair?.sets).toHaveLength(1);

// Contract addresses (after dynamic registration)
t.expect(indexer.chains[1].MyContract.addresses).toContain("0x1234...");
```

## TDD Workflow

1. **Write a failing test** with expected entity output
2. **Implement the handler** until the test passes
3. **Capture the snapshot** — run `pnpm test` to fill `toMatchInlineSnapshot`
4. **Review and commit** the snapshot for regression testing

## Running Tests

```bash
pnpm test              # Run all tests
pnpm test -- -u        # Update snapshots
```

## Advanced: Finding Block Ranges with HyperSync

Auto-exit mode eliminates the need for manual block discovery in most cases. Use this when you need specific block ranges for pinned snapshots.

**Do NOT web-search for block ranges.** Query HyperSync directly. Endpoint pattern: `https://{chainId}.hypersync.xyz` (e.g., chain 1 → `https://1.hypersync.xyz`).

Common chain IDs: 1 (Ethereum), 8453 (Base), 42161 (Arbitrum), 10 (Optimism), 137 (Polygon), 56 (BSC), 43114 (Avalanche), 100 (Gnosis), 59144 (Linea), 534352 (Scroll), 81457 (Blast), 42220 (Celo).

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

Returns the earliest matching blocks. Use `from_block` to paginate forward. Pick a tight range (50–200 blocks) for fast, deterministic tests.

Full HyperSync query reference: https://docs.envio.dev/docs/HyperSync-LLM/hypersync-complete

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
