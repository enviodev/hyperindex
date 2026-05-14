open Vitest

describe("Chains State", () => {
  describe("chainInfo type", () => {
    it(
      "should have isRealtime field set to false",
      t => {
        let chainInfo: Internal.chainInfo = {id: 1, isRealtime: false}
        t.expect(chainInfo.isRealtime).toBe(false)
      },
    )

    it(
      "should have isRealtime field set to true",
      t => {
        let chainInfo: Internal.chainInfo = {id: 1, isRealtime: true}
        t.expect(chainInfo.isRealtime).toBe(true)
      },
    )
  })

  describe("chains dict", () => {
    it(
      "should support multiple chains with different states",
      t => {
        let chains: Internal.chains = Dict.make()
        chains->Dict.set("1", {Internal.id: 1, isRealtime: false})
        chains->Dict.set("2", {Internal.id: 2, isRealtime: true})

        t.expect(chains->Dict.get("1")->Belt.Option.map(c => c.isRealtime)).toBe(Some(false))
        t.expect(chains->Dict.get("2")->Belt.Option.map(c => c.isRealtime)).toBe(Some(true))
      },
    )
  })

  describe("chain in context", () => {
    Async.it(
      "should be accessible in handler context",
      async t => {
        // This test verifies that the chain field is accessible
        // The actual integration test is in EventHandlers.res with the EmptyEvent handler
        let inMemoryStore = InMemoryStore.make(~entities=(Config.loadWithoutRegistrations()).allEntities)
        let loadManager = LoadManager.make()

        let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

        let chains = Dict.make()
        chains->Dict.set("1337", {Internal.id: 1337, isRealtime: false})

        let handlerContext = UserContext.getHandlerContext({
          item,
          loadManager,
          persistence: PgStorage.makePersistenceFromConfig(
            ~config=Config.loadWithoutRegistrations(),
          ),
          inMemoryStore,
          transit: None,
          shouldSaveHistory: false,
          isPreload: false,
          checkpointId: 0n,
          chains,
          isResolved: false,
          config: Config.loadWithoutRegistrations(),
        })

        // Verify we can access current event's chain info
        t.expect(handlerContext.chain.isRealtime).toBe(false)
        t.expect(handlerContext.chain.id).toBe(1337)
      },
    )
  })
})
