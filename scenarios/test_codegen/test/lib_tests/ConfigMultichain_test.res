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
        ClickHouse.makeCreateViewQuery(~entityConfig=shared, ~database="d"),
      )).toEqual((
        `CREATE TABLE IF NOT EXISTS "s"."IsolatedEntity"("id" TEXT NOT NULL, "chain_id" INTEGER NOT NULL, PRIMARY KEY("id", "chain_id"));`,
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
  LIMIT 1 BY \`id\`, \`chainId\`
)
WHERE \`envio_change\` = 'SET'`,
        `CREATE TABLE IF NOT EXISTS "s"."SharedEntity"("id" TEXT NOT NULL, PRIMARY KEY("id"));`,
        // Cross-chain entity: one current row per id, deduped by id alone.
        `CREATE VIEW IF NOT EXISTS d.\`SharedEntity\` AS
SELECT \`id\`
FROM (
  SELECT \`id\`, \`envio_change\`
  FROM d.\`envio_history_SharedEntity\`
  WHERE \`envio_checkpoint_id\` <= (SELECT max(id) FROM d.\`envio_checkpoints\`)
  ORDER BY \`envio_checkpoint_id\` DESC
  LIMIT 1 BY \`id\`
)
WHERE \`envio_change\` = 'SET'`,
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
        `CREATE TABLE IF NOT EXISTS "s"."IsolatedEntity"("id" TEXT NOT NULL, "chainId" INTEGER NOT NULL, PRIMARY KEY("id", "chainId"));`,
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

      // id and chain_id are both primary key columns, so there are no
      // non-primary columns left to update on conflict.
      t.expect((makeInsertQuery(snakeCase), makeInsertQuery(original))).toEqual((
        `INSERT INTO "s"."IsolatedEntity" ("id", "chain_id")
SELECT * FROM unnest($1::TEXT[],$2::INTEGER[])ON CONFLICT("id","chain_id") DO NOTHING;`,
        `INSERT INTO "s"."IsolatedEntity" ("id", "chainId")
SELECT * FROM unnest($1::TEXT[],$2::INTEGER[])ON CONFLICT("id","chainId") DO NOTHING;`,
      ))
    },
  )

  Async.it(
    "Stamps the group's chain id onto isolated entity rows",
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

      // Isolated entities flush one group per chain; each row is stamped with the
      // group's chain id.
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
            chainId: Some(1),
            changes: [Set({entityId: "a", entity: entity("a"), checkpointId: 1n})],
          },
          {
            entityConfig: isolated,
            chainId: Some(137),
            changes: [Set({entityId: "b", entity: entity("b"), checkpointId: 2n})],
          },
        ],
        ~chainMetaData=None,
      )

      let rows = await sql->Postgres.unsafe(
        `SELECT * FROM "${pgSchema}"."IsolatedEntity" ORDER BY "id";`,
      )

      t.expect(
        rows,
        ~message="Rows should carry the chain id of the group they were written in",
      ).toEqual(%raw(`[{id: "a", chain_id: 1}, {id: "b", chain_id: 137}]`))
    },
  )

  Async.it(
    "Keeps the same entity id on different chains as separate rows (composite primary key)",
    async t => {
      let config = makePublicConfig(
        ~storage=%raw(`{postgres: true, postgresColumnNameFormat: "snake_case"}`),
      )
      let isolated = config.userEntitiesByName->Dict.getUnsafe("IsolatedEntity")
      let pgSchema = "multichain_composite_key_test"
      let sql = PgStorage.makeClient()
      let storage = PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false)

      let _ = await storage.initialize(
        ~entities=[isolated],
        ~enums=[EntityHistory.RowAction.config->Table.fromGenericEnumConfig],
        ~envioInfo=%raw(`{}`),
      )

      let entity = id =>
        Dict.fromArray([("id", id->(Utils.magic: string => unknown))])->(
          Utils.magic: dict<unknown> => Internal.entity
        )

      // The same entity id "shared" is written on two chains. The flush groups
      // changes per chain (so the per-id dedup doesn't merge them), each tagged
      // with its chain id. The composite (id, chain_id) key keeps both rows
      // instead of one upserting over the other.
      await storage.writeBatch(
        ~batch={
          totalBatchSize: 2,
          items: [],
          progressedChainsById: Dict.make(),
          isInReorgThreshold: false,
          checkpointIds: [1n, 2n],
          checkpointChainIds: [1, 137],
          checkpointBlockNumbers: [10, 20],
          checkpointBlockHashes: [Null.null, Null.null],
          checkpointEventsProcessed: [1, 1],
        },
        ~rollback=None,
        ~isInReorgThreshold=false,
        ~config,
        ~allEntities=[isolated],
        ~updatedEffectsCache=[],
        ~updatedEntities=[
          {
            entityConfig: isolated,
            chainId: Some(1),
            changes: [Set({entityId: "shared", entity: entity("shared"), checkpointId: 1n})],
          },
          {
            entityConfig: isolated,
            chainId: Some(137),
            changes: [Set({entityId: "shared", entity: entity("shared"), checkpointId: 2n})],
          },
        ],
        ~chainMetaData=None,
      )

      let rows = await sql->Postgres.unsafe(
        `SELECT * FROM "${pgSchema}"."IsolatedEntity" ORDER BY "chain_id";`,
      )

      t.expect(
        rows,
        ~message="Same id on two chains should yield two rows keyed by (id, chain_id)",
      ).toEqual(%raw(`[{id: "shared", chain_id: 1}, {id: "shared", chain_id: 137}]`))
    },
  )

  Async.it(
    "Rollback restores per (id, chain) so a shared id only reverts the reorged chain",
    async t => {
      let config = makePublicConfig(
        ~storage=%raw(`{postgres: true, postgresColumnNameFormat: "snake_case"}`),
      )
      let isolated = config.userEntitiesByName->Dict.getUnsafe("IsolatedEntity")
      let pgSchema = "multichain_rollback_test"
      let sql = PgStorage.makeClient()
      let storage = PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false)

      let _ = await storage.initialize(
        ~entities=[isolated],
        ~enums=[EntityHistory.RowAction.config->Table.fromGenericEnumConfig],
        ~envioInfo=%raw(`{}`),
      )

      let entity = id =>
        Dict.fromArray([("id", id->(Utils.magic: string => unknown))])->(
          Utils.magic: dict<unknown> => Internal.entity
        )

      // History (saved because we're in the reorg threshold): "shared" exists on
      // chain 1 (cp 1) and chain 137 (cp 2), then chain 1 updates it again (cp 3).
      await storage.writeBatch(
        ~batch={
          totalBatchSize: 3,
          items: [],
          progressedChainsById: Dict.make(),
          isInReorgThreshold: true,
          checkpointIds: [1n, 2n, 3n],
          checkpointChainIds: [1, 137, 1],
          checkpointBlockNumbers: [10, 20, 30],
          checkpointBlockHashes: [Null.null, Null.null, Null.null],
          checkpointEventsProcessed: [1, 1, 1],
        },
        ~rollback=None,
        ~isInReorgThreshold=true,
        ~config,
        ~allEntities=[isolated],
        ~updatedEffectsCache=[],
        ~updatedEntities=[
          {
            entityConfig: isolated,
            chainId: Some(1),
            changes: [
              Set({entityId: "shared", entity: entity("shared"), checkpointId: 1n}),
              Set({entityId: "shared", entity: entity("shared"), checkpointId: 3n}),
            ],
          },
          {
            entityConfig: isolated,
            chainId: Some(137),
            changes: [Set({entityId: "shared", entity: entity("shared"), checkpointId: 2n})],
          },
        ],
        ~chainMetaData=None,
      )

      // Roll back to checkpoint 2: only chain 1's "shared" was modified after it
      // (cp 3), so only chain 1's row should be restored — chain 137's untouched.
      let (removed, restored) = await storage.getRollbackData(
        ~entityConfig=isolated,
        ~rollbackTargetCheckpointId=2n,
      )

      t.expect(
        (removed, restored),
        ~message="Only the reorged chain's row is restored; the shared id on the other chain is left alone",
      ).toEqual(([], %raw(`[{id: "shared", chain_id: 1}]`)))
    },
  )
})
