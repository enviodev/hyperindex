# Quality Checks

Common issues, fixes, and validation patterns for subgraph-to-HyperIndex migrations.

## Validation Commands

Run after EVERY code change:

```bash
pnpm codegen           # Regenerate types from schema + config
pnpm tsc --noEmit      # Type-check
pnpm test              # Run tests
```

---

## Common Quality Issues

### Issue 1: Entity Type Import Confusion

**Problem:** Importing entity types from wrong location when there's a name collision with contract handlers.
**Symptom:** "Pair refers to a value, but is being used as a type"

```typescript
// WRONG — Pair is a contract handler, not a type
import { Pair, Token } from "generated";
const p: Pair = { ... };

// CORRECT — use Entities type map (only needed if name collides with a contract)
import type { Entities } from "generated";
const p: Entities["Pair"] = { ... };
```

If there's no collision (entity name differs from contract name), you can import the type directly from `"generated"`.

### Issue 2: BigDecimal vs bigint Type Mismatches

**Problem:** Wrong types for entity fields.
**Symptom:** "Type 'BigNumber' is not assignable to type 'bigint'"

```typescript
// WRONG — Token entity expects bigint for totalSupply
export function fetchTokenTotalSupply(tokenAddress: string): BigDecimal {
  return ZERO_BD;
}

// CORRECT — match entity field type
export function fetchTokenTotalSupply(tokenAddress: string): bigint {
  return ZERO_BI;
}
```

### Issue 3: Entity Field Name Mismatches

**Problem:** Wrong field names that don't match generated types.
**Symptom:** "Property 'token0' does not exist on type 'Entities["Pair"]'"

```typescript
// WRONG
const pair: Entities["Pair"] = {
  token0: token0.id,    // Should be token0_id
  token1: token1.id,    // Should be token1_id
};

// CORRECT — use _id suffix for relationships
const pair: Entities["Pair"] = {
  token0_id: token0.id,
  token1_id: token1.id,
};
```

### Issue 4: Missing BigDecimal Import

**Problem:** Importing from wrong package.
**Symptom:** "Cannot find name 'BigDecimal'"

```typescript
// WRONG
import { BigDecimal } from "bignumber.js";

// CORRECT — import from generated
import { BigDecimal } from "generated";
```

### Issue 5: Hardcoded Values Instead of Constants

**Problem:** Hardcoded addresses instead of constants from original subgraph.

```typescript
// WRONG — hardcoded
const factory = await context.UniswapFactory.get("0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f");

// CORRECT — use constant
const factory = await context.UniswapFactory.get(FACTORY_ADDRESS);
```

**Checklist:** Look for hardcoded addresses, check what constants the subgraph uses, import and use them.

---

## Async/Await Validation

```typescript
// WRONG — missing await, returns {} instead of entity
export function updateTokenDayData() {
  const bundle = context.Bundle.get(`${chainId}-1`);
}

// CORRECT — proper async/await
export async function updateTokenDayData() {
  const bundle = await context.Bundle.get(`${chainId}-1`);
}
```

**Note:** `context.Entity.set()` does NOT need `await` — it's synchronous.

---

## Entity Type Mismatch and Database Schema

Always verify code types match schema types exactly:

| Schema | TypeScript |
|--------|------------|
| `Int!` | `number` |
| `BigInt!` | `bigint` / `ZERO_BI` |
| `BigDecimal!` | `BigDecimal` / `ZERO_BD` |
| `String!` / `Bytes!` | `string` |
| `Boolean!` | `boolean` |
| `EntityType!` | `entity_type_id: string` |

**Example mismatch:**
```typescript
// WRONG — schema expects Int!, code sets BigInt
// Schema: date: Int!
// Code: date: BigInt(dayStartTimestamp)

// CORRECT — schema expects Int!, code sets number
// Schema: date: Int!
// Code: date: dayStartTimestamp  // already a number
```

---

## Field Selection for Transaction Data

When you need `event.transaction.hash` or other transaction fields, you MUST add `field_selection`:

```yaml
# WRONG — transaction.hash will be undefined
- event: Transfer(address indexed from, address indexed to, uint256 value)

# CORRECT — transaction.hash available
- event: Transfer(address indexed from, address indexed to, uint256 value)
  field_selection:
    transaction_fields:
      - hash
```

**Common events that need transaction hash:**
- Transfer, Mint, Burn, Swap events
- Any event creating or updating Transaction entities

---

## @derivedFrom Array Access

`@derivedFrom` arrays are virtual — don't access in handlers:

```typescript
// WRONG — virtual arrays don't exist in types
const mints = transaction.mints;

// CORRECT — query via indexed fields
const mints = await context.Mint.getWhere({ transaction_id: { _eq: transactionId } });
```

---

## 12 Common Fixes to Apply Automatically

1. **Fix entity type imports** — Use `Entities["Name"]` from `"generated"` for entity types
2. **Fix type mismatches** — Match entity field types exactly (BigDecimal vs bigint)
3. **Fix field names** — Use exact field names from generated types (`_id` suffix)
4. **Fix BigDecimal imports** — Import from `"generated"` not `"bignumber.js"`
5. **Fix entity type annotations** — Use `Entities["Pair"]` when name collides with contract handler
6. **Fix transaction field access** — Add `field_selection` in config.yaml
7. **Fix hardcoded values** — Use constants from original subgraph
8. **Fix missing field selection** — Add for ALL events needing transaction data
9. **Fix missing @derivedFrom** — ALL entity arrays need `@derivedFrom(field: "fieldName")`
10. **Fix @derivedFrom array access** — Use `getWhere` instead of direct access
11. **Check helper function dependencies** — Implement all functions without entity dependencies
12. **Check entity type mismatches** — Verify code types match schema property types exactly

**Complete fix example:**

```typescript
// BEFORE — multiple issues
import { Pair, Token } from "generated";
import { BigDecimal } from "bignumber.js";

const pair: Pair = {
  token0: token0.id,         // Wrong field name
  totalSupply: ZERO_BD,      // Wrong type (should be bigint)
};

// AFTER — all issues fixed
import type { Entities } from "generated";
import { BigDecimal } from "generated";

const pair: Entities["Pair"] = {
  token0_id: token0.id,      // Correct field name
  totalSupply: ZERO_BI,      // Correct type (bigint)
};
```

---

## Errors to Ignore During Migration

Some errors are expected during early steps:

```typescript
// IGNORE — will be fixed when handler is implemented
// Error: Cannot find name 'handleMint'
Pair.Mint.handler(handleMint);

// IGNORE — will be fixed when entity is created
// Error: Cannot find name 'MintEvent'
const mintEvent: MintEvent = { ... };
```

**Only fix errors that prevent:**
1. Codegen from working
2. TypeScript compilation
3. Basic file structure
