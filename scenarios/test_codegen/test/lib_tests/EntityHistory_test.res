open RescriptMocha

//unsafe polymorphic toString binding for any type
@send external toStringUnsafe: 'a => string = "toString"

// These are mandatory tables that must be created for every Envio-managed schema.
// The event_sync_state table is used to distinguish Envio-controlled schemas from others.
let generalTables = [TablesStatic.EventSyncState.table]

let stripUndefinedFieldsInPlace = (val: 'a): 'a => {
  let json = val->(Utils.magic: 'a => Js.Json.t)
  //Hot fix for rescript equality check that removes optional fields
  let rec strip = (json: Js.Json.t) => {
    switch json {
    | Object(obj) =>
      obj
      ->Js.Dict.keys
      ->Belt.Array.forEach(key => {
        let value = obj->Utils.Dict.dangerouslyGetNonOption(key)
        if value === %raw(`undefined`) {
          obj->Utils.Dict.deleteInPlace(key)
        } else {
          strip(value->Belt.Option.getExn)
        }
      })
    | Array(arr) => arr->Belt.Array.forEach(value => strip(value))
    | _ => ()
    }
  }

  json->strip
  json->(Utils.magic: Js.Json.t => 'a)
}

module TestEntity = {
  type t = {
    id: string,
    fieldA: int,
    fieldB: option<string>,
  }

  let name = "TestEntity"->(Utils.magic: string => Enums.EntityType.t)
  let schema = S.schema(s => {
    id: s.matches(S.string),
    fieldA: s.matches(S.int),
    fieldB: s.matches(S.null(S.string)),
  })

  let rowsSchema = S.array(schema)
  let table = Table.mkTable(
    "TestEntity",
    ~fields=[
      Table.mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey=true),
      Table.mkField("fieldA", Integer, ~fieldSchema=S.int),
      Table.mkField("fieldB", Text, ~fieldSchema=S.null(S.string), ~isNullable=true),
    ],
  )

  let entityHistory = table->EntityHistory.fromTable(~pgSchema="public", ~schema)

  external castToInternal: t => Internal.entity = "%identity"
}

type testEntityHistory = EntityHistory.historyRow<TestEntity.t>
let testEntityHistorySchema = EntityHistory.makeHistoryRowSchema(TestEntity.schema)

let batchSetMockEntity = (sql, items) =>
  PgStorage.setOrThrow(
    sql,
    ~items,
    ~pgSchema="public",
    ~table=TestEntity.table,
    ~itemSchema=TestEntity.schema,
  )

let getAllMockEntity = sql =>
  sql
  ->Postgres.unsafe(`SELECT * FROM "public"."${TestEntity.table.tableName}"`)
  ->Promise.thenResolve(json => json->S.parseJsonOrThrow(TestEntity.rowsSchema))

let getAllMockEntityHistory = sql =>
  sql->Postgres.unsafe(`SELECT * FROM "public"."${TestEntity.entityHistory.table.tableName}"`)

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
      entityData: Set({id: "1", fieldA: 1, fieldB: Some("test")}),
    }

    let serializedHistory = history->S.reverseConvertToJsonOrThrow(testEntityHistorySchema)
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
      "fieldB": "test",
      "action": "SET"
    }`)

    Assert.deepEqual(serializedHistory, expected)
    let deserializedHistory = serializedHistory->S.parseJsonOrThrow(testEntityHistorySchema)
    Assert.deepEqual(deserializedHistory->stripUndefinedFieldsInPlace, history)
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
      entityData: Set({id: "1", fieldA: 1, fieldB: Some("test")}),
    }
    let serializedHistory = history->S.reverseConvertToJsonOrThrow(testEntityHistorySchema)
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
      "fieldB": "test",
      "action": "SET"
    }`)

    Assert.deepEqual(serializedHistory, expected)
    let deserializedHistory = serializedHistory->S.parseJsonOrThrow(testEntityHistorySchema)
    Assert.deepEqual(deserializedHistory, history)
  })

  it("serializes and deserializes correctly with deleted entity", () => {
    let history: testEntityHistory = {
      current: {
        chain_id: 1,
        block_number: 2,
        block_timestamp: 3,
        log_index: 4,
      },
      previous: None,
      entityData: Delete({id: "1"}),
    }
    let serializedHistory = history->S.reverseConvertToJsonOrThrow(testEntityHistorySchema)
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
      "fieldA": null,
      "fieldB":null,
      "action": "DELETE"
    }`)

    Assert.deepEqual(serializedHistory, expected)
  })
})

describe("Entity History Codegen", () => {
  it("Creates a postgres insert function", () => {
    let expected = `CREATE OR REPLACE FUNCTION "insert_TestEntity_history"(history_row "public"."TestEntity_history", should_copy_current_entity BOOLEAN)
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
            ElSIF should_copy_current_entity THEN
            -- Check if a value for the id exists in the origin table and if so, insert a history row for it.
            SELECT "id", "fieldA", "fieldB" FROM "public"."TestEntity" WHERE id = history_row.id INTO v_origin_record;
            IF FOUND THEN
              INSERT INTO "public"."TestEntity_history" (entity_history_block_timestamp, entity_history_chain_id, entity_history_block_number, entity_history_log_index, "id", "fieldA", "fieldB", "action")
              -- SET the current change data fields to 0 since we don't know what they were
              -- and it doesn't matter provided they are less than any new values
              VALUES (0, 0, 0, 0, v_origin_record."id", v_origin_record."fieldA", v_origin_record."fieldB", 'SET');

              history_row.previous_entity_history_block_timestamp := 0; history_row.previous_entity_history_chain_id := 0; history_row.previous_entity_history_block_number := 0; history_row.previous_entity_history_log_index := 0;
            END IF;
          END IF;
        END IF;

        INSERT INTO "public"."TestEntity_history" ("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "previous_entity_history_block_timestamp", "previous_entity_history_chain_id", "previous_entity_history_block_number", "previous_entity_history_log_index", "id", "fieldA", "fieldB", "action")
        VALUES (history_row."entity_history_block_timestamp", history_row."entity_history_chain_id", history_row."entity_history_block_number", history_row."entity_history_log_index", history_row."previous_entity_history_block_timestamp", history_row."previous_entity_history_chain_id", history_row."previous_entity_history_block_number", history_row."previous_entity_history_log_index", history_row."id", history_row."fieldA", history_row."fieldB", history_row."action");
      END;
      $$ LANGUAGE plpgsql;
      `

    Assert.equal(expected, TestEntity.entityHistory.createInsertFnQuery)
  })
  it("Creates an entity history table", () => {
    let createQuery =
      TestEntity.entityHistory.table->PgStorage.makeCreateTableQuery(~pgSchema="public")
    Assert.equal(
      `CREATE TABLE IF NOT EXISTS "public"."TestEntity_history"("entity_history_block_timestamp" INTEGER NOT NULL, "entity_history_chain_id" INTEGER NOT NULL, "entity_history_block_number" INTEGER NOT NULL, "entity_history_log_index" INTEGER NOT NULL, "previous_entity_history_block_timestamp" INTEGER, "previous_entity_history_chain_id" INTEGER, "previous_entity_history_block_number" INTEGER, "previous_entity_history_log_index" INTEGER, "id" TEXT NOT NULL, "fieldA" INTEGER, "fieldB" TEXT, "action" "public".ENTITY_HISTORY_ROW_ACTION NOT NULL, "serial" SERIAL, PRIMARY KEY("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "id"));`,
      createQuery,
    )
  })

  it("Creates a js insert function", () => {
    let insertFnString = TestEntity.entityHistory.insertFn->toStringUnsafe

    let expected = `(sql, rowArgs, shouldCopyCurrentEntity) =>
      sql\`select "insert_TestEntity_history"(ROW(\${rowArgs["entity_history_block_timestamp"]}, \${rowArgs["entity_history_chain_id"]}, \${rowArgs["entity_history_block_number"]}, \${rowArgs["entity_history_log_index"]}, \${rowArgs["previous_entity_history_block_timestamp"]}, \${rowArgs["previous_entity_history_chain_id"]}, \${rowArgs["previous_entity_history_block_number"]}, \${rowArgs["previous_entity_history_log_index"]}, \${rowArgs["id"]}, \${rowArgs["fieldA"]}, \${rowArgs["fieldB"]}, \${rowArgs["action"]}, NULL),  --NULL argument for SERIAL field
    \${shouldCopyCurrentEntity});\``

    Assert.equal(insertFnString, expected)
  })

  Async.it("Creating tables and functions works", async () => {
    let storage = PgStorage.make(~sql=Db.sql, ~pgSchema="public", ~pgUser="postgres")
    try {
      await storage.initialize(
        ~entities=[module(TestEntity)->Entities.entityModToInternal],
        ~generalTables,
        ~enums=[Persistence.entityHistoryActionEnumConfig->Internal.fromGenericEnumConfig],
      )
    } catch {
    | exn =>
      Js.log2("Setup exn", exn)
      Assert.fail("Failed setting up tables")
    }

    switch await Db.sql->Postgres.unsafe(TestEntity.entityHistory.createInsertFnQuery) {
    | exception exn =>
      Js.log2("createInsertFnQuery exn", exn)
      Assert.fail("Failed creating insert function")
    | _ => ()
    }

    let mockEntity: TestEntity.t = {id: "1", fieldA: 1, fieldB: Some("test")}
    switch await Db.sql->batchSetMockEntity([mockEntity]) {
    | exception exn =>
      Js.log2("batchSetMockEntity exn", exn)
      Assert.fail("Failed to set mock entity in table")
    | _ => ()
    }
    let afterInsert = switch await Db.sql->getAllMockEntity {
    | exception exn =>
      Js.log2("getAllMockEntity exn", exn)
      Assert.fail("Failed to get mock entity from table")->Utils.magic
    | entities => entities
    }

    Assert.deepEqual(afterInsert, [mockEntity], ~message="Should have inserted mock entity")

    let chainId = 137
    let blockNumber = 123456
    let blockTimestamp = blockNumber * 15
    let logIndex = 1

    let entityHistoryItem: testEntityHistory = {
      current: {
        chain_id: chainId,
        block_timestamp: blockTimestamp,
        block_number: blockNumber,
        log_index: logIndex,
      },
      previous: None,
      entityData: Set({
        id: "1",
        fieldA: 2,
        fieldB: Some("test2"),
      }),
    }

    switch await TestEntity.entityHistory->EntityHistory.insertRow(
      ~sql=Db.sql,
      ~historyRow=entityHistoryItem,
      ~shouldCopyCurrentEntity=true,
    ) {
    | exception exn =>
      Js.log2("insertRow exn", exn)
      Assert.fail("Failed to insert mock entity history")
    | _ => ()
    }

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
        "action": "SET",
        "serial": 1,
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
        "action": "SET",
        "serial": 2,
      },
    ]

    let currentHistoryItems = await Db.sql->getAllMockEntityHistory
    Assert.deepEqual(currentHistoryItems, expectedResult)

    switch await TestEntity.entityHistory->EntityHistory.insertRow(
      ~sql=Db.sql,
      ~historyRow={
        entityData: Set({id: "2", fieldA: 1, fieldB: None}),
        previous: None,
        current: {
          chain_id: 1,
          block_timestamp: 4,
          block_number: 4,
          log_index: 6,
        },
      },
      ~shouldCopyCurrentEntity=true,
    ) {
    | exception exn =>
      Js.log2("insertRow exn", exn)
      Assert.fail("Failed to insert mock entity history")
    | _ => ()
    }
    switch await TestEntity.entityHistory->EntityHistory.insertRow(
      ~sql=Db.sql,
      ~historyRow={
        entityData: Set({id: "2", fieldA: 3, fieldB: None}),
        previous: None,
        current: {
          chain_id: 1,
          block_timestamp: 4,
          block_number: 10,
          log_index: 6,
        },
      },
      ~shouldCopyCurrentEntity=true,
    ) {
    | exception exn =>
      Js.log2("insertRow exn", exn)
      Assert.fail("Failed to insert mock entity history")
    | _ => ()
    }

    await TestEntity.entityHistory->EntityHistory.insertRow(
      ~sql=Db.sql,
      ~historyRow={
        entityData: Set({id: "3", fieldA: 4, fieldB: None}),
        previous: None,
        current: {
          chain_id: 137,
          block_timestamp: 4,
          block_number: 7,
          log_index: 6,
        },
      },
      ~shouldCopyCurrentEntity=true,
    )
  })
})

