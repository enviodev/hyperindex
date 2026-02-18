# Step-by-Step Migration Guide

Detailed procedural guide for each migration step. The SKILL.md provides the overview; this file provides the full breakdown.

## Runtime Testing Mandate

**After EVERY code change, run:**

```bash
pnpm test
```

Use the TDD flow: write a failing test, implement, verify the test passes.

If tests aren't sufficient to catch a runtime issue, also run:

```bash
TUI_OFF=true pnpm dev
```

**Why this is critical:**
- TypeScript compilation (`tsc --noEmit`) only catches syntax and type errors
- Runtime errors (database issues, missing entities, logic errors) only appear when running the indexer
- Testing after each change makes debugging much easier — you know exactly which change caused the issue

**Runtime Testing Checklist:**
- [ ] After every code change, run `pnpm test`
- [ ] If needed, run `TUI_OFF=true pnpm dev` for ~30 seconds
- [ ] Watch the output for any error messages or warnings
- [ ] Stop the background process after confirming it runs without errors
- [ ] Only proceed to the next step after confirming tests pass

**Common Runtime Errors to Watch For:**
- Database connection issues
- Missing entity lookups returning `{}` instead of `undefined`
- Logic errors in calculations
- Missing async/await causing empty object returns
- Entity relationship issues
- Configuration problems

---

## Step 1: Clear Boilerplate Code

When working with EventHandlers.ts, clear all boilerplate logic and start fresh:

```typescript
// CLEAR THIS BOILERPLATE CODE:
Contract.EventName.handler(async ({ event, context }) => {
  const entity: EventEntity = {
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    field1: event.params.field1,
    // ... other fields
  };
  context.EventEntity.set(entity);
});

// REPLACE WITH EMPTY HANDLERS:
Contract.EventName.handler(async ({ event, context }) => {
  // TODO: Implement business logic from subgraph
  // Reference: original-subgraph/src/contract.ts
});
```

**Quality Check:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 2: Migrate Schema (Detailed)

Convert TheGraph schema to Envio format:

```graphql
# TheGraph:
type EventEntity @entity(immutable: true) {
  id: Bytes!
  field1: Bytes!
  field2: BigInt!
  blockNumber: BigInt!
  blockTimestamp: BigInt!
  transactionHash: Bytes!
}

# Envio:
type EventEntity {
  id: ID!
  field1: String!
  field2: BigInt!
  blockNumber: BigInt!
  blockTimestamp: BigInt!
  transactionHash: String!
}
```

**Key changes:**
- Remove `@entity` decorators
- `Bytes!` → `String!`
- Keep `ID!`, `BigInt!`, `BigDecimal!`

### Entity Arrays MUST Have @derivedFrom

Entity arrays like `[Mint!]!` are ONLY valid with `@derivedFrom`. Arrays without it cause codegen to fail with "EE211: Arrays of entities is unsupported".

```graphql
# WRONG — causes codegen failure
type Transaction {
  mints: [Mint!]!
  burns: [Burn!]!
  swaps: [Swap!]!
}

# CORRECT — all arrays have @derivedFrom
type Transaction {
  mints: [Mint!]! @derivedFrom(field: "transaction")
  burns: [Burn!]! @derivedFrom(field: "transaction")
  swaps: [Swap!]! @derivedFrom(field: "transaction")
}
```

**How @derivedFrom works in Envio:**
- `@derivedFrom` arrays are VIRTUAL fields — they don't exist in generated types
- They're populated automatically when querying the API, not in handlers
- You CANNOT access them in handlers (e.g., `transaction.mints` will not work)
- Use `_id` fields to establish relationships, and `getWhere` to query related entities

### Schema Verification Checklist

After migrating, verify the schema is IDENTICAL to the original (apart from syntax):

1. Run `pnpm codegen` to ensure schema compiles
2. Compare line-by-line with original subgraph schema
3. Verify no business logic entities or fields are missing
4. Confirm all relationships and derived fields are preserved
5. Ensure ALL entity arrays have `@derivedFrom` directives

**Only acceptable differences:** `@entity` removed, `Bytes!` → `String!`

**Quality Check:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 3: Refactor File Structure

Mirror subgraph file structure using EXACT same filenames:

```
src/
├── utils/
│   ├── pricing.ts        (exact filename from subgraph)
│   ├── helpers.ts         (exact filename from subgraph)
├── handlers/
│   ├── factory.ts         (exact filename from subgraph)
│   └── pair.ts            (exact filename from subgraph)
test/
├── factory.test.ts
└── pair.test.ts
```

### Config.yaml Structure

```yaml
# Global contract definitions (handler + events)
contracts:
  - name: Factory
    events:
      - event: PairCreated(...)
  - name: Pair
    events:
      - event: Swap(...)

# Chain-specific addresses only
chains:
  - id: 1
    contracts:
      - name: Factory
        address:
          - 0xFactoryAddress
```

**Do NOT duplicate contract definitions in chain sections.** Global contracts define handlers and events; chain sections only define addresses.

**Quality Check:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 4: Register Dynamic Contracts

Identify dynamic contracts in the original subgraph.yaml — look for contracts with NO address (templates section):

```yaml
# subgraph.yaml — factory has address, template does not
- kind: ethereum/contract
  name: Factory
  source:
    address: '0x...'

templates:
  - kind: ethereum/contract
    name: Pair      # No address — created dynamically
    source:
      abi: Pair
```

Implement `contractRegister` BEFORE the handler:

```typescript
Factory.PairCreated.contractRegister(({ event, context }) => {
  context.addPair(event.params.pair);
});

Factory.PairCreated.handler(async ({ event, context }) => {
  // Handler logic...
});
```

Remove `address` from dynamic contracts in `config.yaml`.

**Write test first:**

```typescript
it("Should register dynamic Pair contracts", async () => {
  const indexer = createTestIndexer();
  const result = await indexer.process({
    chains: { 1: { startBlock: 10_000_835, endBlock: 10_000_835 } },
  });
  expect(result.changes[0].Pair?.sets).toHaveLength(1);
});
```

**Common patterns:**
```typescript
// Pair contracts
Factory.PairCreated.contractRegister(({ event, context }) => {
  context.addPair(event.params.pair);
});

// Pool contracts
PoolFactory.PoolCreated.contractRegister(({ event, context }) => {
  context.addPool(event.params.pool);
});

// Vault contracts
VaultFactory.VaultCreated.contractRegister(({ event, context }) => {
  context.addVault(event.params.vault);
});
```

**Important:**
- MUST be placed ABOVE the handler for the same event
- MUST use the exact contract name from config.yaml (e.g., `addPair` for `Pair`)
- MUST reference the correct event parameter containing the new contract address

**Quality Check:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 5a: Implement Helper Functions with No Dependencies

**Implement helper functions that have NO dependencies on incomplete entities/handlers.**

A function has "no dependencies" if it:
- Has no `context.Entity.get()` calls
- Doesn't call other unimplemented helper functions
- Only uses constants, basic math, or static data

**You MUST implement the COMPLETE logic, not just placeholders.**

```typescript
// WRONG — just a placeholder
export function fetchTokenSymbol(tokenAddress: string): string {
  // TODO: Implement
  return "UNKNOWN";
}

// CORRECT — complete implementation
export function isNullEthValue(value: string): boolean {
  return value === '0x0000000000000000000000000000000000000000000000000000000000000001' ||
         value === '0x0000000000000000000000000000000000000000000000000000000000000000';
}

export function convertEthToDecimal(eth: bigint): BigDecimal {
  return new BigDecimal(eth.toString()).div(
    new BigDecimal('1000000000000000000')
  );
}
```

**Check function dependencies thoroughly:** When implementing a helper, examine ALL function calls within it. If a called function has no entity dependencies, implement it too.

**External calls MUST use Effect API** — see [migration-patterns.md](migration-patterns.md) for Effect API patterns.

**Quality Check:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 5b: Implement Simple Handlers

Handlers that only set parameter values with minimal processing:
- Direct parameter mapping to entity fields
- Loading existing entities and updating with new data
- Basic event handlers with no complex business logic

**Write a failing test first, then implement until it passes.**

**Quality Check:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 5c: Implement Moderate Complexity Handlers

Handlers that call helper functions but don't create complex entity relationships:
- Handlers that call helper functions
- Handlers that update multiple entities with straightforward logic

**As you implement each handler, implement any helper functions it calls:**
1. Identify helper functions called by the current handler
2. Check if they have dependencies on incomplete entities/handlers
3. If NO dependencies, implement them immediately
4. If they have dependencies, implement their dependencies first
5. Continue recursively until all required helpers are complete

**Quality Check:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 5d: Implement Complex Handlers (One at a Time)

Handlers with complex business logic, multiple entity relationships, contract binding (RPC calls), or dependencies on multiple other handlers.

**Implementation strategy:**
1. Implement ONE complex handler at a time
2. Identify all helper functions it calls
3. Implement any missing helper functions
4. Run tests after EACH helper function
5. Run tests after the handler
6. Move to next handler ONLY after current one passes

**Why this order matters:**
- Prevents "entity not found" errors during development
- Ensures required entities exist before complex handlers use them
- Allows incremental testing and validation
- Reduces circular dependency issues

**Quality Check after each helper AND each handler:**
```bash
pnpm codegen && pnpm tsc --noEmit && pnpm test
```

---

## Step 6: Final Migration Verification

### 6.1: Systematic Handler Logic Review

Go through EACH handler, one by one:
1. Compare logic to subgraph implementation
2. Identify missing or unnecessary logic
3. Update handler
4. Re-check — you'll likely find something else
5. Repeat until logic matches
6. Do this slowly for every handler

**Why iterative:** First pass often misses subtle differences. Multiple iterations ensure accuracy.

### 6.2: Systematic Helper Function Review

Same process for every helper function:
1. Compare to subgraph implementation
2. Identify gaps
3. Fix and re-check
4. Repeat until correct

### 6.3: Verification Checklist

After each handler/function review:
- [ ] Logic matches subgraph exactly — no missing or extra logic
- [ ] All edge cases handled — same conditional branches
- [ ] Entity operations correct — proper loading, updating, saving
- [ ] Helper function calls complete — all required functions called
- [ ] Error handling matches — same validation logic
- [ ] Calculations identical — same mathematical operations and precision

### 6.4: Full Range Verification

```typescript
it("Should match subgraph for full block range", async () => {
  const indexer = createTestIndexer();
  const result = await indexer.process({
    chains: { 1: { startBlock: 10_000_000, endBlock: 10_100_000 } },
  });
  // Compare key metrics: entity counts, specific values, aggregates
});
```

---

## Step 7: Environment Variables Setup

Search the codebase for all environment variables and update the example env file:

```bash
# Find all env variables
grep -r "process.env\." src/
grep -r "process.env\[" src/
```

Update `.env.example` with all found variables, descriptive comments, and example values (not real secrets).
