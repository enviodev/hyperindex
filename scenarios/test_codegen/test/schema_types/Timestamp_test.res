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

    let sql = Db.sql
    /// Setup DB
    let testEntity: Entities.EntityWithTimestamp.t = {
      id: "testEntity",
      timestamp: Js.Date.fromString("1970-01-01T00:02:03.456Z"),
    }
    await sql->PgStorage.setOrThrow(
      ~items=[testEntity->Entities.EntityWithTimestamp.castToInternal],
      ~table=Entities.EntityWithTimestamp.table,
      ~itemSchema=Entities.EntityWithTimestamp.schema,
      ~pgSchema=Config.storagePgSchema,
    )

    let inMemoryStore = InMemoryStore.make()
    let loadManager = LoadManager.make()

    let eventItem = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

    let loaderContext = UserContext.getLoaderContext({
      eventItem,
      loadManager,
      persistence: Config.codegenPersistence,
      inMemoryStore,
      shouldSaveHistory: false,
      isPreload: false,
    })->(Utils.magic: Internal.loaderContext => Types.loaderContext)

    let _ = loaderContext.entityWithTimestamp.get(testEntity.id)

    let handlerContext = UserContext.getHandlerContext({
      eventItem,
      inMemoryStore,
      loadManager,
      persistence: Config.codegenPersistence,
      shouldSaveHistory: false,
      isPreload: false,
    })->(Utils.magic: Internal.handlerContext => Types.handlerContext)

    switch await handlerContext.entityWithTimestamp.get(testEntity.id) {
    | Some(entity) =>
      Assert.deepEqual(entity.timestamp->Js.Date.toISOString, "1970-01-01T00:02:03.456Z")
    | None => Assert.fail("Entity should exist")
    }
  })
})
