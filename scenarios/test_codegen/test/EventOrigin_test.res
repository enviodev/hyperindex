open RescriptMocha

describe("Chains State", () => {
  describe("chainInfo type", () => {
    it(
      "should have isLive field set to false",
      () => {
        let chainInfo: Internal.chainInfo = {id: 1, isLive: false}
        Assert.equal(chainInfo.isLive, false)
      },
    )

    it(
      "should have isLive field set to true",
      () => {
        let chainInfo: Internal.chainInfo = {id: 1, isLive: true}
        Assert.equal(chainInfo.isLive, true)
      },
    )
  })

  describe("chains dict", () => {
    it(
      "should support multiple chains with different states",
      () => {
        let chains: Internal.chains = Js.Dict.empty()
        chains->Js.Dict.set("1", {Internal.id: 1, isLive: false})
        chains->Js.Dict.set("2", {Internal.id: 2, isLive: true})

        Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isLive), Some(false))
        Assert.equal(chains->Js.Dict.get("2")->Belt.Option.map(c => c.isLive), Some(true))
      },
    )
  })

  describe("chains in context", () => {
    Async.it(
      "should be accessible in handler context",
      async () => {
        // This test verifies that the chains field is accessible
        // The actual integration test is in EventHandlers.res with the EmptyEvent handler
        let inMemoryStore = InMemoryStore.make(~entities=Entities.allEntities)
        let loadManager = LoadManager.make()

        let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

        let chains = Js.Dict.empty()
        chains->Js.Dict.set("1", {Internal.id: 1, isLive: false})

        let handlerContext = UserContext.getHandlerContext({
          item,
          loadManager,
          persistence: Generated.codegenPersistence,
          inMemoryStore,
          shouldSaveHistory: false,
          isPreload: false,
          checkpointId: 0.,
          chains,
          isResolved: false,
        })

        // Verify we can access chains
        Assert.equal(
          handlerContext.chains->Js.Dict.get("1")->Belt.Option.map(c => c.isLive),
          Some(false),
        )
      },
    )
  })
})
