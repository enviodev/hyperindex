---
name: indexer-handlers
description: >-
  Use when writing or editing event handlers. Handler registration, context API
  (entity CRUD, getWhere queries, chain, log), spread updates, indexer runtime
  API, and common pitfalls.
metadata:
  managed-by: envio
---

# Handler Syntax & Core API

## ESM Project

This is an ESM project (`"type": "module"` in package.json). Top-level `await` is available. Use `import`/`export` syntax, not `require`.

## Modification Workflow

1. After any change to `schema.graphql` or `config.yaml` → run `pnpm codegen`
2. After any change to TypeScript files → run `pnpm tsc --noEmit`
3. Once compilation succeeds → run `pnpm dev` to catch runtime errors

## Handler Registration

```ts
import { indexer } from "envio";

indexer.onEvent(
  { contract: "MyContract", event: "Transfer" },
  async ({ event, context }) => {
    // event.params.<name>  — decoded event parameters
    // event.chainId        — chain ID
    // event.srcAddress     — emitting contract address (checksummed)
    // event.logIndex       — log index within block
    // event.block          — { number, timestamp, hash }
    // event.transaction    — transaction fields (configure via field_selection)
  },
);
```

The first argument is the options object — `contract` and `event` names plus
optional `wildcard` / `where` (see `indexer-wildcard` and `indexer-filters`
skills). The second argument is the handler.

## Context API

### Entity Operations

```ts
// Read
const entity = await context.Entity.get(id);              // Entity | undefined
const entity = await context.Entity.getOrThrow(id);       // throws if missing
const entity = await context.Entity.getOrCreate({ id, ...defaults });

// Query by indexed fields (@index in schema)
const list = await context.Entity.getWhere({ fieldName: { _eq: value } });
const list = await context.Entity.getWhere({ fieldName: { _gt: value } });
const list = await context.Entity.getWhere({ fieldName: { _lt: value } });
const list = await context.Entity.getWhere({ fieldName: { _gte: value } });
const list = await context.Entity.getWhere({ fieldName: { _lte: value } });
const list = await context.Entity.getWhere({ fieldName: { _in: [value1, value2] } });
const list = await context.Entity.getWhere({ fieldName: { _gte: min, _lte: max } });
const list = await context.Entity.getWhere({ fieldA: { _eq: a }, fieldB: { _eq: b } });

// Write
context.Entity.set(entity);          // create or update (sync — no await)
context.Entity.deleteUnsafe(id);     // delete (sync — no await)
```

`getWhere` operators: `_eq`, `_gt`, `_lt`, `_gte`, `_lte`, `_in`. Multiple fields and operators combine with AND semantics. Only `id` and `@index` fields are queryable. See `indexer-schema` for @index syntax.

### Context Properties

```ts
context.chain.id           // number — current chain ID
context.chain.isRealtime   // boolean — true when ALL chains have caught up to head
context.isPreload      // boolean — true during preload phase
context.log            // { debug, info, warn, error }
context.effect(fn, input)  // external call via Effect API (see indexer-external-calls)
```

## Spread Operator for Updates

Entities from `context.Entity.get()` are **read-only**. Always spread:

```ts
const entity = await context.Entity.get(id);
if (entity) {
  context.Entity.set({ ...entity, field: newValue });
}
```

## `indexer` Runtime API

```ts
import { indexer } from "envio";

indexer.name;                        // "my-indexer"
indexer.chainIds;                    // [1, 137]
indexer.chains[1].id;                // 1
indexer.chains[1].name;              // "ethereum"
indexer.chains[1].startBlock;        // 0
indexer.chains[1].isRealtime;        // false
indexer.chains[1].MyContract.name;   // "MyContract"
indexer.chains[1].MyContract.addresses; // ["0x..."]
indexer.chains[1].MyContract.abi;    // [...]
```

## Common Pitfalls

**Entity IDs** — default to a string `${chainId}_${blockNumber}_${logIndex}`, globally unique across chains and blocks, unless the entity is a singleton keyed by address:
```ts
const id = `${event.chainId}_${event.block.number}_${event.logIndex}`;
```
Ids may also be `Int!`/`BigInt!` (see `indexer-schema`); `get`/`getOrThrow`/`deleteUnsafe` then take that type (`number`/`bigint`) instead of `string`.

**Entity relationships** — schema uses the entity reference (`token0: Token!`); handlers use the `_id` suffix codegen adds (`token0_id: token0.id`), typed as the referenced entity's id. Never write the bare name (`token0`) in the handler, and never put `_id` in the schema.

**Optionals** — `string | undefined`, not `string | null`

**Decimal normalization** — ALWAYS normalize when adding tokens with different decimals.

**Schema & config** — see `indexer-schema` and `indexer-configuration` skills for full reference.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