module Mocks = {
  module Entity = {
    open TestEntity
    let entityId1 = "1"
    let mockEntity1 = {id: entityId1, fieldA: 1, fieldB: Some("test")}
    let mockEntity2 = {id: entityId1, fieldA: 2, fieldB: Some("test2")}
    let mockEntity3 = {id: entityId1, fieldA: 3, fieldB: Some("test3")}
    let mockEntity4 = {id: entityId1, fieldA: 4, fieldB: Some("test4")}

    let entityId2 = "2"
    let mockEntity5 = {id: entityId2, fieldA: 5, fieldB: None}
    let mockEntity6 = {id: entityId2, fieldA: 6, fieldB: None}

    let entityId3 = "3"
    let mockEntity7 = {id: entityId3, fieldA: 7, fieldB: None}
    let mockEntity8 = {id: entityId3, fieldA: 8, fieldB: None}
  }

  module GnosisBug = {
    let chain_id = 1

    let event1: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 10 * 5,
      block_number: 10,
      log_index: 0,
    }

    let event2: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 10 * 5,
      block_number: 10,
      log_index: 1,
    }

    let historyRow1: testEntityHistory = {
      current: event1,
      previous: None,
      entityData: Set(Entity.mockEntity2),
    }

    let historyRow2: testEntityHistory = {
      current: event2,
      previous: None,
      entityData: Set(Entity.mockEntity6),
    }

    let historyRows = [historyRow1, historyRow2]

    // For setting a different entity and testing pruning
    let event3: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 12 * 5,
      block_number: 12,
      log_index: 0,
    }

    let historyRow3: testEntityHistory = {
      current: event3,
      previous: None,
      entityData: Set(Entity.mockEntity3),
    }

    let historyRow4: testEntityHistory = {
      current: event3,
      previous: None,
      entityData: Set(Entity.mockEntity8),
    }

    let historyRowsForPrune = [historyRow3, historyRow4]
  }

  module Chain1 = {
    let chain_id = 1

    let event1: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 1,
      block_number: 1,
      log_index: 0,
    }

    let event2: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 5,
      block_number: 2,
      log_index: 1,
    }

    let event3: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 15,
      block_number: 4,
      log_index: 2,
    }

    let historyRow1: testEntityHistory = {
      current: event1,
      previous: None,
      entityData: Set(Entity.mockEntity1),
    }

    let historyRow2: testEntityHistory = {
      current: event2,
      previous: Some(event1),
      entityData: Set(Entity.mockEntity2),
    }

    let historyRow3: testEntityHistory = {
      current: event3,
      previous: Some(event2),
      entityData: Set(Entity.mockEntity3),
    }

    let historyRows = [historyRow1, historyRow2, historyRow3]

    //Shows a case where no event exists on this block
    let rollbackEventIdentifier: Types.eventIdentifier = {
      blockTimestamp: 10,
      chainId: chain_id,
      blockNumber: 3,
      logIndex: 0,
    }

    let orderedMultichainArg = DbFunctions.EntityHistory.Args.OrderedMultichain({
      safeBlockTimestamp: rollbackEventIdentifier.blockTimestamp,
      reorgChainId: chain_id,
      safeBlockNumber: rollbackEventIdentifier.blockNumber,
    })

    let unorderedMultichainArg = DbFunctions.EntityHistory.Args.UnorderedMultichain({
      reorgChainId: chain_id,
      safeBlockNumber: rollbackEventIdentifier.blockNumber,
    })
  }

  module Chain2 = {
    let chain_id = 2

    let event1: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 3,
      block_number: 1,
      log_index: 0,
    }

    let event2: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 8,
      block_number: 2,
      log_index: 1,
    }

    let event3: EntityHistory.historyFields = {
      chain_id,
      block_timestamp: 13,
      block_number: 3,
      log_index: 2,
    }

    let historyRow1: testEntityHistory = {
      current: event1,
      previous: None,
      entityData: Set(Entity.mockEntity5),
    }

    let historyRow2: testEntityHistory = {
      current: event2,
      previous: Some(event1),
      entityData: Delete({id: Entity.entityId2}),
    }
    let historyRow3: testEntityHistory = {
      current: event3,
      previous: Some(event2),
      entityData: Set(Entity.mockEntity6),
    }

    let historyRows = [historyRow1, historyRow2, historyRow3]
  }

  let historyRows = Utils.Array.mergeSorted(
    (a, b) => a.EntityHistory.current.block_timestamp < b.current.block_timestamp,
    Chain1.historyRows,
    Chain2.historyRows,
  )
}

