---
name: subgraph-migration
description: >-
  Migrate a TheGraph subgraph to Envio HyperIndex using TDD. Covers schema
  conversion (remove @entity, Bytes->String, @derivedFrom), handler translation
  (save->set, store.get->context.get, templates->contractRegister), and
  verification against subgraph data.
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

## Runtime Testing Mandate

**After EVERY code change, run `pnpm test`.** TypeScript compilation only catches syntax errors — runtime errors (database issues, missing entities, logic errors) only appear when running the indexer.

See [references/step-by-step.md](references/step-by-step.md) for the full runtime testing checklist.

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

## Migration Steps Overview

**After each step, run:** `pnpm codegen && pnpm tsc --noEmit && pnpm test`

Full step-by-step details with quality checks: [references/step-by-step.md](references/step-by-step.md)

### Step 1: Clear Boilerplate

Clear generated event handlers and replace with empty TODO handlers.

### Step 2: Migrate Schema

- Remove `@entity` decorators
- `Bytes!` → `String!`
- Keep `BigInt!`, `BigDecimal!`, `ID!`
- ALL entity arrays MUST have `@derivedFrom` (causes a codegen error without it)
- `@derivedFrom` arrays are virtual — cannot access in handlers, only API queries

```graphql
# WRONG — causes "Arrays of entities is unsupported" error
type Transaction { mints: [Mint!]! }

# CORRECT
type Transaction { mints: [Mint!]! @derivedFrom(field: "transaction") }
```

Run: `pnpm codegen` (required after schema changes)

### Step 3: Refactor File Structure

Mirror subgraph file structure with exact filenames. Update `config.yaml` with global contract definitions and chain-specific addresses only.

### Step 4: Register Dynamic Contracts

For factory-created contracts: add `contractRegister` BEFORE handler, remove `address` from dynamic contracts in config.

```ts
Factory.PairCreated.contractRegister(({ event, context }) => {
  context.addPair(event.params.pair);
});
```

### Step 5: Implement Handlers (TDD)

**Implementation order is critical.** See [references/step-by-step.md](references/step-by-step.md) for full 5a/5b/5c/5d breakdown.

1. **5a: Helper functions** with no entity dependencies — implement COMPLETE logic, not placeholders
2. **5b: Simple handlers** — direct parameter mapping
3. **5c: Moderate handlers** — calls helpers, multiple entity updates
4. **5d: Complex handlers** — one at a time, with RPC calls and multiple dependencies

**External calls MUST use Effect API** — see [references/migration-patterns.md](references/migration-patterns.md) for Effect API and contract state fetching patterns.

### Step 6: Final Verification

Systematic review of every handler and helper function against subgraph. Multiple passes — first pass always misses things. See [references/step-by-step.md](references/step-by-step.md) for full verification checklist.

### Step 7: Environment Variables

Search for all `process.env` references and update `.env.example`.

---

## Code Patterns

Full patterns with examples: [references/migration-patterns.md](references/migration-patterns.md)

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

### Entity Updates (spread required — entities are read-only)

```ts
let entity = await context.Entity.get(id);
if (entity) {
  context.Entity.set({ ...entity, field: newValue });
}
```

### Related Entity Queries (@derivedFrom → getWhere)

```ts
// TheGraph: transaction.mints.push(mint);
// Envio:
const mints = await context.Mint.getWhere({ transaction_id: { _eq: transactionId } });
```

### BigDecimal Precision

```ts
import { BigDecimal } from "generated";
// NOT: import { BigDecimal } from "bignumber.js";

export const ZERO_BD = new BigDecimal(0);
export const ONE_BD = new BigDecimal(1);
export const ZERO_BI = BigInt(0);
export const ONE_BI = BigInt(1);
```

### Contract State Fetching (.bind() → Effect API)

TheGraph uses `.bind()` for RPC. Envio requires Effect API with viem. Full pattern: [references/migration-patterns.md](references/migration-patterns.md#contract-state-fetching-bind--effect-api)

---

## Common Issues & Fixes

Full quality check guide with 12 common fixes: [references/quality-checks.md](references/quality-checks.md)

### Field Names — use `_id` suffix
```ts
// WRONG:  { token0: token0.id }
// CORRECT: { token0_id: token0.id }
```

### Missing async/await
```ts
// WRONG:  const entity = context.Entity.get(id);  // Returns {}
// CORRECT: const entity = await context.Entity.get(id);
```
Note: `context.Entity.set()` is synchronous — no await needed.

### Entity Type Imports
```ts
// WRONG:  import { Pair } from "generated";  // Pair is a contract handler, not a type
// CORRECT (when name collides with contract):
import type { Entities } from "generated";
const p: Entities["Pair"] = { ... };
```

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

## Reference Files

- [Step-by-step guide](references/step-by-step.md) — Full procedural walkthrough with quality checks after each step
- [Migration patterns](references/migration-patterns.md) — Entity CRUD, Effect API, contract state fetching, BigDecimal precision
- [Quality checks](references/quality-checks.md) — 12 common fixes, type mismatches, async/await, field selection
- [Migration checklist](references/migration-checklist.md) — 17-point final verification checklist
