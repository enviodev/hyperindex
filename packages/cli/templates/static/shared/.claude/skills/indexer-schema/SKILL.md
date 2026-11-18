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

| Schema Type   | TypeScript Type       | Notes                                                                                                                                                                                                                                               |
| ------------- | --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ID!`         | `string`              | Recommended entity id; `String!`/`Int!`/`BigInt!` also allowed as id                                                                                                                                                                                |
| `String!`     | `string`              |                                                                                                                                                                                                                                                     |
| `Int!`        | `number`              |                                                                                                                                                                                                                                                     |
| `Float!`      | `number`              |                                                                                                                                                                                                                                                     |
| `Boolean!`    | `boolean`             |                                                                                                                                                                                                                                                     |
| `BigInt!`     | `bigint`              | Use `@config(precision: N)` for custom precision                                                                                                                                                                                                    |
| `BigDecimal!` | `BigDecimal`          | Use `@config(precision: N, scale: M)`                                                                                                                                                                                                               |
| `Bytes!`      | `Hex` or `Uint8Array` | Depends on `bytes_type` in config.yaml: `hex` (the EVM/Fuel default) gives a hex-encoded `Hex` (a `string`, or `` `0x${string}` `` with `strict_hex_type: true`), `uint8array` gives a `Uint8Array` stored as raw bytes. SVM is always `Uint8Array` |
| `Timestamp!`  | `Date`                |                                                                                                                                                                                                                                                     |
| `Json!`       | `JSON`                | JSON values only — store a `bigint` as its `.toString()`                                                                                                                                                                                            |

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
  allowedStatuses: [Status!]! # enum arrays supported
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
  pool: Pool! # entity reference — field name matches @derivedFrom "field" arg
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
- Any non-derived field is queryable via `context.Entity.getWhere()`. Indexes are never created up front: `@index` fields are built together when the backfill finishes, before the indexer reports ready, and any field — marked or not — is indexed on the spot if a `getWhere` needs it earlier, pausing indexing while it builds

## @config

Customize precision for numeric types:

```graphql
type Token {
  id: ID!
  totalSupply: BigInt! @config(precision: 100)
  price: BigDecimal! @config(precision: 30, scale: 15)
}
```

Without `@config`, scalar `BigInt` and `BigDecimal` fields use unconstrained PostgreSQL
`NUMERIC` (subject to PostgreSQL's numeric limits). They do not default to a
76-digit precision or a scale of 32. For `BigInt`, use `@config(precision: N)`.
For `BigDecimal`, both arguments are required: `@config(precision: N, scale: M)`.
Precision constrains the total number of decimal digits, including digits to
the left of the decimal point; a complete `uint256` range needs 78 digits, so
precision 76 is not enough.

Unconfigured numeric lists use PostgreSQL `TEXT[]` when Hasura is enabled,
because Hasura cannot read `NUMERIC[]`. With Hasura disabled, those lists use
`NUMERIC[]`. This workaround does not apply to scalar fields or explicitly
configured numeric lists, which retain their numeric types.

### ClickHouse numeric storage

ClickHouse uses a different mapping. The current RowBinary encoder supports
Decimal widths up to 128 bits, so a numeric Decimal column requires configured
precision between 1 and 38 and scale no greater than precision. Unconfigured
fields, wider fields, and configurations with scale above precision are stored
as decimal text in `String` columns:

| Schema field                                               | ClickHouse column |
| ---------------------------------------------------------- | ----------------- |
| `BigInt!`                                                  | `String`          |
| `BigInt! @config(precision: 38)`                           | `Decimal(38, 0)`  |
| `BigInt! @config(precision: 39)` (or any higher precision) | `String`          |
| `BigDecimal!`                                              | `String`          |
| `BigDecimal! @config(precision: 30, scale: 15)`            | `Decimal(30, 15)` |
| `BigDecimal! @config(precision: 10, scale: 12)`            | `String`          |

Nullable numeric scalar fields wrap the column type in `Nullable(...)`.
Non-null numeric lists apply the mapping to their elements. Nullable lists
(such as `[BigInt!]`) are rejected for ClickHouse storage; they do not become
`Nullable(Array(...))`. Do not assume a wide numeric field is stored in
ClickHouse's native `Decimal256` type.

String columns compare and sort lexicographically, not numerically (`"10"` sorts
before `"2"`). Such fields cannot be used as numeric sorting keys in the storage
`orderBy` configuration. For SQL queries, explicitly convert the column to a
numeric type that can represent the data. Validate the range before converting;
ClickHouse integer conversion functions can overflow instead of rejecting
out-of-range input. For example, a known unsigned
`uint256` amount can use `toUInt256(amount)` for numeric ordering. Aggregates
need a separate range check: even if every input fits UInt256, their sum may
exceed its range and overflow. Input conversion checks do not bound the total.
For decimals, `toDecimal256(value, scale)` is suitable only when the value fits
its precision and scale; a full `uint256` range does not fit Decimal256's
76-digit precision. PostgreSQL storage does not have this ClickHouse mapping
restriction. See the [ClickHouse Decimal documentation](https://clickhouse.com/docs/sql-reference/data-types/decimal)
and [type conversion functions](https://clickhouse.com/docs/sql-reference/functions/type-conversion-functions).

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
  token0: Token! # entity reference — handler uses token0_id
  token1: Token! # entity reference — handler uses token1_id
  reserve0: BigInt!
  reserve1: BigInt!
  totalValueLocked: BigDecimal! @config(precision: 30, scale: 15)
  swaps: [Swap!]! @derivedFrom(field: "pool") # "pool" matches Swap.pool field name
}

type Swap {
  id: ID!
  pool: Pool! @index # entity reference — handler uses pool_id; @derivedFrom field arg = "pool"
  sender: String! @index
  amount0In: BigInt!
  amount1In: BigInt!
  timestamp: BigInt! @index
}
```

**Schema vs handler field names** (entity refs to `ID!`-keyed entities):

| Schema field | Schema type      | TypeScript handler field |
| ------------ | ---------------- | ------------------------ |
| `pool`       | `Pool!`          | `pool_id: string`        |
| `token0`     | `Token!`         | `token0_id: string`      |
| `collection` | `NftCollection!` | `collection_id: string`  |

Codegen appends `_id` to entity reference fields (never add it in the schema), typed as the referenced entity's id.

> If something is unclear, use the `envio-docs` skill to search and read the latest documentation.
