open Vitest

// Covers `HandlerLoader.applyRegistrations`: the handler-state fields
// (`handler`, `contractRegister`, `isWildcard`) registered via
// `indexer.onEvent` / `indexer.contractRegister` land on the enriched
// event config, and `dependsOnAddresses` follows the shared
// `Internal.dependsOnAddresses` formula. Filter-parsing behavior is
// covered separately by `EventFilters_test.res`.
let (configWithRegistrations, _) = await HandlerLoader.registerAllHandlers(
  ~config=Config.loadWithoutRegistrations(),
)

let getEvmEventConfig = MockConfig.getEvmEventConfig(~config=configWithRegistrations, ...)

describe("HandlerLoader.applyRegistrations", () => {
  it("propagates handler from onEvent into the event config", t => {
    // `indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, …)`
    // is registered in EventHandlers.ts at module top level.
    let eventConfig = getEvmEventConfig(~contractName="SimpleNft", ~eventName="Transfer")
    t.expect(eventConfig.handler->Belt.Option.isSome).toBe(true)
  })

  it("propagates contractRegister from indexer.contractRegister", t => {
    // `indexer.contractRegister({ contract: "NftFactory", event: "SimpleNftCreated" }, …)`.
    let eventConfig = getEvmEventConfig(~contractName="NftFactory", ~eventName="SimpleNftCreated")
    t.expect(eventConfig.contractRegister->Belt.Option.isSome).toBe(true)
  })

  it("marks wildcard: true registrations as isWildcard", t => {
    // `EventFiltersTest.Transfer` is registered with `wildcard: true`.
    let eventConfig = getEvmEventConfig(~contractName="EventFiltersTest", ~eventName="Transfer")
    t.expect(eventConfig.isWildcard).toBe(true)
  })

  it(
    "computes dependsOnAddresses via Internal.dependsOnAddresses for the wildcard+where case",
    t => {
      // `EventFiltersTest.Transfer` is a wildcard registration with a `where`
      // callback that does not filter by addresses, so
      // `filterByAddresses=false` and `dependsOnAddresses=false`.
      let eventConfig = getEvmEventConfig(
        ~contractName="EventFiltersTest",
        ~eventName="Transfer",
      )
      t.expect(
        eventConfig.dependsOnAddresses,
      ).toBe(
        Internal.dependsOnAddresses(
          ~isWildcard=eventConfig.isWildcard,
          ~filterByAddresses=eventConfig.filterByAddresses,
        ),
      )
    },
  )
})
