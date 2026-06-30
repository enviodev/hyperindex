open Vitest

// EventFiltersTest is configured on chains 100/137 with no address, and its
// Transfer event is registered purely as a wildcard handler via
// `indexer.onEvent({ wildcard: true })`. A concrete srcAddress that isn't
// indexed must NOT trip the simulate validation for such an event — the worker
// routes it via the wildcard path regardless.
let badAddr = Address.unsafeFromString("0x1234567890123456789012345678901234567890")
let zero = Address.unsafeFromString("0x0000000000000000000000000000000000000000")
let whitelisted100 = Address.unsafeFromString("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")

Async.it("does not throw for a handler-registered wildcard event with a concrete srcAddress", async t => {
  let indexer = Indexer.createTestIndexer()

  let wildcardTransfer: Envio.evmSimulateItem = {
    ...Indexer.makeSimulateItem(
      OnEvent({
        event: EventFiltersTest(Transfer),
        params: {from: zero, to: whitelisted100, amount: 0n},
      }),
    ),
    srcAddress: badAddr,
  }

  let result = await indexer.process({
    chains: {\"100": {startBlock: 1, endBlock: 100, simulate: [wildcardTransfer]}},
  })

  // The handler ran in the worker, producing the checkpoint change below
  // instead of failing validation.
  t.expect(
    result.changes->(
      Utils.magic: array<unknown> => array<{"block": int, "chainId": int, "eventsProcessed": int}>
    ),
  ).toEqual([{"block": 1, "chainId": 100, "eventsProcessed": 1}])
})

// The validation must still fire for a genuinely non-indexed, non-wildcard
// event so the wildcard carve-out doesn't defeat it.
Async.it("still throws for a non-wildcard event whose srcAddress isn't indexed", async t => {
  let indexer = Indexer.createTestIndexer()

  let nonWildcard: Envio.evmSimulateItem = {
    ...Indexer.makeSimulateItem(
      OnEvent({event: EventFiltersTest(FilterTestEvent), params: {addr: zero}}),
    ),
    srcAddress: badAddr,
  }

  let error = try {
    let _ = await indexer.process({
      chains: {\"1337": {startBlock: 1, endBlock: 100, simulate: [nonWildcard]}},
    })
    None
  } catch {
  | JsExn(err) => err->JsExn.message
  }

  t.expect(error).toEqual(
    Some(
      `simulate: EventFiltersTest.FilterTestEvent resolved to address ${badAddr->Address.toString}, which isn't indexed on chain 1337. Provide a "srcAddress" configured or registered for EventFiltersTest on this chain, or use a wildcard event.`,
    ),
  )
})
