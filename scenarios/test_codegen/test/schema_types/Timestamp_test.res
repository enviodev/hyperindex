open RescriptMocha

describe("Load and save an entity with a Timestamp from DB", () => {
  Async.before(() => {
    DbHelpers.runUpDownMigration()
  })

  Async.after(() => {
    // It is probably overkill that we are running these 'after' also
    DbHelpers.runUpDownMigration()
  })

  Async.it("be able to set and read entities with Timestamp from DB", async () => {
    This.timeout(5 * 1000)

    let sql = DbFunctions.sql
    /// Setup DB
    let testEntity: Entities.EntityWithTimestamp.t = {
      id: "testEntity",
      timestamp: Js.Date.fromString("1970-01-01T00:02:03.456Z"),
    }
    await DbFunctionsEntities.batchSet(~entityMod=module(Entities.EntityWithTimestamp))(
      sql,
      [testEntity],
    )

    let inMemoryStore = InMemoryStore.make()
    let loadLayer = LoadLayer.makeWithDbConnection()

    let contextEnv = ContextEnv.make(
      ~eventMod=module(Types.Gravatar.EmptyEvent)->Types.eventModToInternal,
      ~event={"devMsg": "This is a placeholder event", "block": {"number": 456}}->Utils.magic,
      ~chain=MockConfig.chain1,
      ~logger=Logging.logger,
    )

    let loaderContext = contextEnv->ContextEnv.getLoaderContext(~loadLayer, ~inMemoryStore)

    let _ = loaderContext.entityWithTimestamp.get(testEntity.id)

    let handlerContext = contextEnv->ContextEnv.getHandlerContext(~inMemoryStore, ~loadLayer)

    switch await handlerContext.entityWithTimestamp.get(testEntity.id) {
    | Some(entity) =>
      Assert.deepEqual(entity.timestamp->Js.Date.toISOString, "1970-01-01T00:02:03.456Z")
    | None => Assert.fail("Entity should exist")
    }
  })
})
