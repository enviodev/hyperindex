open Vitest

// The height stream pushes heights over SSE, so there's no request to count —
// only the pushes themselves tell whether a subscribed chain is still being fed.
// Accepted and ignored pushes are counted separately: a chain frozen at head
// with `heightPush` flat means the stream went quiet, while `heightPushIgnored`
// climbing means the stream is alive but re-emitting a head we already know.
describe("Height subscription push metrics", () => {
  Async.it("Counts accepted and ignored height pushes separately", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes, #createHeightSubscription],
      ~chainId=#1337,
      ~pollingInterval=1,
    )

    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
          maxReorgDepth: 0,
        },
      ],
      ~shouldRollbackOnReorg=false,
      ~reducedPollingInterval=1,
    )
    await Utils.delay(0)

    // Backfill to head so the indexer flips to realtime — the height
    // subscription is only created there.
    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)

    await MockIndexer.Helper.waitItemsQuery(sourceMock)
    sourceMock.resolveGetItemsOrThrow(
      [{blockNumber: 50, logIndex: 0}],
      ~latestFetchedBlockNumber=100,
      ~knownHeight=100,
    )
    await indexerMock.getBatchWritePromise()

    // The realtime wait polls once more; a same-height response is what makes
    // it open the subscription.
    let subscriptionOpened = () => sourceMock.heightSubscriptionCalls->Array.length > 0
    let deadline = Date.now() +. 5_000.
    while !subscriptionOpened() && Date.now() < deadline {
      try sourceMock.resolveGetHeightOrThrow(100) catch {
      | _ => ()
      }
      await Utils.delay(1)
    }
    t.expect(subscriptionOpened(), ~message="the height subscription should be open").toBe(true)

    let heightPushSamples = async () => {
      let samples = await indexerMock.metric("envio_source_request_total")
      samples
      ->Array.filterMap(({value, labels}: MockIndexer.Indexer.metric) =>
        switch labels->Dict.get("method") {
        | Some(method) if method->String.startsWith("height") => Some((method, value))
        | _ => None
        }
      )
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
    }

    t.expect(
      await heightPushSamples(),
      ~message="opening a subscription is not a request and no push has arrived yet",
    ).toEqual([])

    // The stream finds a new block.
    sourceMock.triggerHeightSubscription(101)
    await MockIndexer.Helper.waitItemsQuery(sourceMock)

    t.expect(
      await heightPushSamples(),
      ~message="the accepted push is counted, with no zero-count line for ignored pushes",
    ).toEqual([("heightPush", "1")])

    // The stream re-emits a head we already know, as it does on reconnect.
    sourceMock.triggerHeightSubscription(101)
    sourceMock.triggerHeightSubscription(100)
    await Utils.delay(0)

    t.expect(
      await heightPushSamples(),
      ~message="pushes dropped by the increasing-height guard are counted apart",
    ).toEqual([("heightPush", "1"), ("heightPushIgnored", "2")])
  })
})
