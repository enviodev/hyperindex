---
name: subgraph-migration
description: >-
  Migrate a TheGraph subgraph to Envio HyperIndex using TDD. Covers schema
  conversion (remove @entity, Bytes->String, @derivedFrom), handler translation
  (save->set, store.get->context.get, templates->contractRegister), and
  verification against subgraph data. Invoke with /subgraph-migration.
disable-model-invocation: true
---

# TheGraph to Envio HyperIndex Migration

Migrate from TheGraph subgraph to Envio HyperIndex using Test-Driven Development.

## Before Starting

**Ask the user for:**
1. **Subgraph GraphQL endpoint** (e.g., `https://api.thegraph.com/subgraphs/name/org/subgraph`)
2. **Chain ID and contract addresses**
3. **Block range for testing** (pick blocks with representative events)

The subgraph GraphQL is the **source of truth** — use it to verify HyperIndex produces identical data.

**Prerequisites:** Subgraph folder in workspace, Node.js v22+, pnpm, Docker

**References:**
- Envio docs: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
- Example (Uniswap v4): https://github.com/enviodev/uniswap-v4-indexer

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

## TDD Migration Flow

1. **Query subgraph** for expected entity state at specific blocks
2. **Write test** that processes those blocks and asserts expected output
3. **Implement handler** until test passes
4. **Repeat** for each handler

```ts
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Migration Verification", () => {
  it("Should match subgraph data for Factory.PairCreated", async () => {
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

Run tests: `pnpm test`

---

## Step 1: Setup & Query Subgraph

Query subgraph for sample data at specific blocks:

```graphql
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

Write test with expected data:

```ts
describe("Pair entity migration", () => {
  it("Should create Pair entities matching subgraph", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: { startBlock: 10_008_355, endBlock: 10_008_355 },
      },
    });

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

## Step 2: Migrate Schema

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

Key changes:
- Remove `@entity` decorators
- `Bytes!` → `String!`
- Keep `BigInt!`, `BigDecimal!`, `ID!`

Entity arrays MUST have `@derivedFrom`:

```graphql
# WRONG — causes "EE211: Arrays of entities is unsupported"
type Transaction {
  mints: [Mint!]!
}

# CORRECT
type Transaction {
  mints: [Mint!]! @derivedFrom(field: "transaction")
}
```

`@derivedFrom` arrays are virtual — cannot access in handlers, only in API queries.

Run: `pnpm codegen` (required after schema changes)

## Step 3: Refactor File Structure

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
contracts:
  - name: Factory
    events:
      - event: PairCreated(...)

chains:
  - id: 1
    contracts:
      - name: Factory
        address:
          - 0xFactoryAddress
```

Run: `pnpm codegen` (required after config changes)

## Step 4: Register Dynamic Contracts

For contracts created by factories (templates in subgraph):

```ts
// Register BEFORE handler
Factory.PairCreated.contractRegister(({ event, context }) => {
  context.addPair(event.params.pair);
});

Factory.PairCreated.handler(async ({ event, context }) => {
  // Handler logic
});
```

Remove `address` field from dynamic contracts in `config.yaml`.

Write test first:

```ts
it("Should register dynamic Pair contracts", async () => {
  const indexer = createTestIndexer();

  const result = await indexer.process({
    chains: {
      1: { startBlock: 10_000_835, endBlock: 10_000_835 },
    },
  });

  expect(result.changes[0].Pair?.sets).toHaveLength(1);
});
```

## Step 5: Implement Handlers (TDD)

For each handler:

1. **Query subgraph** for expected state at test block
2. **Write failing test** with expected data
3. **Implement handler** until test passes
4. **Snapshot the result** for regression testing

Order of implementation:
1. Helper functions (no entity dependencies)
2. Simple handlers (direct parameter mapping)
3. Moderate handlers (calls helpers)
4. Complex handlers (multiple entities, RPC calls)

Example TDD cycle:

```ts
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
  ).toMatchInlineSnapshot(`...`);
});

// 3. Implement handler until test passes
// 4. Run: pnpm test
```

## Step 6: Final Verification

Compare full block range against subgraph:

```ts
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

```ts
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

`transaction.hash` requires `field_selection` in config:

```yaml
- event: Transfer(...)
  field_selection:
    transaction_fields:
      - hash
```

### Entity Updates

```ts
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

```ts
// TheGraph (direct array access):
transaction.mints.push(mint);

// Envio (query via indexed field):
const mints = await context.Mint.getWhere({ transaction_id: { _eq: transactionId } });
```

### BigDecimal

```ts
// Import from generated
import { BigDecimal } from "generated";

// NOT: import { BigDecimal } from "bignumber.js";
```

---

## Common Issues & Fixes

### Field Names
```ts
// WRONG:
const pair = { token0: token0.id };
// CORRECT:
const pair = { token0_id: token0.id };
```

### Missing async/await
```ts
// WRONG:
const entity = context.Entity.get(id); // Returns {}
// CORRECT:
const entity = await context.Entity.get(id);
```

Note: `context.Entity.set()` is synchronous — no await needed.

### Schema Type Mapping

| Schema | TypeScript |
|--------|------------|
| `Int!` | `number` |
| `BigInt!` | `bigint` / `ZERO_BI` |
| `BigDecimal!` | `BigDecimal` / `ZERO_BD` |
| `String!` / `Bytes!` | `string` |
| `Entity!` | `entity_id: string` |

### Multichain IDs
Prefix all entity IDs: `${event.chainId}-${originalId}`

---

## Quality Checklist

See [references/migration-checklist.md](references/migration-checklist.md) for the full 17-point quality checklist.
