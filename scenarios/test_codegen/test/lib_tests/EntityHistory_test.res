open RescriptMocha

//unsafe polymorphic toString binding for any type
@send external toStringUnsafe: 'a => string = "toString"

type testEntity = {
  id: string,
  fieldA: int,
  fieldB: option<string>,
}

let testEntitySchema: S.t<testEntity> = S.schema(s => {
  id: s.matches(S.string),
  fieldA: s.matches(S.int),
  fieldB: s.matches(S.option(S.string)),
})

let testEntityRowsSchema = S.array(testEntitySchema)

type testEntityHistory = EntityHistory.historyRow<testEntity>
let testEntityHistorySchema = EntityHistory.makeHistoryRowSchema(testEntitySchema)

let mockEntityTable = Table.mkTable(
  "TestEntity",
  ~fields=[
    Table.mkField("id", Text, ~isPrimaryKey=true),
    Table.mkField("fieldA", Integer),
    Table.mkField("fieldB", Text, ~isNullable=true),
  ],
)

let mockEntityHistory = mockEntityTable->EntityHistory.fromTable(~schema=testEntitySchema)

let batchSetMockEntity = Table.PostgresInterop.makeBatchSetFn(
  ~table=mockEntityTable,
  ~rowsSchema=testEntityRowsSchema,
)

let getAllMockEntity = sql =>
  sql
  ->Postgres.unsafe(`SELECT * FROM "public"."${mockEntityTable.tableName}"`)
  ->Promise.thenResolve(json => json->S.parseOrRaiseWith(testEntityRowsSchema))

let getAllMockEntityHistory = sql =>
  sql->Postgres.unsafe(`SELECT * FROM "public"."${mockEntityHistory.table.tableName}"`)

describe("Entity history serde", () => {
  it("serializes and deserializes correctly", () => {
    let history: testEntityHistory = {
      current: {
        chain_id: 1,
        block_number: 2,
        block_timestamp: 3,
        log_index: 4,
      },
      previous: None,
      entityData: {id: "1", fieldA: 1, fieldB: Some("test")},
    }

    let serializedHistory = history->S.serializeOrRaiseWith(testEntityHistorySchema)
    let expected = %raw(`{
      "entity_history_block_timestamp": 3,
      "entity_history_chain_id": 1,
      "entity_history_block_number": 2,
      "entity_history_log_index": 4,
      "previous_entity_history_block_timestamp": null,
      "previous_entity_history_chain_id": null,
      "previous_entity_history_block_number": null,
      "previous_entity_history_log_index": null,
      "id": "1",
      "fieldA": 1,
      "fieldB": "test"
    }`)

    Assert.deepEqual(serializedHistory, expected)
    let deserializedHistory = serializedHistory->S.parseOrRaiseWith(testEntityHistorySchema)
    Assert.deepEqual(deserializedHistory, history)
  })

  it("serializes and deserializes correctly with previous history", () => {
    let history: testEntityHistory = {
      current: {
        chain_id: 1,
        block_number: 2,
        block_timestamp: 3,
        log_index: 4,
      },
      previous: Some({
        chain_id: 5,
        block_number: 6,
        block_timestamp: 7,
        log_index: 8,
      }), //previous
      entityData: {id: "1", fieldA: 1, fieldB: Some("test")},
    }
    let serializedHistory = history->S.serializeOrRaiseWith(testEntityHistorySchema)
    let expected = %raw(`{
      "entity_history_block_timestamp": 3,
      "entity_history_chain_id": 1,
      "entity_history_block_number": 2,
      "entity_history_log_index": 4,
      "previous_entity_history_block_timestamp": 7,
      "previous_entity_history_chain_id": 5,
      "previous_entity_history_block_number": 6,                            
      "previous_entity_history_log_index": 8,
      "id": "1",
      "fieldA": 1,
      "fieldB": "test"
    }`)

    Assert.deepEqual(serializedHistory, expected)
    let deserializedHistory = serializedHistory->S.parseOrRaiseWith(testEntityHistorySchema)
    Assert.deepEqual(deserializedHistory, history)
  })
})

