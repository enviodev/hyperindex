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
- Relationship fields use the **entity type directly**: `collection: NftCollection!` — **never** add `_id` in the schema field name
- The `_id` suffix only appears in TypeScript handlers (added by codegen): schema field `collection` → handler field `collection_id`

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
  pool: Pool!  # entity reference — field name matches @derivedFrom "field" arg
}
```

**Critical rules:**
- The `field` argument must match the **schema field name** on the child entity — which is the entity reference name (`"pool"`), **not** `"pool_id"`
- In TypeScript handlers, set this relationship using the `_id` suffix: `pool_id: poolEntity.id` — codegen transforms `pool: Pool!` → `pool_id` in the TypeScript type
- **Never write `pool_id: String!` in the schema when using `@derivedFrom(field: "pool")`.** The schema field must be `pool: Pool!`; the `_id` is a codegen artifact for handlers only

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
- Entity arrays require `@derivedFrom` — bare `[Swap!]!` without it causes a codegen error

## Example

```graphql
enum PoolType {
  UniswapV2
  UniswapV3
}

type Token {
  id: ID!
  symbol: String!
}

type Pool @index(fields: ["token0", "token1"]) {
  id: ID!
  poolType: PoolType!
  token0: Token!   # entity reference — handler uses token0_id
  token1: Token!   # entity reference — handler uses token1_id
  reserve0: BigInt!
  reserve1: BigInt!
  totalValueLocked: BigDecimal! @config(precision: 30, scale: 15)
  swaps: [Swap!]! @derivedFrom(field: "pool")  # "pool" matches Swap.pool field name
}

type Swap {
  id: ID!
  pool: Pool! @index   # entity reference — handler uses pool_id; @derivedFrom field arg = "pool"
  sender: String! @index
  amount0In: BigInt!
  amount1In: BigInt!
  timestamp: BigInt! @index
}
```

**Schema vs handler field names:**

| Schema field | Schema type | TypeScript handler field |
|---|---|---|
| `pool` | `Pool!` | `pool_id: string` |
| `token0` | `Token!` | `token0_id: string` |
| `collection` | `NftCollection!` | `collection_id: string` |

Codegen always appends `_id` to entity reference field names in the TypeScript types. Do **not** add `_id` yourself in the schema.

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
