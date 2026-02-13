---
name: indexer-development
description: >-
  Build and modify HyperIndex indexers. Covers schema.graphql (entity types,
  relationships, @derivedFrom, @index), config.yaml (chains, contracts, events,
  field_selection, rpc), and event handlers (context API, entity CRUD, spread
  updates, address types). Use when creating, editing, or debugging indexer
  schema, config, or handler code.
---

# HyperIndex Indexer Development

## ESM Project

This is an ESM project (`"type": "module"` in package.json). Top-level `await` is available. Use `import`/`export` syntax, not `require`.

## Modification Workflow

1. After any change to `schema.graphql` or `config.yaml` → run `pnpm codegen`
2. After any change to TypeScript files → run `pnpm tsc --noEmit`
3. If formatting errors, confirm Prettier is not causing conflicts
4. Once compilation succeeds → run `TUI_OFF=true pnpm dev` to catch runtime errors

## Spread Operator for Updates

Entities returned by `context.Entity.get()` are read-only and immutable. Always use spread:

```ts
let stream = await context.SablierStream.get(event.params.streamId.toString());

if (stream) {
  const updatedStream: SablierStream = {
    ...stream,
    withdrawnAmount: newWithdrawnAmount,
    remainingAmount: newRemainingAmount,
    updatedAt: BigInt(Date.now()),
    progressPercentage: progress,
    status: isCompleted ? "Completed" : stream.status,
    isCompleted,
    timeRemaining: isCompleted ? BigInt(0) : stream.timeRemaining,
  };

  context.SablierStream.set(updatedStream);
}
```

## Schema Rules

- **No `@entity` decorator** — unlike TheGraph, schema types have no decorators
- **No entity arrays** without `@derivedFrom` — `[Mint!]!` causes `EE211` error
- Use `entity_id` fields for relationships: `token_id: String!` not `token: Token!`
- `@derivedFrom` arrays are virtual — cannot access in handlers, only in API queries
- Avoid time-series fields (e.g., `dailyVolume`) — typically inaccurate
- DESC indices supported: `@index(fields: ["poolId", ["date", "DESC"]])`

Example:

```graphql
type Pool {
  id: ID!
  token0_id: String!
  token1_id: String!
  reserve0: BigInt!
  swaps: [Swap!]! @derivedFrom(field: "pool")
}
```

## Config Rules

- Uses `chains` (not `networks`) and `max_reorg_depth` (not `confirmed_block_threshold`)
- Handler field is optional — handlers auto-register from `src/handlers/`
- Global contracts are auto-configured per chain (no need to repeat contract definition in each chain)
- RPC config uses `rpc` with `for: sync | live | fallback`; WebSocket via `ws:` field
- `full_batch_size` controls batch size
- Validate with: `# yaml-language-server: $schema=./node_modules/envio/evm.schema.json`
- **Deprecated options** (do NOT use): `loaders`, `preload_handlers`, `preRegisterDynamicContracts`, `event_decoder`, `rpc_config`, `unordered_multichain_mode`

### field_selection

If using `event.transaction.hash` or other transaction-level data, define it explicitly:

```yaml
- name: SablierLockup
  address:
    - 0x467D5Bf8Cfa1a5f99328fBdCb9C751c78934b725
  events:
    - event: CreateLockupLinearStream(...)
      field_selection:
        transaction_fields:
          - hash
```

## Handler Rules

- `context.chain.id` and `context.chain.isLive` are available in handlers
- Use `indexer` from `generated` (replaces `getGeneratedByChainId`)
- Address type is `` `0x${string}` ``, not plain `string`
- Use `transaction.type` (not `transaction.kind`)
- Entity array fields are `readonly` — spread into a new array to modify
- Only capitalized entity types are exported from `generated` (e.g., `Token`, not `token`)
- Conditional `eventFilters` can return a boolean to enable/disable filtering

## Common Pitfalls

### Entity Relationships

```ts
// WRONG:
const pair = { token0: token0.id };

// CORRECT — use _id suffix:
const pair = { token0_id: token0.id };
```

### Timestamp Handling

Always cast timestamps to BigInt: `BigInt(event.block.timestamp)`

### Address Case

Use lowercase keys in config objects to match `address.toLowerCase()` lookups:
`"0x6b175474e89094c44da98b954eedeac495271d0f"` not `"0x6B175474E89094C44Da98b954EedeAC495271d0F"`

### Type Safety

- `string | undefined` for optional strings, not `string | null`
- Generated types are strict about null vs undefined

### Decimal Normalization

**ALWAYS normalize amounts** when adding tokens with different decimals. USDC (6 decimals) + DAI (18 decimals) requires normalization before addition.

### Schema Type Mapping

| Schema | TypeScript |
|--------|------------|
| `Int!` | `number` |
| `BigInt!` | `bigint` / `ZERO_BI` |
| `BigDecimal!` | `BigDecimal` / `ZERO_BD` |
| `String!` / `Bytes!` | `string` |
| `Entity!` | `entity_id: string` |

## Deep Documentation

Full LLM-optimized reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete

Example repos:
- [Uniswap v4 Indexer](https://github.com/enviodev/uniswap-v4-indexer)
- [Safe Analysis Indexer](https://github.com/enviodev/safe-analysis-indexer)