describe("Entity History Codegen", () => {
  it("Creates a postgres insert function", () => {
    let expected = `CREATE OR REPLACE FUNCTION "insert_TestEntity_history"(history_row "public"."TestEntity_history")
      RETURNS void AS $$
      DECLARE
        v_previous_record RECORD;
        v_origin_record RECORD;
      BEGIN
        -- Check if previous values are not provided
        IF history_row.previous_entity_history_block_timestamp IS NULL OR history_row.previous_entity_history_chain_id IS NULL OR history_row.previous_entity_history_block_number IS NULL OR history_row.previous_entity_history_log_index IS NULL THEN
          -- Find the most recent record for the same id
          SELECT entity_history_block_timestamp, entity_history_chain_id, entity_history_block_number, entity_history_log_index INTO v_previous_record
          FROM "public"."TestEntity_history"
          WHERE id = history_row.id
          ORDER BY entity_history_block_timestamp DESC, entity_history_chain_id DESC, entity_history_block_number DESC, entity_history_log_index DESC
          LIMIT 1;

          -- If a previous record exists, use its values
          IF FOUND THEN
            history_row.previous_entity_history_block_timestamp := v_previous_record.entity_history_block_timestamp; history_row.previous_entity_history_chain_id := v_previous_record.entity_history_chain_id; history_row.previous_entity_history_block_number := v_previous_record.entity_history_block_number; history_row.previous_entity_history_log_index := v_previous_record.entity_history_log_index;
            ElSE
            -- Check if a value for the id exists in the origin table and if so, insert a history row for it.
            SELECT "id", "fieldA", "fieldB" FROM "public"."TestEntity" WHERE id = history_row.id INTO v_origin_record;
            IF FOUND THEN
              INSERT INTO "public"."TestEntity_history" (entity_history_block_timestamp, entity_history_chain_id, entity_history_block_number, entity_history_log_index, "id", "fieldA", "fieldB")
              -- SET the current change data fields to 0 since we don't know what they were
              -- and it doesn't matter provided they are less than any new values
              VALUES (0, 0, 0, 0, v_origin_record."id", v_origin_record."fieldA", v_origin_record."fieldB");

              history_row.previous_entity_history_block_timestamp := 0; history_row.previous_entity_history_chain_id := 0; history_row.previous_entity_history_block_number := 0; history_row.previous_entity_history_log_index := 0;
            END IF;
          END IF;
        END IF;

        INSERT INTO "public"."TestEntity_history" ("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "previous_entity_history_block_timestamp", "previous_entity_history_chain_id", "previous_entity_history_block_number", "previous_entity_history_log_index", "id", "fieldA", "fieldB")
        VALUES (history_row."entity_history_block_timestamp", history_row."entity_history_chain_id", history_row."entity_history_block_number", history_row."entity_history_log_index", history_row."previous_entity_history_block_timestamp", history_row."previous_entity_history_chain_id", history_row."previous_entity_history_block_number", history_row."previous_entity_history_log_index", history_row."id", history_row."fieldA", history_row."fieldB");
      END;
      $$ LANGUAGE plpgsql;
      `

    Assert.equal(expected, mockEntityHistory.createInsertFnQuery)
  })

  it("Creates a js insert function", () => {
    let insertFnString = mockEntityHistory.insertFn->toStringUnsafe

    let expected = `(sql, rowArgs) =>
      sql\`select "insert_TestEntity_history"(ROW(\${rowArgs["entity_history_block_timestamp"]}, \${rowArgs["entity_history_chain_id"]}, \${rowArgs["entity_history_block_number"]}, \${rowArgs["entity_history_log_index"]}, \${rowArgs["previous_entity_history_block_timestamp"]}, \${rowArgs["previous_entity_history_chain_id"]}, \${rowArgs["previous_entity_history_block_number"]}, \${rowArgs["previous_entity_history_log_index"]}, \${rowArgs["id"]}, \${rowArgs["fieldA"]}, \${rowArgs["fieldB"]}));\``

    Assert.equal(expected, insertFnString)
  })

  Async.it("Creating tables and functions works", async () => {
    let _ = await Migrations.runDownMigrations(~shouldExit=false)
    let _resA = await Migrations.creatTableIfNotExists(DbFunctions.sql, mockEntityTable)
    let _resB = await Migrations.creatTableIfNotExists(DbFunctions.sql, mockEntityHistory.table)
    let _createFn = await DbFunctions.sql->Postgres.unsafe(mockEntityHistory.createInsertFnQuery)

    // let res = await DbFunctions.sql->Postgres.unsafe(``)
    let mockEntity = {id: "1", fieldA: 1, fieldB: Some("test")}
    await DbFunctions.sql->batchSetMockEntity([mockEntity])
    let afterInsert = await DbFunctions.sql->getAllMockEntity
    Assert.deepEqual(afterInsert, [mockEntity])

    let chainId = 137
    let blockNumber = 123456
    let blockTimestamp = blockNumber * 15
    let logIndex = 1

    let entityHistoryItem: EntityHistory.historyRow<testEntity> = {
      current: {
        chain_id: chainId,
        block_timestamp: blockTimestamp,
        block_number: blockNumber,
        log_index: logIndex,
      },
      previous: None,
      entityData: {
        id: "1",
        fieldA: 2,
        fieldB: Some("test2"),
      },
    }

    let _callRes =
      await mockEntityHistory->EntityHistory.insertRow(
        ~sql=DbFunctions.sql,
        ~historyRow=entityHistoryItem,
      )

    // let _callRes = await DbFunctions.sql->call(entityHistoryItem)

    let expectedResult = [
      {
        "entity_history_block_timestamp": 0,
        "entity_history_chain_id": 0,
        "entity_history_block_number": 0,
        "entity_history_log_index": 0,
        "previous_entity_history_block_timestamp": Js.Nullable.Null,
        "previous_entity_history_chain_id": Js.Nullable.Null,
        "previous_entity_history_block_number": Js.Nullable.Null,
        "previous_entity_history_log_index": Js.Nullable.Null,
        "id": "1",
        "fieldA": 1,
        "fieldB": "test",
      },
      {
        "entity_history_block_timestamp": blockTimestamp,
        "entity_history_chain_id": chainId,
        "entity_history_block_number": blockNumber,
        "entity_history_log_index": logIndex,
        "previous_entity_history_block_timestamp": Js.Nullable.Value(0),
        "previous_entity_history_chain_id": Js.Nullable.Value(0),
        "previous_entity_history_block_number": Js.Nullable.Value(0),
        "previous_entity_history_log_index": Js.Nullable.Value(0),
        "id": "1",
        "fieldA": 2,
        "fieldB": "test2",
      },
    ]

    let currentHistoryItems = await DbFunctions.sql->getAllMockEntityHistory
    Assert.deepEqual(currentHistoryItems, expectedResult)
  })
})
