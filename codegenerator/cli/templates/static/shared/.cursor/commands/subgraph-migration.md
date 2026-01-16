# TheGraph to Envio HyperIndex Migration Guide

Migrate from TheGraph subgraph indexer to Envio HyperIndex indexer.

**Prerequisites:**
- Subgraph folder in workspace
- Node.js v22+ (v24 recommended)
- pnpm package manager
- Docker installed

**Whitelist these commands:**
- `pnpm codegen`
- `pnpm tsc --noEmit`
- `TUI_OFF=true pnpm dev`

**Reference Documentation:**
- Envio: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
- Example (Uniswap v4): https://github.com/enviodev/uniswap-v4-indexer
- Example (Safe): https://github.com/enviodev/safe-analysis-indexer

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

## Multichain Support

- Prefix all entity IDs: `${event.chainId}-${originalId}`
- Never hardcode `chainId = 1` - use `event.chainId`
- Chain-specific Bundle IDs: `${chainId}-1`

---

## Migration Steps

### Step 1: Clear Boilerplate Code

Replace generated handlers with empty skeletons:

```typescript
// BEFORE (boilerplate):
Contract.EventName.handler(async ({ event, context }) => {
  const entity: EventEntity = {
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    field1: event.params.field1,
  };
  context.EventEntity.set(entity);
});

// AFTER (skeleton):
Contract.EventName.handler(async ({ event, context }) => {
  // TODO: Implement from subgraph
});
```

**Validate:** `pnpm codegen && pnpm tsc --noEmit`

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

**Validate:** `pnpm codegen`

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

**Validate:** `pnpm codegen && pnpm tsc --noEmit`

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

**Validate:** `pnpm codegen && TUI_OFF=true pnpm dev`

---

### Step 5: Implement Handlers

**Order:**
1. **5a: Helper functions** (no entity dependencies)
2. **5b: Simple handlers** (direct parameter mapping)
3. **5c: Moderate handlers** (calls helpers, straightforward logic)
4. **5d: Complex handlers** (multiple entities, RPC calls)

**Validate after each:** `pnpm codegen && pnpm tsc --noEmit && TUI_OFF=true pnpm dev`

---

### Step 6: Final Verification

1. Compare each handler to subgraph implementation
2. Verify all edge cases handled
3. Ensure no TODOs remain
4. Run full validation

---

### Step 7: Environment Variables

```bash
grep -r "process.env\." src/
```

Document all in `.env.example`.

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

**Preload note:** Handlers run twice (parallel preload, then sequential). Use `context.effect()` or `!context.isPreload` check.

---

## BigDecimal Precision

**Maintain precision from original subgraph:**

```typescript
import { BigDecimal } from "generated";

export const ZERO_BI = BigInt(0);
export const ONE_BI = BigInt(1);
export const ZERO_BD = new BigDecimal(0);
export const ONE_BD = new BigDecimal(1);

// WRONG:
const value = Number(amount) / Math.pow(10, decimals);

// CORRECT:
const value = new BigDecimal(amount.toString()).div(
  exponentToBigDecimal(decimals)
);
```

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

## Validation Commands

```bash
# After every change:
pnpm codegen
pnpm tsc --noEmit
TUI_OFF=true pnpm dev
```

**Runtime testing is mandatory** - TypeScript only catches syntax errors, not database/logic issues.

---

## Quality Checklist

- [ ] All `@entity` decorators removed
- [ ] `Bytes!` → `String!` in schema
- [ ] All entity arrays have `@derivedFrom`
- [ ] Entity IDs prefixed with `chainId`
- [ ] All external calls use Effect API
- [ ] BigDecimal precision maintained
- [ ] Field names match generated types (`_id` suffix for relations)
- [ ] `field_selection` added for transaction fields
- [ ] No hardcoded addresses (use constants)
- [ ] async/await on all `context.Entity.get()` calls
- [ ] Runtime tested with `TUI_OFF=true pnpm dev`
