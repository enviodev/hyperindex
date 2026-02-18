---
name: indexing-schema
description: >-
  Use when defining or editing schema.graphql. Entity types, scalar types,
  enums, relationships, @derivedFrom, @index, @config directives, array rules,
  naming conventions, and schema-to-TypeScript type mapping.
---

# Schema Reference (schema.graphql)

## Entity Rules

- Every type is an entity — **no `@entity` decorator** (unlike TheGraph)
- Must have `id: ID!` as first field
- Names: 1-63 chars, alphanumeric + underscore, no reserved words
- Use `_id` suffix for relationships: `token_id: String!` not `token: Token!`

## Scalar Types

| Schema Type | TypeScript Type | Notes |
|-------------|----------------|-------|
| `ID!` | `string` | Required on every entity |
| `String!` | `string` | |
| `Int!` | `number` | |
| `Float!` | `number` | |
| `Boolean!` | `boolean` | |
| `BigInt!` | `bigint` | Use `@config(precision: N)` for custom precision |
| `BigDecimal!` | `BigDecimal` | Use `@config(precision: N, scale: M)` |
| `Bytes!` | `string` | Hex-encoded |
| `Timestamp!` | `Date` | |
| `Json!` | `any` | |

## Enums

```graphql
enum Status {
  Active
  Inactive
  Paused
}

type Pool {
  id: ID!
  status: Status!
  allowedStatuses: [Status!]!  # enum arrays supported
}
```

## @derivedFrom

Virtual reverse-lookup — **cannot access in handlers**, only in API queries:

```graphql
type Pool {
  id: ID!
  swaps: [Swap!]! @derivedFrom(field: "pool")
}

type Swap {
  id: ID!
  pool_id: String!  # the FK field
}
```

The `field` argument must reference an `_id` relationship field on the derived entity.

## @index

Single-field index for faster queries:

```graphql
type Transfer {
  id: ID!
  from: String! @index
  to: String! @index
  timestamp: BigInt! @index
}
```

Composite index with optional DESC direction:

```graphql
type Trade @index(fields: ["poolId", ["date", "DESC"]]) {
  id: ID!
  poolId: String!
  date: BigInt!
  volume: BigDecimal!
}
```

- Fields default to ASC; use `["field", "DESC"]` for descending
- IDs and `@derivedFrom` fields are automatically indexed
- Only `@index` fields are queryable via `context.Entity.getWhere()`

## @config

Customize precision for numeric types:

```graphql
type Token {
  id: ID!
  totalSupply: BigInt! @config(precision: 100)
  price: BigDecimal! @config(precision: 30, scale: 15)
}
```

- `BigInt` default precision: 76 digits
- `BigDecimal` default: precision 76, scale 32

## Array Rules

- Supported: `[Type!]!` — non-nullable elements, non-nullable array
- **Not supported**: `[Type]!` (nullable elements), nested arrays, `[Boolean!]!`, `[Timestamp!]!`
- Entity arrays require `@derivedFrom` — bare `[Swap!]!` without it causes `EE211` error

## Example

```graphql
enum PoolType {
  UniswapV2
  UniswapV3
}

type Pool @index(fields: ["token0_id", "token1_id"]) {
  id: ID!
  poolType: PoolType!
  token0_id: String!
  token1_id: String!
  reserve0: BigInt!
  reserve1: BigInt!
  totalValueLocked: BigDecimal! @config(precision: 30, scale: 15)
  swaps: [Swap!]! @derivedFrom(field: "pool")
}

type Swap {
  id: ID!
  pool_id: String! @index
  sender: String! @index
  amount0In: BigInt!
  amount1In: BigInt!
  timestamp: BigInt! @index
}
```

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
