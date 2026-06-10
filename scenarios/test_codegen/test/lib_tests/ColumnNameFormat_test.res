open Vitest

// Mirrors the public config the CLI emits when the backends configure
// different `column_name_format`s: the resolved column names arrive as
// per-property `dbName` (Postgres) and `clickhouseDbName` (ClickHouse)
// values. Snapshot uses snake_case in Postgres only; Token uses snake_case
// in ClickHouse only.
let publicConfigJson: JSON.t = %raw(`{
  "version": "0.0.1-dev",
  "name": "test",
  "storage": { "postgres": true, "clickhouse": true },
  "evm": {
    "chains": {
      "ethereumMainnet": {
        "id": 1,
        "startBlock": 0,
        "rpcs": [{ "url": "https://eth.com", "for": "sync" }]
      }
    },
    "addressFormat": "checksum"
  },
  "enums": {},
  "entities": [{
    "name": "Snapshot",
    "properties": [
      { "name": "id", "type": "string" },
      { "name": "transactionIndex", "type": "int", "dbName": "transaction_index", "isIndex": true },
      { "name": "tokenOwner", "type": "entity", "dbName": "token_owner_id", "linkedEntity": "User", "entity": "User" }
    ]
  }, {
    "name": "Token",
    "properties": [
      { "name": "id", "type": "string" },
      { "name": "tokenId", "type": "int", "clickhouseDbName": "token_id" }
    ]
  }, {
    "name": "User",
    "properties": [
      { "name": "id", "type": "string" }
    ]
  }]
}`)

let config = Config.fromPublic(publicConfigJson)
let snapshotEntity = config.userEntitiesByName->Dict.getUnsafe("Snapshot")

// The entity record keeps the API field names from schema.graphql
type snapshot = {
  id: string,
  transactionIndex: int,
  tokenOwner_id: string,
}
let snapshot1 = {id: "1", transactionIndex: 5, tokenOwner_id: "user-1"}

