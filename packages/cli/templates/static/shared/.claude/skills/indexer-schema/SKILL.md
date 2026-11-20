---
name: indexer-schema
description: >-
  Use when defining or editing schema.graphql. Entity types, scalar types,
  enums, relationships, @derivedFrom, @index, @config directives, array rules,
  naming conventions, and schema-to-TypeScript type mapping.
metadata:
  managed-by: envio
---

# Schema Reference (schema.graphql)

## Entity Rules

- Every type is an entity — **no `@entity` decorator** (unlike TheGraph)
- Must have an `id` field first — `ID!` (recommended), or `String!`, `Int!`, `BigInt!`
- Names: 1-63 chars, alphanumeric + underscore, no reserved words
- Relationship fields use the **entity type directly**: `collection: NftCollection!` — **never** add `_id` in the schema field name
- The `_id` suffix only appears in TypeScript handlers (added by codegen): schema field `collection` → handler field `collection_id`, typed as the referenced entity's id

## Scalar Types

| Schema Type | TypeScript Type | Notes |
|-------------|----------------|-------|
| `ID!` | `string` | Recommended entity id; `String!`/`Int!`/`BigInt!` also allowed as id |
| `String!` | `string` | |
| `Int!` | `number` | |
| `Float!` | `number` | |
| `Boolean!` | `boolean` | |
| `BigInt!` | `bigint` | Use `@config(precision: N)` for custom precision |
| `BigDecimal!` | `BigDecimal` | Use `@config(precision: N, scale: M)` |
| `Bytes!` | `Hex` or `Uint8Array` | Depends on `bytes_type` in config.yaml: `hex` (the EVM/Fuel default) gives a hex-encoded `Hex` (a `string`, or `` `0x${string}` `` with `strict_hex_type: true`), `uint8array` gives a `Uint8Array` stored as raw bytes. SVM is always `Uint8Array` |
| `Timestamp!` | `Date` | |
| `Json!` | `JSON` | JSON values only — store a `bigint` as its `.toString()` |

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

Covering index — `include` stores extra columns in the index without keying on them, so a query that reads only the key and included columns is answered from the index alone (a Postgres index-only scan):

```graphql
type Trade @index(fields: ["poolId", ["date", "DESC"]], include: ["volume"]) {
  id: ID!
  poolId: String!
  date: BigInt!
  volume: BigDecimal!
}
```

- Fields default to ASC; use `["field", "DESC"]` for descending
- `include` takes plain field names (no direction), works with one or more key `fields`, and is Postgres-only. Keep included columns small: they are copied into the index, and an index entry is limited to about 2.7 kB
- IDs and `@derivedFrom` fields are automatically indexed
- Any non-derived field is queryable via `context.Entity.getWhere()`. Indexes are never created up front: `@index` fields are built together when the backfill finishes, before the indexer reports ready, and any field — marked or not — is indexed on the spot if a `getWhere` needs it earlier, pausing indexing while it builds

## @config

Bound the digits of a numeric field:

```graphql
type Token {
  id: ID!
  totalSupply: BigInt!                                 # a raw uint256: leave it unbounded
  feeBps: BigInt! @config(precision: 5)
  price: BigDecimal! @config(precision: 30, scale: 15)
}
```

- Without `@config`, `BigInt` and `BigDecimal` are unbounded (`NUMERIC` in Postgres): every uint256 and int256 fits. Leave raw token amounts unbounded unless you know their range
- With `@config`, Postgres rounds a value to `scale` fractional digits and refuses one whose whole part has more than `precision − scale` digits
- In ClickHouse, a precision of 1–76 with a scale no greater than the precision stores a numeric `Decimal(P, S)` column, which sorts and aggregates as a number. Any other field, unbounded included, stores a `String` column: cast it in SQL (`toUInt256(amount)`, `toInt256(amount)`, `toDecimal256(price, 18)`), list it in no `clickhouse.orderBy`, and give a ClickHouse entity whose `BigInt` id is unbounded an `orderBy` of other fields
- 76 digits doesn't hold every uint256: its maximum, 2^256 − 1, has 78 digits

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

**Schema vs handler field names** (entity refs to `ID!`-keyed entities):

| Schema field | Schema type | TypeScript handler field |
|---|---|---|
| `pool` | `Pool!` | `pool_id: string` |
| `token0` | `Token!` | `token0_id: string` |
| `collection` | `NftCollection!` | `collection_id: string` |

Codegen appends `_id` to entity reference fields (never add it in the schema), typed as the referenced entity's id.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
