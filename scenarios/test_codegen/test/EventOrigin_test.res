open Vitest

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

  describe("chain in context", () => {
    Async.it(
      "should be accessible in handler context",
      async () => {
        // This test verifies that the chain field is accessible
        // The actual integration test is in EventHandlers.res with the EmptyEvent handler
        let inMemoryStore = InMemoryStore.make(~entities=Indexer.Generated.allEntities)
        let loadManager = LoadManager.make()

        let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

        let chains = Js.Dict.empty()
        chains->Js.Dict.set("1337", {Internal.id: 1337, isLive: false})

        let handlerContext = UserContext.getHandlerContext({
          item,
          loadManager,
          persistence: Indexer.Generated.codegenPersistence,
          inMemoryStore,
          shouldSaveHistory: false,
          isPreload: false,
          checkpointId: 0.,
          chains,
          isResolved: false,
          config: Indexer.Generated.configWithoutRegistrations,
        })

        // Verify we can access current event's chain info
        Assert.equal(handlerContext.chain.isLive, false)
        Assert.equal(handlerContext.chain.id, 1337)
      },
    )
  })
})
