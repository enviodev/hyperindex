---
name: indexing-handler-syntax
description: >-
  Use when writing or editing event handlers. Handler registration, context API
  (entity CRUD, getWhere queries, chain, log), spread updates, indexer runtime
  API, and common pitfalls.
---

# Handler Syntax & Core API

## ESM Project

This is an ESM project (`"type": "module"` in package.json). Top-level `await` is available. Use `import`/`export` syntax, not `require`.

## Modification Workflow

1. After any change to `schema.graphql` or `config.yaml` → run `pnpm codegen`
2. After any change to TypeScript files → run `pnpm tsc --noEmit`
3. Once compilation succeeds → run `TUI_OFF=true pnpm dev` to catch runtime errors

## Handler Registration

```ts
import { Contract } from "generated";

Contract.Event.handler(async ({ event, context }) => {
  // event.params.<name>  — decoded event parameters
  // event.chainId        — chain ID
  // event.srcAddress     — emitting contract address (checksummed)
  // event.logIndex       — log index within block
  // event.block          — { number, timestamp, hash }
  // event.transaction    — transaction fields (configure via field_selection)
});
```

Handlers accept an optional 2nd argument — see `indexing-wildcard` and `indexing-filters` skills.

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

// Write
context.Entity.set(entity);          // create or update (sync — no await)
context.Entity.deleteUnsafe(id);     // delete (sync — no await)
```

`getWhere` operators: `_eq`, `_gt`, `_lt`, `_gte`, `_lte`. Only `@index` fields are queryable. See `indexing-schema` for @index syntax.

### Context Properties

```ts
context.chain.id       // number — current chain ID
context.chain.isLive   // boolean — true when processing live blocks
context.isPreload      // boolean — true during preload phase
context.log            // { debug, info, warn, error, errorWithExn }
context.effect(fn, input)  // external call via Effect API (see indexing-external-calls)
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
import { indexer } from "generated";

indexer.name;                        // "my-indexer"
indexer.chainIds;                    // [1, 137]
indexer.chains[1].id;                // 1
indexer.chains[1].name;              // "ethereum"
indexer.chains[1].startBlock;        // 0
indexer.chains[1].isLive;            // false
indexer.chains[1].MyContract.name;   // "MyContract"
indexer.chains[1].MyContract.addresses; // ["0x..."]
indexer.chains[1].MyContract.abi;    // [...]
```

## Common Pitfalls

**Entity IDs** — prefer `${chainId}_${blockNumber}_${logIndex}` as a unique ID:
```ts
const id = `${event.chainId}_${event.block.number}_${event.logIndex}`;
```
This is globally unique across chains and blocks. Use it as the default unless the entity is a singleton (e.g., a Token or Pool keyed by address).

**Entity relationships** — use `_id` suffix:
```ts
// WRONG:  { token0: token0.id }
// CORRECT: { token0_id: token0.id }
```

**Optionals** — `string | undefined`, not `string | null`

**Decimal normalization** — ALWAYS normalize when adding tokens with different decimals.

**Schema & config** — see `indexing-schema` and `indexing-config` skills for full reference.

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
