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
    let storage = Config.codegenPersistence->Persistence.getInitializedStorageOrThrow

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
      json: %raw(`{"foo": ["bar"]}`),
      enumField: ADMIN,
      optEnumField: Some(ADMIN),
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
    let set = (sql, items) =>
      sql->PgStorage.setOrThrow(
        ~items,
        ~table=Entities.EntityWithAllTypes.table,
        ~itemSchema=Entities.EntityWithAllTypes.schema,
        ~pgSchema=Config.storagePgSchema,
      )

    //Fails if parsing does not work
    let read = ids =>
      storage.loadByIdsOrThrow(
        ~ids,
        ~table=Entities.EntityWithAllTypes.table,
        ~rowsSchema=Entities.EntityWithAllTypes.rowsSchema,
      )

    let setHistory = (sql, row) =>
      Entities.EntityWithAllTypes.entityHistory->EntityHistory.batchInsertRows(~sql, ~rows=[row])

    try await Db.sql->setHistory(entityHistoryItem) catch {
    | exn =>
      Js.log2("setHistory exn", exn)
      Assert.fail("Failed to set entity history in table")
    }

    //set the entity
    try await Db.sql->set([entity->Entities.EntityWithAllTypes.castToInternal]) catch {
    | exn =>
      Js.log(exn)
      Assert.fail("Failed to set entity in table")
    }

    switch await read([entity.id]) {
    | exception exn =>
      Js.log(exn)
      Assert.fail("Failed to read entity from table")
    | [_entity] => Assert.deepEqual(_entity, entity)
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

  it("contains correct query for unnest entity", () => {
    let createQuery =
      Entities.EntityWithAllNonArrayTypes.table->PgStorage.makeCreateTableQuery(~pgSchema="public")
    Assert.equal(
      createQuery,
      `CREATE TABLE IF NOT EXISTS "public"."EntityWithAllNonArrayTypes"("bigDecimal" NUMERIC NOT NULL, "bigInt" NUMERIC NOT NULL, "bool" BOOLEAN NOT NULL, "enumField" "public".AccountType NOT NULL, "float_" DOUBLE PRECISION NOT NULL, "id" TEXT NOT NULL, "int_" INTEGER NOT NULL, "optBigDecimal" NUMERIC, "optBigInt" NUMERIC, "optBool" BOOLEAN, "optEnumField" "public".AccountType, "optFloat" DOUBLE PRECISION, "optInt" INTEGER, "optString" TEXT, "string" TEXT NOT NULL, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));`,
    )
    let query = PgStorage.makeInsertUnnestSetQuery(
      ~table=Entities.EntityWithAllNonArrayTypes.table,
      ~itemSchema=Entities.EntityWithAllNonArrayTypes.schema,
      ~isRawEvents=false,
      ~pgSchema="public",
    )

    Assert.equal(
      query,
      `INSERT INTO "public"."EntityWithAllNonArrayTypes" ("bigDecimal", "bigInt", "bool", "enumField", "float_", "id", "int_", "optBigDecimal", "optBigInt", "optBool", "optEnumField", "optFloat", "optInt", "optString", "string")
SELECT * FROM unnest($1::NUMERIC[],$2::NUMERIC[],$3::INTEGER[]::BOOLEAN[],$4::TEXT[]::"public".AccountType[],$5::DOUBLE PRECISION[],$6::TEXT[],$7::INTEGER[],$8::NUMERIC[],$9::NUMERIC[],$10::INTEGER[]::BOOLEAN[],$11::TEXT[]::"public".AccountType[],$12::DOUBLE PRECISION[],$13::INTEGER[],$14::TEXT[],$15::TEXT[])ON CONFLICT("id") DO UPDATE SET "bigDecimal" = EXCLUDED."bigDecimal","bigInt" = EXCLUDED."bigInt","bool" = EXCLUDED."bool","enumField" = EXCLUDED."enumField","float_" = EXCLUDED."float_","int_" = EXCLUDED."int_","optBigDecimal" = EXCLUDED."optBigDecimal","optBigInt" = EXCLUDED."optBigInt","optBool" = EXCLUDED."optBool","optEnumField" = EXCLUDED."optEnumField","optFloat" = EXCLUDED."optFloat","optInt" = EXCLUDED."optInt","optString" = EXCLUDED."optString","string" = EXCLUDED."string";`,
    )
  })

  Async.it("All type entity without array types for unnest case", async () => {
    let storage = Config.codegenPersistence->Persistence.getInitializedStorageOrThrow

    let entity: Entities.EntityWithAllNonArrayTypes.t = {
      id: "1",
      string: "string",
      optString: Some("optString"),
      int_: 1,
      optInt: Some(2),
      float_: 1.1,
      optFloat: Some(2.2),
      bool: true,
      optBool: Some(false),
      bigInt: BigInt.fromInt(1),
      optBigInt: Some(BigInt.fromInt(2)),
      bigDecimal: BigDecimal.fromStringUnsafe("1.1"),
      optBigDecimal: Some(BigDecimal.fromStringUnsafe("2.2")),
      enumField: ADMIN,
      optEnumField: Some(ADMIN),
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
    let set = (sql, items) => {
      sql->PgStorage.setOrThrow(
        ~items,
        ~table=Entities.EntityWithAllNonArrayTypes.table,
        ~itemSchema=Entities.EntityWithAllNonArrayTypes.schema,
        ~pgSchema="public",
      )
    }

    //Fails if parsing does not work
    let read = ids =>
      storage.loadByIdsOrThrow(
        ~ids,
        ~table=Entities.EntityWithAllNonArrayTypes.table,
        ~rowsSchema=Entities.EntityWithAllNonArrayTypes.rowsSchema,
      )

    let setHistory = (sql, row) =>
      Entities.EntityWithAllNonArrayTypes.entityHistory->EntityHistory.batchInsertRows(
        ~sql,
        ~rows=[row],
      )

    try await Db.sql->setHistory(entityHistoryItem) catch {
    | exn =>
      Js.log2("setHistory exn", exn)
      Assert.fail("Failed to set entity history in table")
    }

    //set the entity
    try await Db.sql->set([entity->Entities.EntityWithAllNonArrayTypes.castToInternal]) catch {
    | exn =>
      Js.log(exn)
      Assert.fail("Failed to set entity in table")
    }

    switch await read([entity.id]) {
    | exception exn =>
      Js.log(exn)
      Assert.fail("Failed to read entity from table")
    | [_entity] => Assert.deepEqual(_entity, entity)
    | _ => Assert.fail("Should have returned a row on batch read fn")
    }

    //The copy function will do it's custom postgres serialization of the entity
    // await Db.sql->DbFunctions.EntityHistory.copyAllEntitiesToEntityHistory

    let res =
      await Db.sql->Postgres.unsafe(`SELECT * FROM public."EntityWithAllNonArrayTypes_history";`)

    switch res {
    | [row] =>
      let parsed = row->S.parseJsonOrThrow(Entities.EntityWithAllNonArrayTypes.entityHistory.schema)
      Assert.deepEqual(
        parsed.entityData,
        Set(entity),
        ~message="Postgres json serialization should be compatable with our schema",
      )
    | _ => Assert.fail("Should have returned a row")
    }
  })
})