describe("Storage column naming (snake_case)", () => {
  it("keeps API field names in the entity schema", t => {
    let json =
      snapshot1
      ->(Utils.magic: snapshot => Internal.entity)
      ->S.reverseConvertToJsonOrThrow(snapshotEntity.schema)
    t.expect(json).toEqual(
      %raw(`{ "id": "1", "transactionIndex": 5, "tokenOwner_id": "user-1" }`),
    )
  })

  it("creates the Postgres table with db column names", t => {
    let query = PgStorage.makeCreateTableQuery(
      snapshotEntity.table,
      ~pgSchema="test_schema",
      ~isNumericArrayAsText=false,
    )
    t.expect(
      query,
    ).toBe(`CREATE TABLE IF NOT EXISTS "test_schema"."Snapshot"("id" TEXT NOT NULL, "transaction_index" INTEGER NOT NULL, "token_owner_id" TEXT NOT NULL, PRIMARY KEY("id"));`)
  })

  it("creates indices with db column names", t => {
    let query = PgStorage.makeCreateTableIndicesQuery(snapshotEntity.table, ~pgSchema="test_schema")
    t.expect(
      query,
    ).toBe(`CREATE INDEX IF NOT EXISTS "Snapshot_transaction_index" ON "test_schema"."Snapshot"("transaction_index");`)
  })

  it("references db column names in the insert query", t => {
    let query = PgStorage.makeInsertUnnestSetQuery(
      ~pgSchema="test_schema",
      ~table=snapshotEntity.table,
      ~itemSchema=snapshotEntity.schema->S.toUnknown,
      ~isRawEvents=false,
    )
    t.expect(query).toBe(`INSERT INTO "test_schema"."Snapshot" ("id", "transaction_index", "token_owner_id")
SELECT * FROM unnest($1::TEXT[],$2::INTEGER[],$3::TEXT[])ON CONFLICT("id") DO UPDATE SET "transaction_index" = EXCLUDED."transaction_index","token_owner_id" = EXCLUDED."token_owner_id";`)
  })

  it("converts entities to insert params by reading API field names", t => {
    let data = PgStorage.makeTableBatchSetQuery(
      ~pgSchema="test_schema",
      ~table=snapshotEntity.table,
      ~itemSchema=snapshotEntity.schema->S.toUnknown,
    )
    let params = data["convertOrThrow"]([snapshot1->(Utils.magic: snapshot => unknown)])
    t.expect(params->(Utils.magic: unknown => JSON.t)).toEqual(
      %raw(`[["1"], [5], ["user-1"]]`),
    )
  })

  it("parses rows keyed by db column names into entities", t => {
    let rows = %raw(`[{ "id": "1", "transaction_index": 5, "token_owner_id": "user-1" }]`)
    let entities = rows->S.parseOrThrow(snapshotEntity.rowsSchema)
    t.expect(entities->(Utils.magic: array<Internal.entity> => array<snapshot>)).toEqual([
      snapshot1,
    ])
  })

  it("inserts history rows with db column names", t => {
    let entityHistory = PgStorage.getEntityHistory(~entityConfig=snapshotEntity)
    let query = PgStorage.makeInsertValuesSetQuery(
      ~pgSchema="test_schema",
      ~table=entityHistory.table,
      ~itemSchema=entityHistory.setChangeSchema->S.toUnknown,
      ~itemsCount=1,
    )
    t.expect(query).toBe(`INSERT INTO "test_schema"."envio_history_Snapshot" ("envio_change", "id", "transaction_index", "token_owner_id", "envio_checkpoint_id")
VALUES($1,$2,$3,$4,$5)ON CONFLICT("id","envio_checkpoint_id") DO UPDATE SET "envio_change" = EXCLUDED."envio_change","transaction_index" = EXCLUDED."transaction_index","token_owner_id" = EXCLUDED."token_owner_id";`)
  })

  it("keeps API field names in ClickHouse when only Postgres renames columns", t => {
    let query = ClickHouse.makeCreateHistoryTableQuery(
      ~entityConfig=snapshotEntity,
      ~database="envio",
    )
    t.expect(query).toBe(`CREATE TABLE IF NOT EXISTS envio.\`envio_history_Snapshot\` (
  \`id\` String,
  \`transactionIndex\` Int32,
  \`tokenOwner_id\` String,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (id, envio_checkpoint_id)`)
  })

  it("serializes ClickHouse set updates with ClickHouse column keys", t => {
    let setUpdateSchema = EntityHistory.makeSetUpdateSchema(
      ClickHouse.makeClickHouseEntitySchema(snapshotEntity.table),
    )
    let json =
      Change.Set({
        entityId: "1",
        entity: snapshot1->(Utils.magic: snapshot => Internal.entity),
        checkpointId: 5n,
      })->S.reverseConvertToJsonOrThrow(setUpdateSchema)
    t.expect(json).toEqual(
      %raw(`{
        "envio_change": "SET",
        "envio_checkpoint_id": "5",
        "id": "1",
        "transactionIndex": 5,
        "tokenOwner_id": "user-1"
      }`),
    )
  })

  it("renames ClickHouse columns independently from Postgres", t => {
    let tokenEntity = config.userEntitiesByName->Dict.getUnsafe("Token")
    let pgQuery = PgStorage.makeCreateTableQuery(
      tokenEntity.table,
      ~pgSchema="test_schema",
      ~isNumericArrayAsText=false,
    )
    let clickhouseQuery = ClickHouse.makeCreateHistoryTableQuery(
      ~entityConfig=tokenEntity,
      ~database="envio",
    )
    t.expect({
      "postgres": pgQuery,
      "clickhouse": clickhouseQuery,
    }).toEqual({
      "postgres": `CREATE TABLE IF NOT EXISTS "test_schema"."Token"("id" TEXT NOT NULL, "tokenId" INTEGER NOT NULL, PRIMARY KEY("id"));`,
      "clickhouse": `CREATE TABLE IF NOT EXISTS envio.\`envio_history_Token\` (
  \`id\` String,
  \`token_id\` Int32,
  \`envio_checkpoint_id\` UInt64,
  \`envio_change\` Enum8('SET', 'DELETE')
)
ENGINE = MergeTree()
ORDER BY (id, envio_checkpoint_id)`,
    })
  })

  it("keeps using API field names for tables without renamed columns", t => {
    let userEntity = config.userEntitiesByName->Dict.getUnsafe("User")
    let query = PgStorage.makeCreateTableQuery(
      userEntity.table,
      ~pgSchema="test_schema",
      ~isNumericArrayAsText=false,
    )
    t.expect(
      query,
    ).toBe(`CREATE TABLE IF NOT EXISTS "test_schema"."User"("id" TEXT NOT NULL, PRIMARY KEY("id"));`)
  })

  Async.it("initializes, writes and reads back entities from a real Postgres", async t => {
    let pgSchema = "colnaming_test_schema"
    let sql = PgStorage.makeClient()
    let storage = PgStorage.make(
      ~sql,
      ~pgHost=Env.Db.host,
      ~pgSchema,
      ~pgPort=Env.Db.port,
      ~pgUser=Env.Db.user,
      ~pgDatabase=Env.Db.database,
      ~pgPassword=Env.Db.password,
      ~isHasuraEnabled=false,
    )
    let _ = await storage.initialize(
      ~entities=config.allEntities,
      ~enums=config.allEnums->Array.concat([
        EntityHistory.RowAction.config->Table.fromGenericEnumConfig,
      ]),
      ~envioInfo=JSON.Object(Dict.make()),
    )

    await PgStorage.setOrThrow(
      sql,
      ~items=[snapshot1->(Utils.magic: snapshot => unknown)],
      ~table=snapshotEntity.table,
      ~itemSchema=snapshotEntity.schema->S.toUnknown,
      ~pgSchema,
    )

    let rawRows = await sql->Postgres.unsafe(`SELECT * FROM "${pgSchema}"."Snapshot";`)
    let loadedByIds = await storage.loadByIdsOrThrow(
      ~ids=["1"],
      ~table=snapshotEntity.table,
      ~rowsSchema=snapshotEntity.rowsSchema,
    )
    let loadedByField = await storage.loadByFieldOrThrow(
      ~fieldName="transactionIndex",
      ~fieldSchema=S.int,
      ~fieldValue=5,
      ~operator=#"=",
      ~table=snapshotEntity.table,
      ~rowsSchema=snapshotEntity.rowsSchema,
    )

    let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
    await storage.close()

    t.expect({
      "rawRows": rawRows->(Utils.magic: array<unknown> => JSON.t),
      "loadedByIds": loadedByIds->(Utils.magic: array<Internal.entity> => array<snapshot>),
      "loadedByField": loadedByField->(Utils.magic: array<Internal.entity> => array<snapshot>),
    }).toEqual({
      "rawRows": %raw(`[{ "id": "1", "transaction_index": 5, "token_owner_id": "user-1" }]`),
      "loadedByIds": [snapshot1],
      "loadedByField": [snapshot1],
    })
  })
})
