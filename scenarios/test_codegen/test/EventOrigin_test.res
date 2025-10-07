open RescriptMocha

describe("EventOrigin", () => {
  describe("eventOrigin type", () => {
    it("should have Historical variant", () => {
      let origin: Internal.eventOrigin = Historical
      // Verify it compiles and can be used
      switch origin {
      | Historical => Assert.ok(true)
      | Live => Assert.ok(false)
      }
    })

    it("should have Live variant", () => {
      let origin: Internal.eventOrigin = Live
      // Verify it compiles and can be used
      switch origin {
      | Historical => Assert.ok(false)
      | Live => Assert.ok(true)
      }
    })
  })

  describe("eventOrigin in context", () => {
    Async.it("should be accessible in handler context", async () => {
      // This test verifies that the eventOrigin field is accessible
      // The actual integration test is in EventHandlers.res with the EmptyEvent handler
      let inMemoryStore = InMemoryStore.make()
      let loadManager = LoadManager.make()

      let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

      let handlerContext = UserContext.getHandlerContext({
        item,
        loadManager,
        persistence: Config.codegenPersistence,
        inMemoryStore,
        shouldSaveHistory: false,
        isPreload: false,
        eventOrigin: Internal.Historical,
      })

      // Verify we can access eventOrigin
      switch handlerContext.eventOrigin {
      | Historical => Assert.ok(true)
      | Live => Assert.ok(false)
      }
    })
  })
})