describe("Entity history rollbacks", () => {
  Async.beforeEach(async () => {
    try {
      let _ = DbHelpers.resetPostgresClient()
      let storage = PgStorage.make(~sql=Db.sql, ~pgSchema="public", ~pgUser="postgres")
      await storage.initialize(
        ~entities=[module(TestEntity)->Entities.entityModToInternal],
        ~generalTables,
        ~enums=[Persistence.entityHistoryActionEnumConfig->Internal.fromGenericEnumConfig],
      )

      let _ = await Db.sql->Postgres.unsafe(TestEntity.entityHistory.createInsertFnQuery)

      try await Db.sql->PgStorage.setOrThrow(
        ~items=[
          Mocks.Entity.mockEntity1->TestEntity.castToInternal,
          Mocks.Entity.mockEntity5->TestEntity.castToInternal,
        ],
        ~table=TestEntity.table,
        ~itemSchema=TestEntity.schema,
        ~pgSchema=Config.storagePgSchema,
      ) catch {
      | exn =>
        Js.log2("batchSet mock entity exn", exn)
        Assert.fail("Failed to set mock entity in table")
      }

      try await Db.sql->Postgres.beginSql(
        sql => [
          TestEntity.entityHistory->EntityHistory.batchInsertRows(
            ~sql,
            ~rows=Mocks.GnosisBug.historyRows,
          ),
        ],
      ) catch {
      | exn =>
        Js.log2("insert mock rows exn", exn)
        Assert.fail("Failed to insert mock rows")
      }

      let historyItems = {
        let items = await Db.sql->getAllMockEntityHistory
        items->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)
      }
      Assert.equal(historyItems->Js.Array2.length, 4, ~message="Should have 4 history items")
      Assert.ok(
        historyItems->Belt.Array.some(item => item.current.chain_id == 0),
        ~message="Should contain 2 copied items",
      )
    } catch {
    | exn =>
      Js.log2(" Entity history setup exn", exn)
      Assert.fail("Failed setting up tables")
    }
  })

  Async.it("Rollback ignores copied entities as an item in reorg threshold", async () => {
    let rollbackDiff = await Db.sql->DbFunctions.EntityHistory.getRollbackDiff(
      OrderedMultichain({
        reorgChainId: Mocks.GnosisBug.chain_id,
        safeBlockNumber: 9,
        safeBlockTimestamp: 9 * 5,
      }),
      ~entityConfig=module(TestEntity)->Entities.entityModToInternal,
    )

    let expectedDiff: array<EntityHistory.historyRow<Internal.entity>> = [
      {
        current: {chain_id: 0, block_timestamp: 0, block_number: 0, log_index: 0},
        previous: %raw(`undefined`),
        entityData: Set(Mocks.Entity.mockEntity1->TestEntity.castToInternal),
      },
      {
        current: {chain_id: 0, block_timestamp: 0, block_number: 0, log_index: 0},
        previous: %raw(`undefined`),
        entityData: Set(Mocks.Entity.mockEntity5->TestEntity.castToInternal),
      },
    ]

    Assert.deepStrictEqual(
      rollbackDiff,
      expectedDiff,
      ~message="Should rollback to the copied entity",
    )
  })

  Async.it(
    "Deleting items after reorg event should not remove the copied history item",
    async () => {
      await Db.sql->DbFunctions.EntityHistory.deleteAllEntityHistoryAfterEventIdentifier(
        ~isUnorderedMultichainMode=false,
        ~eventIdentifier={
          chainId: Mocks.GnosisBug.chain_id,
          blockTimestamp: 9 * 5,
          blockNumber: 9,
          logIndex: 0,
        },
        ~allEntities=[module(TestEntity)->Entities.entityModToInternal],
      )

      let historyItems = {
        let items = await Db.sql->getAllMockEntityHistory
        items->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)
      }

      Assert.equal(historyItems->Js.Array2.length, 2, ~message="Should have the 2 copied items")

      let allItemsAreZeroChainId =
        historyItems->Belt.Array.every(item => item.current.chain_id == 0)

      Assert.ok(
        allItemsAreZeroChainId,
        ~message="Should have all items in the zero chain id since they are copied",
      )
    },
  )

  Async.it("Prunes history correctly with items in reorg threshold", async () => {
    // set the current entity of id 3
    await Db.sql->PgStorage.setOrThrow(
      ~items=[Mocks.Entity.mockEntity7->TestEntity.castToInternal],
      ~table=TestEntity.table,
      ~itemSchema=TestEntity.schema,
      ~pgSchema=Config.storagePgSchema,
    )

    // set an updated version of its row to get a copied entity history
    try await Db.sql->Postgres.beginSql(
      sql => [
        TestEntity.entityHistory->EntityHistory.batchInsertRows(
          ~sql,
          ~rows=Mocks.GnosisBug.historyRowsForPrune,
        ),
      ],
    ) catch {
    | exn =>
      Js.log2("insert mock rows exn", exn)
      Assert.fail("Failed to insert mock rows")
    }

    // let historyItemsBefore = {
    //   let items = await Db.sql->getAllMockEntityHistory
    //   Js.log2("history items before prune", items)
    //   items->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)
    // }

    await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
      ~entityName=(module(TestEntity)->Entities.entityModToInternal).name,
      ~safeChainIdAndBlockNumberArray=[{chainId: Mocks.GnosisBug.chain_id, blockNumber: 11}],
      ~shouldDeepClean=true,
    )

    let historyItemsAfter = {
      let items = await Db.sql->getAllMockEntityHistory
      // Js.log2("history items after prune", items)
      items->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)
    }

    Assert.equal(
      historyItemsAfter->Js.Array2.length,
      4,
      ~message="Should have 4 history items for entity id 1 and 3 before and after block 11",
    )
  })
})

