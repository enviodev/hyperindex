open Vitest

// Entities without crossChain (isolated multichain mode) get a chain id
// column appended at config parse time, spelled per each backend's
// column_name_format. Cross-chain entities (unordered mode) don't.
describe("Multichain entity chain id column", () => {
  let makePublicConfigJson: JSON.t => JSON.t = %raw(`(storage) => ({
    name: "test",
    storage,
    evm: {chains: {"1": {id: 1, startBlock: 0}}},
    entities: [
      {name: "IsolatedEntity", properties: [{name: "id", type: "string"}]},
      {name: "SharedEntity", crossChain: true, properties: [{name: "id", type: "string"}]},
    ],
  })`)
  let makePublicConfig = (~storage) => storage->makePublicConfigJson->Config.fromPublic

  Async.it(
    "Adds a chain id column for isolated entities only, per backend column name format",
    async t => {
      let config = makePublicConfig(
        ~storage=%raw(`{postgres: true, postgresColumnNameFormat: "snake_case", clickhouse: true}`),
      )
      let isolated = config.userEntitiesByName->Dict.getUnsafe("IsolatedEntity")
      let shared = config.userEntitiesByName->Dict.getUnsafe("SharedEntity")

      t.expect((
        PgStorage.makeCreateTableQuery(isolated.table, ~pgSchema="s", ~isNumericArrayAsText=false),
        ClickHouse.makeCreateHistoryTableQuery(~entityConfig=isolated, ~database="d"),
        ClickHouse.makeCreateViewQuery(~entityConfig=isolated, ~database="d"),
        PgStorage.makeCreateTableQuery(shared.table, ~pgSchema="s", ~isNumericArrayAsText=false),
      )).toEqual((
        `CREATE TABLE IF NOT EXISTS "s"."IsolatedEntity"("id" TEXT NOT NULL, "chain_id" INTEGER NOT NULL, PRIMARY KEY("id"));`,
        `CREATE TABLE IF NOT EXISTS d.\`envio_history_IsolatedEntity\` (
  \`id\` String,
  \`chainId\` Int32,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (id, envio_checkpoint_id)`,
        `CREATE VIEW IF NOT EXISTS d.\`IsolatedEntity\` AS
SELECT \`id\`, \`chainId\`
FROM (
  SELECT \`id\`, \`chainId\`, \`envio_change\`
  FROM d.\`envio_history_IsolatedEntity\`
  WHERE \`envio_checkpoint_id\` <= (SELECT max(id) FROM d.\`envio_checkpoints\`)
  ORDER BY \`envio_checkpoint_id\` DESC
  LIMIT 1 BY \`id\`
)
WHERE \`envio_change\` = 'SET'`,
        `CREATE TABLE IF NOT EXISTS "s"."SharedEntity"("id" TEXT NOT NULL, PRIMARY KEY("id"));`,
      ))
    },
  )

  Async.it(
    "Spells the chain id column as chainId for the original column name format",
    async t => {
      let config = makePublicConfig(
        ~storage=%raw(`{postgres: true, clickhouse: true, clickhouseColumnNameFormat: "snake_case"}`),
      )
      let isolated = config.userEntitiesByName->Dict.getUnsafe("IsolatedEntity")

      t.expect((
        PgStorage.makeCreateTableQuery(isolated.table, ~pgSchema="s", ~isNumericArrayAsText=false),
        ClickHouse.makeCreateHistoryTableQuery(~entityConfig=isolated, ~database="d"),
      )).toEqual((
        `CREATE TABLE IF NOT EXISTS "s"."IsolatedEntity"("id" TEXT NOT NULL, "chainId" INTEGER NOT NULL, PRIMARY KEY("id"));`,
        `CREATE TABLE IF NOT EXISTS d.\`envio_history_IsolatedEntity\` (
  \`id\` String,
  \`chain_id\` Int32,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (id, envio_checkpoint_id)`,
      ))
    },
  )
})
