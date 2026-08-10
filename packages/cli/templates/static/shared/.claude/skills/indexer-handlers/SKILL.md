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

// Query by any non-derived field (the index is created on demand)
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

`getWhere` operators: `_eq`, `_gt`, `_lt`, `_gte`, `_lte`, `_in`. Multiple fields and operators combine with AND semantics. Any non-derived field is queryable — the indexer creates the matching index the first time it's queried, which pauses indexing while the index builds. Marking a field `@index` in `schema.graphql` normally avoids that pause: those indexes are created together when the backfill finishes, before the indexer reports ready. A `getWhere` on an `@index` field during backfill still builds it there and then. See `indexer-schema` for @index syntax.

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

**Entity IDs** — with `disable_default_cross_chain: true` a row is identified by `(id, chainId)`, so the id only has to be unique within its chain:
```ts
const id = `${event.block.number}_${event.logIndex}`;
```
Without the flag — or on an entity marked `@crossChain` — the id is the whole key, so prefix it with `${event.chainId}_` to keep chains apart.

**Entity relationships** — schema uses the entity reference (`token0: Token!`); handlers use the `_id` suffix codegen adds (`token0_id: token0.id`), typed as the referenced entity's id. Never write the bare name (`token0`) in the handler, and never put `_id` in the schema.

**Optionals** — `string | undefined`, not `string | null`

**Decimal normalization** — ALWAYS normalize when adding tokens with different decimals.

**Schema & config** — see `indexer-schema` and `indexer-configuration` skills for full reference.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
