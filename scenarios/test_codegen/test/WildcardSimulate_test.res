open Vitest

// EventFiltersTest is configured on chains 100/137 with no address, and its
// Transfer event is registered purely as a wildcard handler via
// `indexer.onEvent({ wildcard: true })`. A concrete srcAddress that isn't
// indexed must NOT trip the simulate validation for such an event — the worker
// routes it via the wildcard path regardless.
Async.it("does not throw for a handler-registered wildcard event with a concrete srcAddress", async t => {
  let indexer = Indexer.createTestIndexer()

  let result = await indexer.process(
    {
      "chains": {
        "100": {
          "startBlock": 1,
          "endBlock": 100,
          "simulate": [
            {
              "contract": "EventFiltersTest",
              "event": "Transfer",
              "srcAddress": "0x1234567890123456789012345678901234567890",
              "params": {
                "from": "0x0000000000000000000000000000000000000000",
                "to": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
                "amount": "0",
              },
            },
          ],
        },
      },
    }->(Utils.magic: 'a => Indexer.testIndexerProcessConfig),
  )

  // The handler ran in the worker, producing a checkpoint change instead of
  // failing validation.
  t.expect(result.changes->Array.length).toEqual(1)
})

// The validation must still fire for a genuinely non-indexed, non-wildcard
// event so the wildcard carve-out doesn't defeat it.
Async.it("still throws for a non-wildcard event whose srcAddress isn't indexed", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process(
      {
        "chains": {
          "1337": {
            "startBlock": 1,
            "endBlock": 100,
            "simulate": [
              {
                "contract": "EventFiltersTest",
                "event": "FilterTestEvent",
                "srcAddress": "0x1234567890123456789012345678901234567890",
                "params": {"addr": "0x0000000000000000000000000000000000000000"},
              },
            ],
          },
        },
      }->(Utils.magic: 'a => Indexer.testIndexerProcessConfig),
    )
    None
  } catch {
  | JsExn(err) => err->JsExn.message
  }

  t.expect(error).toEqual(
    Some(
      `simulate: EventFiltersTest.FilterTestEvent resolved to address 0x1234567890123456789012345678901234567890, which isn't indexed on chain 1337. Provide a "srcAddress" configured or registered for EventFiltersTest on this chain, or use a wildcard event.`,
    ),
  )
})
