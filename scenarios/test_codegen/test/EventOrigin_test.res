open RescriptMocha

describe("Chains State", () => {
  describe("chainInfo type", () => {
    it(
      "should have isReady field set to false",
      () => {
        let chainInfo: Internal.chainInfo = {isReady: false}
        Assert.equal(chainInfo.isReady, false)
      },
    )

    it(
      "should have isReady field set to true",
      () => {
        let chainInfo: Internal.chainInfo = {isReady: true}
        Assert.equal(chainInfo.isReady, true)
      },
    )
  })

  describe("chains dict", () => {
    it(
      "should support multiple chains with different states",
      () => {
        let chains: Internal.chains = Js.Dict.empty()
        chains->Js.Dict.set("1", {Internal.isReady: false})
        chains->Js.Dict.set("2", {Internal.isReady: true})

        Assert.equal(chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady), Some(false))
        Assert.equal(chains->Js.Dict.get("2")->Belt.Option.map(c => c.isReady), Some(true))
      },
    )
  })

  describe("chains in context", () => {
    Async.it(
      "should be accessible in handler context",
      async () => {
        // This test verifies that the chains field is accessible
        // The actual integration test is in EventHandlers.res with the EmptyEvent handler
        let inMemoryStore = InMemoryStore.make()
        let loadManager = LoadManager.make()

        let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

        let chains = Js.Dict.empty()
        chains->Js.Dict.set("1", {Internal.isReady: false})

        let handlerContext = UserContext.getHandlerContext({
          item,
          loadManager,
          persistence: Config.codegenPersistence,
          inMemoryStore,
          shouldSaveHistory: false,
          isPreload: false,
          checkpointId: 0,
          chains,
        })

        // Verify we can access chains
        Assert.equal(
          handlerContext.chains->Js.Dict.get("1")->Belt.Option.map(c => c.isReady),
          Some(false),
        )
      },
    )
  })
})