describe("Entity history rollbacks", () => {
  Async.beforeEach(async () => {
    try {
      let _ = DbHelpers.resetPostgresClient()
      let storage = PgStorage.make(~sql=Db.sql, ~pgSchema="public", ~pgUser="postgres")
      await storage.initialize(
        ~entities=[module(TestEntity)->Entities.entityModToInternal],
        ~generalTables,
        ~enums=[Persistence.entityHistoryActionEnumConfig->Internal.fromGenericEnumConfig],
      )

      let _ = await Db.sql->Postgres.unsafe(TestEntity.entityHistory.createInsertFnQuery)

      try await Db.sql->Postgres.beginSql(
        sql => [
          TestEntity.entityHistory->EntityHistory.batchInsertRows(~sql, ~rows=Mocks.historyRows),
        ],
      ) catch {
      | exn =>
        Js.log2("insert mock rows exn", exn)
        Assert.fail("Failed to insert mock rows")
      }

      let historyItems = {
        let items = await Db.sql->getAllMockEntityHistory
        items->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)
      }
      Assert.equal(historyItems->Js.Array2.length, 6, ~message="Should have 6 history items")
      Assert.ok(
        !(historyItems->Belt.Array.some(item => item.current.chain_id == 0)),
        ~message="No defaulted/copied values should exist in history",
      )
    } catch {
    | exn =>
      Js.log2(" Entity history setup exn", exn)
      Assert.fail("Failed setting up tables")
    }
  })

  Async.it("Returns expected diff for ordered multichain mode", async () => {
    let orderdMultichainRollbackDiff = try await Db.sql->DbFunctions.EntityHistory.getRollbackDiff(
      Mocks.Chain1.orderedMultichainArg,
      ~entityConfig=module(TestEntity)->Entities.entityModToInternal,
    ) catch {
    | exn =>
      Js.log2("getRollbackDiff exn", exn)
      Assert.fail("Failed to get rollback diff")
    }

    switch orderdMultichainRollbackDiff {
    | [
        {current: currentA, entityData: Set(entitySetA)},
        {current: currentB, entityData: Delete({id: entityDeleteB})},
      ] =>
      Assert.deepEqual(
        currentA,
        Mocks.Chain1.event2,
        ~message="First history item should haved diffed to event2",
      )
      Assert.deepEqual(
        entitySetA,
        Mocks.Entity.mockEntity2->TestEntity.castToInternal,
        ~message="First history item should haved diffed to mockEntity2",
      )
      Assert.deepEqual(
        currentB,
        Mocks.Chain2.event2,
        ~message="Second history item should haved diffed to event3",
      )
      Assert.deepEqual(
        entityDeleteB,
        Mocks.Entity.entityId2,
        ~message="Second history item should haved diffed a delete of entityId2",
      )
    | _ => Assert.fail("Should have a set and delete history item in diff")
    }
  })

  Async.it("Returns expected diff for unordered multichain mode", async () => {
    let unorderedMultichainRollbackDiff = try await Db.sql->DbFunctions.EntityHistory.getRollbackDiff(
      Mocks.Chain1.unorderedMultichainArg,
      ~entityConfig=module(TestEntity)->Entities.entityModToInternal,
    ) catch {
    | exn =>
      Js.log2("getRollbackDiff exn", exn)
      Assert.fail("Failed to get rollback diff")
    }

    switch unorderedMultichainRollbackDiff {
    | [{current: currentA, entityData: Set(entitySetA)}] =>
      Assert.deepEqual(
        currentA,
        Mocks.Chain1.event2,
        ~message="First history item should haved diffed to event2",
      )
      Assert.deepEqual(
        entitySetA,
        Mocks.Entity.mockEntity2->TestEntity.castToInternal,
        ~message="First history item should haved diffed to mockEntity2",
      )
    | _ => Assert.fail("Should have only chain 1 item in diff")
    }
  })

  Async.it("Gets first event change per chain ordered mode", async () => {
    let firstChangeEventPerChain = try await Db.sql->DbFunctions.EntityHistory.getFirstChangeEventPerChain(
      Mocks.Chain1.orderedMultichainArg,
      ~allEntities=[module(TestEntity)->Entities.entityModToInternal],
    ) catch {
    | exn =>
      Js.log2("getFirstChangeEventPerChain exn", exn)
      Assert.fail("Failed to get rollback diff")
    }

    let expected = DbFunctions.EntityHistory.FirstChangeEventPerChain.make()
    expected->DbFunctions.EntityHistory.FirstChangeEventPerChain.setIfEarlier(
      ~chainId=Mocks.Chain1.chain_id,
      ~event={
        blockNumber: Mocks.Chain1.event3.block_number,
        logIndex: Mocks.Chain1.event3.log_index,
      },
    )
    expected->DbFunctions.EntityHistory.FirstChangeEventPerChain.setIfEarlier(
      ~chainId=Mocks.Chain2.chain_id,
      ~event={
        blockNumber: Mocks.Chain2.event3.block_number,
        logIndex: Mocks.Chain2.event3.log_index,
      },
    )

    Assert.deepEqual(
      firstChangeEventPerChain,
      expected,
      ~message="Should have chain 1 and 2 first change events",
    )
  })

  Async.it("Gets first event change per chain unordered mode", async () => {
    let firstChangeEventPerChain = try await Db.sql->DbFunctions.EntityHistory.getFirstChangeEventPerChain(
      Mocks.Chain1.unorderedMultichainArg,
      ~allEntities=[module(TestEntity)->Entities.entityModToInternal],
    ) catch {
    | exn =>
      Js.log2("getFirstChangeEventPerChain exn", exn)
      Assert.fail("Failed to get rollback diff")
    }

    let expected = DbFunctions.EntityHistory.FirstChangeEventPerChain.make()
    expected->DbFunctions.EntityHistory.FirstChangeEventPerChain.setIfEarlier(
      ~chainId=Mocks.Chain1.chain_id,
      ~event={
        blockNumber: Mocks.Chain1.event3.block_number,
        logIndex: Mocks.Chain1.event3.log_index,
      },
    )

    Assert.deepEqual(
      firstChangeEventPerChain,
      expected,
      ~message="Should only have chain 1 first change event",
    )
  })

  Async.it("Deletes current history after rollback ordered", async () => {
    let _ =
      await Db.sql->DbFunctions.EntityHistory.deleteAllEntityHistoryAfterEventIdentifier(
        ~isUnorderedMultichainMode=false,
        ~eventIdentifier=Mocks.Chain1.rollbackEventIdentifier,
        ~allEntities=[module(TestEntity)->Entities.entityModToInternal],
      )

    let currentHistoryItems = await Db.sql->getAllMockEntityHistory
    let parsedHistoryItems =
      currentHistoryItems->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)

    let expectedHistoryItems = Mocks.historyRows->Belt.Array.slice(~offset=0, ~len=4)

    Assert.deepEqual(
      parsedHistoryItems->stripUndefinedFieldsInPlace,
      expectedHistoryItems->stripUndefinedFieldsInPlace,
      ~message="Should have deleted last 2 items in history",
    )
  })

  Async.it("Deletes current history after rollback unordered", async () => {
    let _ =
      await Db.sql->DbFunctions.EntityHistory.deleteAllEntityHistoryAfterEventIdentifier(
        ~isUnorderedMultichainMode=true,
        ~eventIdentifier=Mocks.Chain1.rollbackEventIdentifier,
        ~allEntities=[module(TestEntity)->Entities.entityModToInternal],
      )

    let currentHistoryItems = await Db.sql->getAllMockEntityHistory
    let parsedHistoryItems =
      currentHistoryItems->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)

    let expectedHistoryItems = Mocks.historyRows->Belt.Array.slice(~offset=0, ~len=5)

    Assert.deepEqual(
      parsedHistoryItems->stripUndefinedFieldsInPlace,
      expectedHistoryItems->stripUndefinedFieldsInPlace,
      ~message="Should have deleted just the last item in history",
    )
  })

  Async.it("Prunes history correctly with items in reorg threshold", async () => {
    await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
      ~entityName=(module(TestEntity)->Entities.entityModToInternal).name,
      ~safeChainIdAndBlockNumberArray=[{chainId: 1, blockNumber: 3}, {chainId: 2, blockNumber: 2}],
      ~shouldDeepClean=true,
    )
    let currentHistoryItems = await Db.sql->getAllMockEntityHistory

    let parsedHistoryItems =
      currentHistoryItems->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)

    let expectedHistoryItems = [
      Mocks.Chain1.historyRow2,
      Mocks.Chain1.historyRow3,
      Mocks.Chain2.historyRow2,
      Mocks.Chain2.historyRow3,
    ]

    let sort = arr =>
      arr->Js.Array2.sortInPlaceWith(
        (a, b) => a.EntityHistory.current.block_number - b.current.block_number,
      )

    Assert.deepEqual(
      parsedHistoryItems->sort->stripUndefinedFieldsInPlace,
      expectedHistoryItems->sort->stripUndefinedFieldsInPlace,
      ~message="Should have deleted the unneeded first items in history",
    )
  })

  Async.it(
    "Deep clean prunes history correctly with items in reorg threshold without checking for stale history entities in threshold",
    async () => {
      await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
        ~entityName=(module(TestEntity)->Entities.entityModToInternal).name,
        ~safeChainIdAndBlockNumberArray=[
          {chainId: 1, blockNumber: 3},
          {chainId: 2, blockNumber: 2},
        ],
        ~shouldDeepClean=false,
      )
      let currentHistoryItems = await Db.sql->getAllMockEntityHistory

      let parsedHistoryItems =
        currentHistoryItems->S.parseJsonOrThrow(TestEntity.entityHistory.schemaRows)

      let sort = arr =>
        arr->Js.Array2.sortInPlaceWith(
          (a, b) => a.EntityHistory.current.block_number - b.current.block_number,
        )

      Assert.deepEqual(
        parsedHistoryItems->sort->stripUndefinedFieldsInPlace,
        Mocks.historyRows,
        ~message="Should have deleted the unneeded first items in history",
      )
    },
  )
  Async.it("Prunes history correctly with no items in reorg threshold", async () => {
    await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
      ~entityName=(module(TestEntity)->Entities.entityModToInternal).name,
      ~safeChainIdAndBlockNumberArray=[{chainId: 1, blockNumber: 4}, {chainId: 2, blockNumber: 3}],
      ~shouldDeepClean=true,
    )
    let currentHistoryItems = await Db.sql->getAllMockEntityHistory

    Assert.ok(
      currentHistoryItems->Array.length == 0,
      ~message="Should have deleted all items in history",
    )
  })
})

