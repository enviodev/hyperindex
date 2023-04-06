open Jest
/* open Expect */

describe("E2E Mock Event Batch", () => {
  beforeAllPromise(() => {
    SetupRpcNode.setupNodeAndContracts()
  }, ~timeout=60000)

  testPromise("Complete E2E", async () => {
    let localChainConfig = Config.config->Js.Dict.unsafeGet("31337")
    await localChainConfig->EventSyncing.processAllEvents
    pass
  })
})
