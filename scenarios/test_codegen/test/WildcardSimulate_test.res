open Vitest

// EventFiltersTest is configured on chains 100/137 with no address, and its
// Transfer event is registered purely as a wildcard handler via
// `indexer.onEvent({ wildcard: true })`. The simulate path routes such an event
// to its handler whatever srcAddress the item carries.
let badAddr = Address.unsafeFromString("0x1234567890123456789012345678901234567890")
let zero = Address.unsafeFromString("0x0000000000000000000000000000000000000000")
let whitelisted100 = Address.unsafeFromString("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC")

Async.it("routes a handler-registered wildcard event to its handler regardless of srcAddress", async t => {
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

  // The wildcard handler ran in the worker, producing the checkpoint change below.
  t.expect(
    result.changes->(
      Utils.magic: array<unknown> => array<{"block": int, "chainId": int, "eventsProcessed": int}>
    ),
  ).toEqual([{"block": 1, "chainId": 100, "eventsProcessed": 1}])
})

// simulate only requires srcAddress to start with "0x" — a placeholder like
// "0xfoo" is accepted, unlike a real address which must be valid 20-byte hex.
Async.it("accepts a non-address placeholder srcAddress starting with 0x", async t => {
  let indexer = Indexer.createTestIndexer()

  let wildcardTransfer: Envio.evmSimulateItem = {
    ...Indexer.makeSimulateItem(
      OnEvent({
        event: EventFiltersTest(Transfer),
        params: {from: zero, to: whitelisted100, amount: 0n},
      }),
    ),
    srcAddress: Address.unsafeFromString("0xfoo"),
  }

  let result = await indexer.process({
    chains: {\"100": {startBlock: 1, endBlock: 100, simulate: [wildcardTransfer]}},
  })

  t.expect(
    result.changes->(
      Utils.magic: array<unknown> => array<{"block": int, "chainId": int, "eventsProcessed": int}>
    ),
  ).toEqual([{"block": 1, "chainId": 100, "eventsProcessed": 1}])
})
