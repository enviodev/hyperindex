# TheGraph to Envio HyperIndex Migration Guide

Migrate from TheGraph subgraph indexer to Envio HyperIndex indexer using Test-Driven Development.

## Before Starting

**Ask the user for:**
1. **Subgraph GraphQL endpoint** (e.g., `https://api.thegraph.com/subgraphs/name/org/subgraph`)
2. **Chain ID and contract addresses**
3. **Block range for testing** (pick blocks with representative events)

The subgraph GraphQL is the **source of truth** - use it to verify HyperIndex produces identical data.

**Prerequisites:**
- Subgraph folder in workspace
- Node.js v22+ (v24 recommended)
- pnpm package manager

**Reference Documentation:**
- Envio: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
- Example (Uniswap v4): https://github.com/enviodev/uniswap-v4-indexer

---

## TDD Migration Flow

Instead of constantly running `pnpm dev` and `tsc`, use the **HyperIndex Testing Framework**:

1. **Query subgraph** for expected entity state at specific blocks
2. **Write test** that processes those blocks and asserts expected output
3. **Implement handler** until test passes
4. **Repeat** for each handler

```typescript
// test/migration.test.ts
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Migration Verification", () => {
  it("Should match subgraph data for Factory.PairCreated", async () => {
    const indexer = createTestIndexer();

    // Process specific block range
    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 10_000_000,
          endBlock: 10_000_100,
        },
      },
    });

    // Verify against subgraph data (queried beforehand)
    expect(result).toMatchInlineSnapshot(`
      {
        "changes": [
          {
            "Pair": {
              "sets": [
                {
                  "id": "1-0x...",
                  "token0_id": "0x...",
                  "token1_id": "0x...",
                },
              ],
            },
            "block": 10000050,
            "chainId": 1,
          },
        ],
      }
    `);
  });
});
```

**Run tests:** `pnpm test`

---

## Quick Reference: Key Differences

| TheGraph | Envio |
|----------|-------|
| `@entity` decorator | No decorator needed |
| `Bytes!` | `String!` |
| `entity.save()` | `context.Entity.set(entity)` |
| `store.get("Entity", id)` | `await context.Entity.get(id)` |
| `ContractTemplate.create(addr)` | `context.addContract(addr)` in `contractRegister` |
| Direct array access | `@derivedFrom` (virtual, query via `getWhere`) |
| `.bind()` for RPC | Effect API with `context.effect()` |

---

## Migration Steps

### Step 1: Setup & Query Subgraph

**Query subgraph for sample data:**

```graphql
# Get entities at specific block
{
  pairs(first: 10, block: { number: 10000000 }) {
    id
    token0 { id symbol decimals }
    token1 { id symbol decimals }
    reserve0
    reserve1
  }
}
```

**Create test file with expected data:**

```typescript
// test/pairs.test.ts
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Pair entity migration", () => {
  it("Should create Pair entities matching subgraph", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: { startBlock: 10_008_355, endBlock: 10_008_355 },
      },
    });

    // Expected data from subgraph query
    expect(result.changes).toContainEqual(
      expect.objectContaining({
        Pair: {
          sets: expect.arrayContaining([
            expect.objectContaining({
              id: "1-0xb4e16d0168e52d35cacd2c6185b44281ec28c9dc",
              token0_id: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
              token1_id: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
            }),
          ]),
        },
      })
    );
  });
});
```

---

### Step 2: Migrate Schema

Convert TheGraph schema to Envio format:

```graphql
# TheGraph:
type Entity @entity(immutable: true) {
  id: Bytes!
  field: Bytes!
  value: BigInt!
}

# Envio:
type Entity {
  id: ID!
  field: String!
  value: BigInt!
}
```

**Key changes:**
- Remove `@entity` decorators
- `Bytes!` → `String!`
- Keep `BigInt!`, `BigDecimal!`, `ID!`

**Entity arrays MUST have `@derivedFrom`:**

```graphql
# WRONG - causes "EE211: Arrays of entities is unsupported"
type Transaction {
  mints: [Mint!]!
}

# CORRECT
type Transaction {
  mints: [Mint!]! @derivedFrom(field: "transaction")
}
```

**Note:** `@derivedFrom` arrays are virtual - cannot access in handlers, only in API queries.

**Run:** `pnpm codegen` (required after schema changes)

---

### Step 3: Refactor File Structure

Mirror subgraph file structure:

```
src/
├── utils/
│   ├── pricing.ts
│   └── helpers.ts
├── handlers/
│   ├── factory.ts
│   └── pair.ts
test/
├── factory.test.ts
└── pair.test.ts
```

Update `config.yaml`:

```yaml
# Global contract definitions
contracts:
  - name: Factory
    events:
      - event: PairCreated(...)

# Chain-specific addresses only
chains:
  - id: 1
    contracts:
      - name: Factory
        address:
          - 0xFactoryAddress
```

**Run:** `pnpm codegen` (required after config changes)

---

### Step 4: Register Dynamic Contracts

For contracts created by factories (templates in subgraph):

```typescript
// Register BEFORE handler
Factory.PairCreated.contractRegister(({ event, context }) => {
  context.addPair(event.params.pair);
});

Factory.PairCreated.handler(async ({ event, context }) => {
  // Handler logic
});
```

Remove `address` field from dynamic contracts in `config.yaml`.

**Write test first:**

```typescript
it("Should register dynamic Pair contracts", async () => {
  const indexer = createTestIndexer();

  const result = await indexer.process({
    chains: {
      1: { startBlock: 10_000_835, endBlock: 10_000_835 },
    },
  });

  // Verify Pair was created
  expect(result.changes[0].Pair?.sets).toHaveLength(1);
});
```

---

### Step 5: Implement Handlers (TDD)

For each handler:

1. **Query subgraph** for expected state at test block
2. **Write failing test** with expected data
3. **Implement handler** until test passes
4. **Snapshot the result** for regression testing

**Example TDD cycle:**

```typescript
// 1. Query subgraph at block 10861674 for Token entities
// 2. Write test:
it("Should create Token on first Transfer", async () => {
  const indexer = createTestIndexer();

  expect(
    await indexer.process({
      chains: {
        1: { startBlock: 10_861_674, endBlock: 10_861_674 },
      },
    })
  ).toMatchInlineSnapshot(`
    {
      "changes": [
        {
          "Token": {
            "sets": [
              {
                "id": "1-0x...",
                "symbol": "UNI",
                "decimals": 18n,
                "totalSupply": 1000000000000000000000000000n,
              },
            ],
          },
          "block": 10861674,
          "chainId": 1,
        },
      ],
    }
  `);
});

// 3. Implement handler until test passes
// 4. Run: pnpm test
```

**Order of implementation:**
1. Helper functions (no entity dependencies)
2. Simple handlers (direct parameter mapping)
3. Moderate handlers (calls helpers)
4. Complex handlers (multiple entities, RPC calls)

---

### Step 6: Final Verification

**Compare full block range against subgraph:**

```typescript
it("Should match subgraph for full block range", async () => {
  const indexer = createTestIndexer();

  const result = await indexer.process({
    chains: {
      1: { startBlock: 10_000_000, endBlock: 10_100_000 },
    },
  });

  // Query subgraph for same range and compare key metrics
  // - Total entity counts
  // - Specific entity values
  // - Aggregate calculations
});
```

---

## Code Patterns

### Entity Creation

```typescript
// TheGraph:
let entity = new Entity(id);
entity.field = value;
entity.save();

// Envio:
const entity: Entity = {
  id: `${event.chainId}-${id}`,
  field: value,
  blockNumber: BigInt(event.block.number),
  transactionHash: event.transaction.hash,
};
context.Entity.set(entity);
```

**Note:** `transaction.hash` requires `field_selection` in config:

```yaml
- event: Transfer(...)
  field_selection:
    transaction_fields:
      - hash
```

### Entity Updates

```typescript
// TheGraph:
let entity = store.get("Entity", id);
entity.field = newValue;
entity.save();

// Envio:
let entity = await context.Entity.get(id);
if (entity) {
  context.Entity.set({
    ...entity,
    field: newValue,
  });
}
```

### Related Entity Queries

```typescript
// TheGraph (direct array access):
transaction.mints.push(mint);

// Envio (query via indexed field):
const mints = await context.Mint.getWhere.transaction_id.eq(transactionId);
```

---

## Effect API (External Calls)

**ALL external calls MUST use Effect API:**

```typescript
// src/effects/tokenMetadata.ts
import { createEffect, S } from "envio";
import { createPublicClient, http, parseAbi } from "viem";

const ERC20_ABI = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

const client = createPublicClient({
  chain: { id: 1, name: "mainnet", ... },
  transport: http(process.env.RPC_URL),
});

export const getTokenMetadata = createEffect(
  {
    name: "getTokenMetadata",
    input: S.string,
    output: S.object({
      name: S.string,
      symbol: S.string,
      decimals: S.number,
    }),
    cache: true,
  },
  async ({ input: address }) => {
    const [name, symbol, decimals] = await Promise.all([
      client.readContract({ address, abi: ERC20_ABI, functionName: "name" }),
      client.readContract({ address, abi: ERC20_ABI, functionName: "symbol" }),
      client.readContract({ address, abi: ERC20_ABI, functionName: "decimals" }),
    ]);
    return { name, symbol, decimals: Number(decimals) };
  }
);
```

**Usage in handler:**

```typescript
import { getTokenMetadata } from "./effects/tokenMetadata";

Contract.Event.handler(async ({ event, context }) => {
  const metadata = await context.effect(getTokenMetadata, event.params.token);
  // Use metadata...
});
```

---

## Multichain Support

- Prefix all entity IDs: `${event.chainId}-${originalId}`
- Never hardcode `chainId = 1` - use `event.chainId`
- Chain-specific Bundle IDs: `${chainId}-1`

---

## Common Issues & Fixes

### Issue 1: Field Names

```typescript
// WRONG:
const pair = { token0: token0.id };

// CORRECT:
const pair = { token0_id: token0.id };
```

### Issue 2: BigDecimal Import

```typescript
// WRONG:
import { BigDecimal } from "bignumber.js";

// CORRECT:
import { BigDecimal } from "generated";
```

### Issue 3: Missing async/await

```typescript
// WRONG:
const entity = context.Entity.get(id); // Returns {}

// CORRECT:
const entity = await context.Entity.get(id);
```

Note: `context.Entity.set()` is synchronous - no await needed.

### Issue 4: Schema Type Mapping

| Schema | TypeScript |
|--------|------------|
| `Int!` | `number` |
| `BigInt!` | `bigint` / `ZERO_BI` |
| `BigDecimal!` | `BigDecimal` / `ZERO_BD` |
| `String!` / `Bytes!` | `string` |
| `Entity!` | `entity_id: string` |

---

## Quality Checklist

- [ ] Subgraph GraphQL endpoint obtained
- [ ] Test blocks identified with representative events
- [ ] All `@entity` decorators removed
- [ ] `Bytes!` → `String!` in schema
- [ ] All entity arrays have `@derivedFrom`
- [ ] Entity IDs prefixed with `chainId`
- [ ] All external calls use Effect API
- [ ] BigDecimal precision maintained
- [ ] Field names match generated types (`_id` suffix for relations)
- [ ] `field_selection` added for transaction fields
- [ ] Tests pass and match subgraph data
- [ ] Snapshots captured for regression testing
