open Vitest

// https://github.com/enviodev/hyperindex/issues/1542
//
// envio appends a `chainId` column to every per-chain entity's table. It is a
// column like any other by the time storage sees it, so `@storage(clickhouse:
// {orderBy})` and `@index(fields:)` can name it — the directive namespace is
// the declared fields plus that appended column.

let configYaml = (~perChain, ~columnNameFormat="original") =>
  `
name: per-chain-directive-fields
${perChain ? "disable_default_cross_chain: true" : ""}
storage:
  postgres:
    default: true
  clickhouse:
    default: true
    column_name_format: ${columnNameFormat}
chains:
  - id: 1
    start_block: 0
  - id: 137
    start_block: 0
`

let parse = (~perChain, ~columnNameFormat="original", schema) =>
  InternalTestIndexer.fromUserApi(
    ~schema,
    ~configYaml=configYaml(~perChain, ~columnNameFormat),
  ).config

let parseError = (~perChain, ~columnNameFormat="original", schema) =>
  InternalTestIndexer.parseError(~schema, ~configYaml=configYaml(~perChain, ~columnNameFormat))

let entityConfig = (config: Config.t, name) => config.userEntitiesByName->Dict.getUnsafe(name)

describe("clickhouse.orderBy on the appended chain column", () => {
  it("Sorts by the chain column when the entity lists it", t => {
    let config = parse(
      ~perChain=true,
      ~columnNameFormat="snake_case",
      `
type Transfer @storage(clickhouse: {orderBy: ["chainId", "timestamp"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
    )

    t.expect(
      ClickHouse.makeCreateHistoryTableQuery(
        ~entityConfig=config->entityConfig("Transfer"),
        ~database="db",
      ),
      ~message="chain column leads the sorting key",
    ).toBe(`CREATE TABLE IF NOT EXISTS db.\`envio_history_Transfer\` (
  \`id\` String,
  \`timestamp\` DateTime64(3, 'UTC'),
  \`chain_id\` Int32,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (\`chain_id\`, \`timestamp\`, envio_checkpoint_id)`)
  })

  it("Sorts by the chain column alone, overriding the default id sorting key", t => {
    let config = parse(
      ~perChain=true,
      ~columnNameFormat="snake_case",
      `
type Transfer @storage(clickhouse: {orderBy: ["chainId"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
    )

    t.expect(
      ClickHouse.makeCreateHistoryTableQuery(
        ~entityConfig=config->entityConfig("Transfer"),
        ~database="db",
      ),
      ~message="a lone chain column replaces the default id prefix",
    ).toBe(`CREATE TABLE IF NOT EXISTS db.\`envio_history_Transfer\` (
  \`id\` String,
  \`timestamp\` DateTime64(3, 'UTC'),
  \`chain_id\` Int32,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (\`chain_id\`, envio_checkpoint_id)`)
  })

  it("Keeps the listed position, so a trailing chain column stays trailing", t => {
    let config = parse(
      ~perChain=true,
      ~columnNameFormat="snake_case",
      `
type Transfer @storage(clickhouse: {orderBy: ["timestamp", "chainId"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
    )

    t.expect(
      ClickHouse.makeCreateHistoryTableQuery(
        ~entityConfig=config->entityConfig("Transfer"),
        ~database="db",
      ),
      ~message="chain column stays where the schema put it",
    ).toBe(`CREATE TABLE IF NOT EXISTS db.\`envio_history_Transfer\` (
  \`id\` String,
  \`timestamp\` DateTime64(3, 'UTC'),
  \`chain_id\` Int32,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (\`timestamp\`, \`chain_id\`, envio_checkpoint_id)`)
  })

  it("Points at the schema spelling when the storage column name is used", t => {
    t.expect(
      parseError(
        ~perChain=true,
        ~columnNameFormat="snake_case",
        `
type Transfer @storage(clickhouse: {orderBy: ["chain_id"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:15: Invalid \`clickhouse.orderBy\` on \`Transfer\`: \`chain_id\` is not a column of the entity.
  Spell the chain column as \`chainId\`, the way it's named in the schema, whatever \`column_name_format\` the storage uses.`)
  })

  it("Rejects the chain column on a cross-chain entity, which never gets one", t => {
    t.expect(
      parseError(
        ~perChain=true,
        `
type Transfer @crossChain @storage(clickhouse: {orderBy: ["chainId"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:27: Invalid \`clickhouse.orderBy\` on \`Transfer\`: \`chainId\` is not a column of the entity.
  envio only appends a chain column to per-chain entities, and \`Transfer\` is \`@crossChain\`. Drop \`@crossChain\`, or declare a \`chainId\` field yourself.`)
  })

  it("Points at the config flag when entities are cross-chain by default", t => {
    t.expect(
      parseError(
        ~perChain=false,
        `
type Transfer @storage(clickhouse: {orderBy: ["chainId"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:15: Invalid \`clickhouse.orderBy\` on \`Transfer\`: \`chainId\` is not a column of the entity.
  envio only appends a chain column to per-chain entities, and entities are cross-chain unless config.yaml sets \`disable_default_cross_chain: true\`. Set it, or declare a \`chainId\` field yourself.`)
  })

  it("Doesn't suggest dropping @crossChain when that alone changes nothing", t => {
    t.expect(
      parseError(
        ~perChain=false,
        `
type Transfer @crossChain @storage(clickhouse: {orderBy: ["chainId"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:27: Invalid \`clickhouse.orderBy\` on \`Transfer\`: \`chainId\` is not a column of the entity.
  envio only appends a chain column to per-chain entities, and entities are cross-chain unless config.yaml sets \`disable_default_cross_chain: true\`. Set it and drop \`@crossChain\`, or declare a \`chainId\` field yourself.`)
  })

  it("Treats a declared chainId on a cross-chain entity as an ordinary column", t => {
    let config = parse(
      ~perChain=true,
      ~columnNameFormat="snake_case",
      `
type Transfer @crossChain @storage(clickhouse: {orderBy: ["chainId", "timestamp"]}) {
  id: ID!
  chainId: Int!
  timestamp: Timestamp!
}
`,
    )

    t.expect(
      ClickHouse.makeCreateHistoryTableQuery(
        ~entityConfig=config->entityConfig("Transfer"),
        ~database="db",
      ),
      ~message="the user's own chainId field sorts like any other",
    ).toBe(`CREATE TABLE IF NOT EXISTS db.\`envio_history_Transfer\` (
  \`id\` String,
  \`chain_id\` Int32,
  \`timestamp\` DateTime64(3, 'UTC'),
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (\`chain_id\`, \`timestamp\`, envio_checkpoint_id)`)
  })

  it("Lists the columns available when the name is nothing at all", t => {
    t.expect(
      parseError(
        ~perChain=true,
        `
type Transfer @storage(clickhouse: {orderBy: ["blockNumber"]}) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:15: Invalid \`clickhouse.orderBy\` on \`Transfer\`: \`blockNumber\` is not a column of the entity.
  Available columns: \`id\`, \`timestamp\`, \`chainId\`.`)
  })
})

describe("@index on the appended chain column", () => {
  it("Indexes the chain column alongside another field", t => {
    let config = parse(
      ~perChain=true,
      `
type Transfer @index(fields: ["chainId", "timestamp"]) {
  id: ID!
  timestamp: Timestamp!
}
`,
    )

    t.expect(
      (config->entityConfig("Transfer")).table->Table.getCompositeIndexes,
      ~message="the appended chain column resolves to its storage column",
    ).toEqual([
      [
        ({fieldName: "chainId", direction: Table.Asc}: Table.compositeIndexField),
        {fieldName: "timestamp", direction: Table.Asc},
      ],
    ])
  })

  it("Rejects a lone chain-column index, which the primary key already covers", t => {
    t.expect(
      parseError(
        ~perChain=true,
        `
type Transfer @index(fields: ["chainId"]) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:15: Invalid \`@index\` on \`Transfer\`: \`chainId\` is part of the primary key envio appends to every per-chain entity, so it is already indexed.
  List it with another column, e.g. \`@index(fields: ["chainId", "timestamp"])\`.`)
  })

  it("Rejects the chain column on a cross-chain entity, which never gets one", t => {
    t.expect(
      parseError(
        ~perChain=true,
        `
type Transfer @crossChain @index(fields: ["chainId", "timestamp"]) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:27: Invalid \`@index\` on \`Transfer\`: \`chainId\` is not a column of the entity.
  envio only appends a chain column to per-chain entities, and \`Transfer\` is \`@crossChain\`. Drop \`@crossChain\`, or declare a \`chainId\` field yourself.`)
  })

  it("Has no db_write_timestamp column to index", t => {
    t.expect(
      parseError(
        ~perChain=true,
        `
type Transfer @index(fields: ["db_write_timestamp", "timestamp"]) {
  id: ID!
  timestamp: Timestamp!
}
`,
      ),
    ).toBe(`schema.graphql:2:15: Invalid \`@index\` on \`Transfer\`: \`db_write_timestamp\` is not a column of the entity.
  Available columns: \`id\`, \`timestamp\`, \`chainId\`.`)
  })
})