describe_skip("Prune performance test", () => {
  Async.it("Print benchmark of prune function", async () => {
    let _ = DbHelpers.resetPostgresClient()
    let storage = PgStorage.make(~sql=Db.sql, ~pgSchema="public", ~pgUser="postgres")
    await storage.initialize(
      ~entities=[module(TestEntity)->Entities.entityModToInternal],
      ~generalTables,
      ~enums=[Persistence.entityHistoryActionEnumConfig->Internal.fromGenericEnumConfig],
    )

    let _ = await Db.sql->Postgres.unsafe(TestEntity.entityHistory.createInsertFnQuery)

    let rows: array<testEntityHistory> = []
    for i in 0 to 1000 {
      let mockEntity: TestEntity.t = {
        id: i->mod(10)->Belt.Int.toString,
        fieldA: i,
        fieldB: None,
      }

      let historyRow: testEntityHistory = {
        current: {
          chain_id: 1,
          block_timestamp: i * 5,
          block_number: i,
          log_index: 0,
        },
        previous: None,
        entityData: Set(mockEntity),
      }
      rows->Js.Array2.push(historyRow)->ignore
    }

    try await Db.sql->Postgres.beginSql(
      sql => [TestEntity.entityHistory->EntityHistory.batchInsertRows(~sql, ~rows)],
    ) catch {
    | exn =>
      Js.log2("insert mock rows exn", exn)
      Assert.fail("Failed to insert mock rows")
    }

    let startTime = Hrtime.makeTimer()

    try await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
      ~entityName=(module(TestEntity)->Entities.entityModToInternal).name,
      ~safeChainIdAndBlockNumberArray=[{chainId: 1, blockNumber: 500}],
      ~shouldDeepClean=false,
    ) catch {
    | exn =>
      Js.log2("prune stale entity history exn", exn)
      Assert.fail("Failed to prune stale entity history")
    }

    let elapsedTime = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.intFromMillis
    Js.log2("Elapsed time", elapsedTime)
  })
})
