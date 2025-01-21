open RescriptMocha

@send external padStart: (string, ~padCount: int, ~padChar: string) => string = "padStart"

let mockDate = (~year=2024, ~month=1, ~day=1) => {
  let padInt = i => i->Belt.Int.toString->padStart(~padCount=2, ~padChar="0")
  Js.Date.fromString(`${year->padInt}-${month->padInt}-${day->padInt}T00:00:00Z`)
}

describe("SerDe Test", () => {
  Async.before(async () => {
    await DbHelpers.runUpDownMigration()
  })

  Async.it("All type entity", async () => {
    let entity: Entities.EntityWithAllTypes.t = {
      id: "1",
      string: "string",
      optString: Some("optString"),
      arrayOfStrings: ["arrayOfStrings1", "arrayOfStrings2"],
      int_: 1,
      optInt: Some(2),
      arrayOfInts: [3, 4],
      float_: 1.1,
      optFloat: Some(2.2),
      arrayOfFloats: [3.3, 4.4],
      bool: true,
      optBool: Some(false),
      //TODO: get array of bools working
      // arrayOfBool: [true, false],
      bigInt: BigInt.fromInt(1),
      optBigInt: Some(BigInt.fromInt(2)),
      arrayOfBigInts: [BigInt.fromInt(3), BigInt.fromInt(4)],
      bigDecimal: BigDecimal.fromStringUnsafe("1.1"),
      optBigDecimal: Some(BigDecimal.fromStringUnsafe("2.2")),
      arrayOfBigDecimals: [BigDecimal.fromStringUnsafe("3.3"), BigDecimal.fromStringUnsafe("4.4")],
      //TODO: get timestamp working
      // timestamp: mockDate(~day=1),
      // optTimestamp: Some(mockDate(~day=2)),
      // arrayOfTimestamps: [Js.Date.fromFloat(3.3), Js.Date.fromFloat(4.4)],
      // arrayOfTimestamps: [],
    }

    let entityHistoryItem: EntityHistory.historyRow<_> = {
      current: {
        chain_id: 1,
        block_timestamp: 1,
        block_number: 1,
        log_index: 1,
      },
      previous: None,
      entityData: Set(entity),
    }

    //Fails if serialziation does not work
    let set = DbFunctionsEntities.batchSet(~entityMod=module(Entities.EntityWithAllTypes))
    //Fails if parsing does not work
    let read = DbFunctionsEntities.batchRead(~entityMod=module(Entities.EntityWithAllTypes))

    let setHistory = (sql, row) =>
      Entities.EntityWithAllTypes.entityHistory->EntityHistory.batchInsertRows(
        ~sql,
        ~rows=[row],
        ~shouldCopyCurrentEntity=true,
      )

    try await Db.sql->setHistory(entityHistoryItem) catch {
    | exn =>
      Js.log2("setHistory exn", exn)
      Assert.fail("Failed to set entity history in table")
    }

    //set the entity
    try await Db.sql->set([entity]) catch {
    | exn =>
      Js.log(exn)
      Assert.fail("Failed to set entity in table")
    }

    switch await Db.sql->read([entity.id]) {
    | exception exn =>
      Js.log(exn)
      Assert.fail("Failed to read entity from table")
    | [_entity] => ()
    | _ => Assert.fail("Should have returned a row on batch read fn")
    }

    //The copy function will do it's custom postgres serialization of the entity
    // await Db.sql->DbFunctions.EntityHistory.copyAllEntitiesToEntityHistory

    let res = await Db.sql->Postgres.unsafe(`SELECT * FROM public."EntityWithAllTypes_history";`)

    switch res {
    | [row] =>
      let parsed = row->S.parseJsonOrThrow(Entities.EntityWithAllTypes.entityHistory.schema)
      Assert.deepEqual(
        parsed.entityData,
        Set(entity),
        ~message="Postgres json serialization should be compatable with our schema",
      )
    | _ => Assert.fail("Should have returned a row")
    }
  })
})
