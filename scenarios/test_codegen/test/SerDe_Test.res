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

    //Fails if serialziation does not work
    let set = DbFunctionsEntities.batchSet(~entityMod=module(Entities.EntityWithAllTypes))
    //Fails if parsing does not work
    let read = DbFunctionsEntities.batchRead(~entityMod=module(Entities.EntityWithAllTypes))
    //set the entity
    switch await DbFunctions.sql->set([entity]) {
    | exception exn =>
      Js.log(exn)
      Assert.fail("Failed to set entity in table")
    | _ => ()
    }

    switch await DbFunctions.sql->read([entity.id]) {
    | exception exn =>
      Js.log(exn)
      Assert.fail("Failed to read entity from table")
    | [_entity] => ()
    | _ => Assert.fail("Should have returned a row on batch read fn")
    }

    //The copy function will do it's custom postgres serialization of the entity
    await DbFunctions.sql->DbFunctions.EntityHistory.copyAllEntitiesToEntityHistory

    let res = await DbFunctions.sql->Postgres.unsafe(`SELECT * FROM public.entity_history;`)

    switch res {
    | [row] =>
      let json = row["params"]
      let parsed = json->S.parseWith(Entities.EntityWithAllTypes.schema)
      switch parsed {
      | Ok(parsed) =>
        Assert.deepEqual(
          parsed,
          entity,
          ~message="Postgres json serialization should be compatable with our schema",
        )
      | Error(e) => Assert.fail("Failed to parse entity history: " ++ e->S.Error.reason)
      }
    | _ => Assert.fail("Should have returned a row")
    }
  })
})
