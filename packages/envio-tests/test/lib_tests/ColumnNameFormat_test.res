open Vitest

let config = InternalTestIndexer.fromUserApi(
  ~schema=`
type Snapshot {
  id: ID!
  transactionIndex: Int! @index
  tokenOwner: User!
}

type User {
  id: ID!
}
`,
  ~configYaml=`
name: column-names
storage:
  postgres:
    default: true
    column_name_format: snake_case
  clickhouse:
    default: true
    column_name_format: original
chains:
  - id: 1
    start_block: 0
`,
).config

let reverseFormatConfig = InternalTestIndexer.fromUserApi(
  ~schema=`
type Token {
  id: ID!
  tokenId: Int!
}
`,
  ~configYaml=`
name: reverse-column-names
storage:
  postgres:
    default: true
    column_name_format: original
  clickhouse:
    default: true
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
`,
).config
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

  it("creates indexes with db column names", t => {
    let definition =
      PgStorage.getSchemaIndexes(~entities=[snapshotEntity])->Array.getUnsafe(0)
    t.expect(
      definition->IndexDefinition.makeCreateQuery(~pgSchema="test_schema"),
    ).toBe(
      `CREATE INDEX "${definition->IndexDefinition.name}" ON "test_schema"."Snapshot"("transaction_index");`,
    )
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
    let entities = rows->S.parseOrThrow(
      snapshotEntity.table
      ->Table.pgRowsSchema
      ->(Utils.magic: S.t<array<unknown>> => S.t<array<Internal.entity>>),
    )
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
    // The spec is what crosses to Rust, so the column names it carries are the
    // ones the history table is created with and written to.
    let spec = ClickHouse.entitySpec(~entityConfig=snapshotEntity)
    t.expect(spec.columns->Array.map(({name}) => name)).toEqual([
      "id",
      "transactionIndex",
      "tokenOwner_id",
    ])
  })

  it("serializes ClickHouse set updates with ClickHouse column keys", t => {
    let setUpdateSchema = EntityHistory.makeSetUpdateSchema(
      ~idSchema=snapshotEntity.table->Table.getIdSchema,
      ClickHouse.makeClickHouseEntitySchema(snapshotEntity.table),
    )
    let json =
      Change.Set({
        entityId: "1"->EntityId.unsafeOfString,
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
    let tokenEntity = reverseFormatConfig.userEntitiesByName->Dict.getUnsafe("Token")
    let pgQuery = PgStorage.makeCreateTableQuery(
      tokenEntity.table,
      ~pgSchema="test_schema",
      ~isNumericArrayAsText=false,
    )
    t.expect({
      "postgres": pgQuery,
      "clickhouse": ClickHouse.entitySpec(~entityConfig=tokenEntity).columns->Array.map(({name}) =>
        name
      ),
    }).toEqual({
      "postgres": `CREATE TABLE IF NOT EXISTS "test_schema"."Token"("id" TEXT NOT NULL, "tokenId" INTEGER NOT NULL, PRIMARY KEY("id"));`,
      "clickhouse": ["id", "token_id"],
    })
  })

  it("maps API field names to pg columns for load filters", t => {
    let mapping =
      snapshotEntity.table
      ->Table.queryFields
      ->Dict.toArray
      ->Array.map(((apiName, queryField: Table.queryField)) => (apiName, queryField.pgDbFieldName))
      ->Dict.fromArray
    t.expect(mapping->(Utils.magic: dict<string> => JSON.t)).toEqual(
      %raw(`{
        "id": "id",
        "transactionIndex": "transaction_index",
        "tokenOwner_id": "token_owner_id"
      }`),
    )
  })

  it("exposes renamed columns in Hasura under the original field name", t => {
    let columnConfigs = Hasura.makeColumnConfigs(snapshotEntity.table)
    t.expect(columnConfigs->(Utils.magic: dict<Hasura.columnConfig> => JSON.t)).toEqual(
      %raw(`{
        "transaction_index": { "customName": "transactionIndex" },
        "token_owner_id": { "customName": "tokenOwner_id" }
      }`),
    )
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
    ~ecosystem=Evm,
    )
    let _ = await storage.initialize(
      ~contractMapping=config.contractMapping,
      ~entities=config.userEntities,
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
      ~setQueryCache=PgStorage.makeSetQueryCache(),
    )

    let rawRows = await sql->Postgres.unsafe(`SELECT * FROM "${pgSchema}"."Snapshot";`)
    let loadedByIds = await storage.loadOrThrow(
      ~filter=EntityFilter.In({
        fieldName: "id",
        fieldValue: ["1"]->(Utils.magic: array<string> => array<unknown>),
      }),
      ~table=snapshotEntity.table,
    )
    let loadedByField = await storage.loadOrThrow(
      ~filter=EntityFilter.Eq({
        fieldName: "transactionIndex",
        fieldValue: 5->(Utils.magic: int => unknown),
      }),
      ~table=snapshotEntity.table,
    )

    let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
    await storage.close()

    t.expect({
      "rawRows": rawRows->(Utils.magic: array<unknown> => JSON.t),
      "loadedByIds": loadedByIds->(Utils.magic: array<unknown> => array<snapshot>),
      "loadedByField": loadedByField->(Utils.magic: array<unknown> => array<snapshot>),
    }).toEqual({
      "rawRows": %raw(`[{ "id": "1", "transaction_index": 5, "token_owner_id": "user-1" }]`),
      "loadedByIds": [snapshot1],
      "loadedByField": [snapshot1],
    })
  })
})
