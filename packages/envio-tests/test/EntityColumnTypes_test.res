open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: entity-column-types
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type PostgresNumericPrecisionEntityTester {
  id: ID!
  exampleBigInt: BigInt @config(precision: 76)
  exampleBigIntRequired: BigInt! @config(precision: 77)
  exampleBigIntArray: [BigInt!] @config(precision: 78)
  exampleBigIntArrayRequired: [BigInt!]! @config(precision: 79)
  exampleBigDecimal: BigDecimal @config(precision: 80, scale: 5)
  exampleBigDecimalRequired: BigDecimal! @config(precision: 81, scale: 5)
  exampleBigDecimalArray: [BigDecimal!] @config(precision: 82, scale: 5)
  exampleBigDecimalArrayRequired: [BigDecimal!]! @config(precision: 83, scale: 5)
  exampleBigDecimalOtherOrder: BigDecimal! @config(scale: 6, precision: 84)
}
`,
  ~unsupported=[
    {backend: #memory, reason: "asserts Postgres column types and numeric precision"},
    {backend: #clickhouse, reason: "the schema's nullable arrays have no ClickHouse equivalent"},
  ],
)

describe("Postgres Numeric Precision Entity Tester Migrations", () => {
  scenario->Scenario.it(
    "should have the correct columns and data types in 'PostgresNumericPrecisionEntityTester' table",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source as _) => {
      let {sql, pgSchema} = indexer->IndexerRunner.pgOrThrow
      //  This SQL is quite a beast, but it does work 🙏
      let columnsRes: array<{
        "column_name": string,
        "data_type": string,
        "element_data_type": string,
        "numeric_precision": Nullable.t<int>,
        "numeric_scale": Nullable.t<int>,
        "is_nullable": string,
      }> = await sql->Postgres.unsafe(`SELECT
          a.attname AS column_name,
          pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
          CASE
            WHEN t.typcategory = 'A' THEN
              pg_catalog.format_type(t.typelem, NULL)
            ELSE ''
          END AS element_data_type,
          CASE
            WHEN t.typname LIKE 'numeric%' OR et.typname LIKE 'numeric%' THEN
              (regexp_match(pg_catalog.format_type(a.atttypid, a.atttypmod), 'numeric\\((\\d+),(\\d+)\\)'))[1]::int
            ELSE NULL
          END AS numeric_precision,
          CASE
            WHEN t.typname LIKE 'numeric%' OR et.typname LIKE 'numeric%' THEN
              (regexp_match(pg_catalog.format_type(a.atttypid, a.atttypmod), 'numeric\\((\\d+),(\\d+)\\)'))[2]::int
            ELSE NULL
          END AS numeric_scale,
          CASE
            WHEN a.attnotnull THEN 'NO'
            ELSE 'YES'
          END AS is_nullable
        FROM
          pg_attribute a
          JOIN pg_class c ON a.attrelid = c.oid
          JOIN pg_namespace n ON c.relnamespace = n.oid
          JOIN pg_type t ON a.atttypid = t.oid
          LEFT JOIN pg_type et ON t.typelem = et.oid
        WHERE
          n.nspname = '${pgSchema}' AND
          c.relname = 'PostgresNumericPrecisionEntityTester' AND
          a.attnum > 0 AND
          NOT a.attisdropped
        ORDER BY
          a.attnum;`)

      t.expect(columnsRes).toEqual([
        {
          "column_name": "id",
          "data_type": "text",
          "element_data_type": "",
          "numeric_precision": Nullable.null,
          "numeric_scale": Nullable.null,
          "is_nullable": "NO",
        },
        {
          "column_name": "exampleBigInt",
          "data_type": "numeric(76,0)",
          "element_data_type": "",
          "numeric_precision": Nullable.make(76),
          "numeric_scale": Nullable.make(0),
          "is_nullable": "YES",
        },
        {
          "column_name": "exampleBigIntRequired",
          "data_type": "numeric(77,0)",
          "element_data_type": "",
          "numeric_precision": Nullable.make(77),
          "numeric_scale": Nullable.make(0),
          "is_nullable": "NO",
        },
        {
          "column_name": "exampleBigIntArray",
          "data_type": "numeric(78,0)[]",
          "element_data_type": "numeric",
          "numeric_precision": Nullable.make(78),
          "numeric_scale": Nullable.make(0),
          "is_nullable": "YES",
        },
        {
          "column_name": "exampleBigIntArrayRequired",
          "data_type": "numeric(79,0)[]",
          "element_data_type": "numeric",
          "numeric_precision": Nullable.make(79),
          "numeric_scale": Nullable.make(0),
          "is_nullable": "NO",
        },
        {
          "column_name": "exampleBigDecimal",
          "data_type": "numeric(80,5)",
          "element_data_type": "",
          "numeric_precision": Nullable.make(80),
          "numeric_scale": Nullable.make(5),
          "is_nullable": "YES",
        },
        {
          "column_name": "exampleBigDecimalRequired",
          "data_type": "numeric(81,5)",
          "element_data_type": "",
          "numeric_precision": Nullable.make(81),
          "numeric_scale": Nullable.make(5),
          "is_nullable": "NO",
        },
        {
          "column_name": "exampleBigDecimalArray",
          "data_type": "numeric(82,5)[]",
          "element_data_type": "numeric",
          "numeric_precision": Nullable.make(82),
          "numeric_scale": Nullable.make(5),
          "is_nullable": "YES",
        },
        {
          "column_name": "exampleBigDecimalArrayRequired",
          "data_type": "numeric(83,5)[]",
          "element_data_type": "numeric",
          "numeric_precision": Nullable.make(83),
          "numeric_scale": Nullable.make(5),
          "is_nullable": "NO",
        },
        {
          "column_name": "exampleBigDecimalOtherOrder",
          "data_type": "numeric(84,6)",
          "element_data_type": "",
          "numeric_precision": Nullable.make(84),
          "numeric_scale": Nullable.make(6),
          "is_nullable": "NO",
        },
      ])
    },
  )
})
