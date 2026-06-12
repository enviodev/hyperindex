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

  Async.it(
    "Includes the chain id column in the insert query for isolated entities",
    async t => {
      let snakeCase = makePublicConfig(
        ~storage=%raw(`{postgres: true, postgresColumnNameFormat: "snake_case"}`),
      )
      let original = makePublicConfig(~storage=%raw(`{postgres: true}`))
      let makeInsertQuery = (config: Config.t) => {
        let isolated = config.userEntitiesByName->Dict.getUnsafe("IsolatedEntity")
        PgStorage.makeInsertUnnestSetQuery(
          ~pgSchema="s",
          ~table=isolated.table,
          ~itemSchema=PgStorage.getWriteSchema(isolated),
          ~isRawEvents=false,
        )
      }

      t.expect((makeInsertQuery(snakeCase), makeInsertQuery(original))).toEqual((
        `INSERT INTO "s"."IsolatedEntity" ("id", "chain_id")
SELECT * FROM unnest($1::TEXT[],$2::INTEGER[])ON CONFLICT("id") DO UPDATE SET "chain_id" = EXCLUDED."chain_id";`,
        `INSERT INTO "s"."IsolatedEntity" ("id", "chainId")
SELECT * FROM unnest($1::TEXT[],$2::INTEGER[])ON CONFLICT("id") DO UPDATE SET "chainId" = EXCLUDED."chainId";`,
      ))
    },
  )

  Async.it(
    "Stamps the chain id from the change's checkpoint when writing isolated entities",
    async t => {
      let config = makePublicConfig(
        ~storage=%raw(`{postgres: true, postgresColumnNameFormat: "snake_case"}`),
      )
      let isolated = config.userEntitiesByName->Dict.getUnsafe("IsolatedEntity")
      let pgSchema = "multichain_write_test"
      let sql = PgStorage.makeClient()
      let storage = PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false)

      let _ = await storage.initialize(
        ~entities=[isolated],
        ~enums=[EntityHistory.RowAction.config->Table.fromGenericEnumConfig],
        ~envioInfo=%raw(`{}`),
      )

      let batch: Batch.t = {
        totalBatchSize: 2,
        items: [],
        progressedChainsById: Dict.make(),
        isInReorgThreshold: false,
        checkpointIds: [1n, 2n],
        checkpointChainIds: [1, 137],
        checkpointBlockNumbers: [10, 20],
        checkpointBlockHashes: [Null.null, Null.null],
        checkpointEventsProcessed: [1, 1],
      }
      let entity = id =>
        Dict.fromArray([("id", id->(Utils.magic: string => unknown))])->(
          Utils.magic: dict<unknown> => Internal.entity
        )

      await storage.writeBatch(
        ~batch,
        ~rollback=None,
        ~isInReorgThreshold=false,
        ~config,
        ~allEntities=[isolated],
        ~updatedEffectsCache=[],
        ~updatedEntities=[
          {
            entityConfig: isolated,
            changes: [
              Set({entityId: "a", entity: entity("a"), checkpointId: 1n}),
              Set({entityId: "b", entity: entity("b"), checkpointId: 2n}),
            ],
          },
        ],
        ~chainMetaData=None,
      )

      let rows = await sql->Postgres.unsafe(
        `SELECT * FROM "${pgSchema}"."IsolatedEntity" ORDER BY "id";`,
      )

      t.expect(
        rows,
        ~message="Rows should carry the chain id of the checkpoint their change was made at",
      ).toEqual(%raw(`[{id: "a", chain_id: 1}, {id: "b", chain_id: 137}]`))
    },
  )
})
