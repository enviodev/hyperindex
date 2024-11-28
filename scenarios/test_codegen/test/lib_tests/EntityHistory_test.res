open RescriptMocha

//unsafe polymorphic toString binding for any type
@send external toStringUnsafe: 'a => string = "toString"

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
    fieldB: s.matches(S.option(S.string)),
  })

  let rowsSchema = S.array(schema)
  let table = Table.mkTable(
    "TestEntity",
    ~fields=[
      Table.mkField("id", Text, ~isPrimaryKey=true),
      Table.mkField("fieldA", Integer),
      Table.mkField("fieldB", Text, ~isNullable=true),
    ],
  )

  let entityHistory = table->EntityHistory.fromTable(~schema)
}

type testEntityHistory = EntityHistory.historyRow<TestEntity.t>
let testEntityHistorySchema = EntityHistory.makeHistoryRowSchema(TestEntity.schema)

let batchSetMockEntity = Table.PostgresInterop.makeBatchSetFn(
  ~table=TestEntity.table,
  ~rowsSchema=TestEntity.rowsSchema,
)

let getAllMockEntity = sql =>
  sql
  ->Postgres.unsafe(`SELECT * FROM "public"."${TestEntity.table.tableName}"`)
  ->Promise.thenResolve(json => json->S.parseOrRaiseWith(TestEntity.rowsSchema))

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
      "fieldB": "test",
      "action": "SET"
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
      entityData: Set({id: "1", fieldA: 1, fieldB: Some("test")}),
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
      "fieldB": "test",
      "action": "SET"
    }`)

    Assert.deepEqual(serializedHistory, expected)
    let deserializedHistory = serializedHistory->S.parseOrRaiseWith(testEntityHistorySchema)
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

  it("Creates a js insert function", () => {
    let insertFnString = TestEntity.entityHistory.insertFn->toStringUnsafe

    let expected = `(sql, rowArgs, shouldCopyCurrentEntity) =>
      sql\`select "insert_TestEntity_history"(ROW(\${rowArgs["entity_history_block_timestamp"]}, \${rowArgs["entity_history_chain_id"]}, \${rowArgs["entity_history_block_number"]}, \${rowArgs["entity_history_log_index"]}, \${rowArgs["previous_entity_history_block_timestamp"]}, \${rowArgs["previous_entity_history_chain_id"]}, \${rowArgs["previous_entity_history_block_number"]}, \${rowArgs["previous_entity_history_log_index"]}, \${rowArgs["id"]}, \${rowArgs["fieldA"]}, \${rowArgs["fieldB"]}, \${rowArgs["action"]}, NULL),  --NULL argument for SERIAL field
    \${shouldCopyCurrentEntity});\``

    Assert.equal(insertFnString, expected)
  })

  Async.it("Creating tables and functions works", async () => {
    try {
      let _ = await Migrations.runDownMigrations(~shouldExit=false)
      let _ = await Migrations.createEnumIfNotExists(Db.sql, EntityHistory.RowAction.enum)
      let _resA = await Migrations.creatTableIfNotExists(Db.sql, TestEntity.table)
      let _resB = await Migrations.creatTableIfNotExists(Db.sql, TestEntity.entityHistory.table)
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
      let _ = await Migrations.runDownMigrations(~shouldExit=false)
      let _ = await Migrations.createEnumIfNotExists(Db.sql, EntityHistory.RowAction.enum)
      let _ = await Migrations.creatTableIfNotExists(Db.sql, TestEntity.table)
      let _ = await Migrations.creatTableIfNotExists(Db.sql, TestEntity.entityHistory.table)

      let _ = await Db.sql->Postgres.unsafe(TestEntity.entityHistory.createInsertFnQuery)

      try await Db.sql->Postgres.beginSql(
        sql => [
          TestEntity.entityHistory->EntityHistory.batchInsertRows(
            ~sql,
            ~rows=Mocks.historyRows,
            ~shouldCopyCurrentEntity=true,
          ),
        ],
      ) catch {
      | exn =>
        Js.log2("insert mock rows exn", exn)
        Assert.fail("Failed to insert mock rows")
      }

      let historyItems = {
        let items = await Db.sql->getAllMockEntityHistory
        items->S.parseOrRaiseWith(TestEntity.entityHistory.schemaRows)
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
      ~entityMod=module(TestEntity),
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
        Mocks.Entity.mockEntity2,
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
      ~entityMod=module(TestEntity),
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
        Mocks.Entity.mockEntity2,
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
      currentHistoryItems->S.parseOrRaiseWith(TestEntity.entityHistory.schemaRows)

    let expectedHistoryItems = Mocks.historyRows->Belt.Array.slice(~offset=0, ~len=4)

    Assert.deepEqual(
      parsedHistoryItems,
      expectedHistoryItems,
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
      currentHistoryItems->S.parseOrRaiseWith(TestEntity.entityHistory.schemaRows)

    let expectedHistoryItems = Mocks.historyRows->Belt.Array.slice(~offset=0, ~len=5)

    Assert.deepEqual(
      parsedHistoryItems,
      expectedHistoryItems,
      ~message="Should have deleted just the last item in history",
    )
  })

  Async.it("Prunes history correctly with items in reorg threshold", async () => {
    await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
      ~entityName=TestEntity.name,
      ~safeChainIdAndBlockNumberArray=[{chainId: 1, blockNumber: 3}, {chainId: 2, blockNumber: 2}],
      ~shouldDeepClean=true,
    )
    let currentHistoryItems = await Db.sql->getAllMockEntityHistory

    let parsedHistoryItems =
      currentHistoryItems->S.parseOrRaiseWith(TestEntity.entityHistory.schemaRows)

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
      parsedHistoryItems->sort,
      expectedHistoryItems->sort,
      ~message="Should have deleted the unneeded first items in history",
    )
  })

  Async.it(
    "Deep clean prunes history correctly with items in reorg threshold without checking for stale history entities in threshold",
    async () => {
      await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
        ~entityName=TestEntity.name,
        ~safeChainIdAndBlockNumberArray=[
          {chainId: 1, blockNumber: 3},
          {chainId: 2, blockNumber: 2},
        ],
        ~shouldDeepClean=false,
      )
      let currentHistoryItems = await Db.sql->getAllMockEntityHistory

      let parsedHistoryItems =
        currentHistoryItems->S.parseOrRaiseWith(TestEntity.entityHistory.schemaRows)

      let sort = arr =>
        arr->Js.Array2.sortInPlaceWith(
          (a, b) => a.EntityHistory.current.block_number - b.current.block_number,
        )

      Assert.deepEqual(
        parsedHistoryItems->sort,
        Mocks.historyRows,
        ~message="Should have deleted the unneeded first items in history",
      )
    },
  )
  Async.it("Prunes history correctly with no items in reorg threshold", async () => {
    await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
      ~entityName=TestEntity.name,
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
    let _ = await Migrations.runDownMigrations(~shouldExit=false)
    let _ = await Migrations.createEnumIfNotExists(Db.sql, EntityHistory.RowAction.enum)
    let _ = await Migrations.creatTableIfNotExists(Db.sql, TestEntity.table)
    let _ = await Migrations.creatTableIfNotExists(Db.sql, TestEntity.entityHistory.table)

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
      sql => [
        TestEntity.entityHistory->EntityHistory.batchInsertRows(
          ~sql,
          ~rows,
          ~shouldCopyCurrentEntity=false,
        ),
      ],
    ) catch {
    | exn =>
      Js.log2("insert mock rows exn", exn)
      Assert.fail("Failed to insert mock rows")
    }

    let startTime = Hrtime.makeTimer()

    try await Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
      ~entityName=TestEntity.name,
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
