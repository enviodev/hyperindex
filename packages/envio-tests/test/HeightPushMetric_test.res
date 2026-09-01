open Vitest

// The height stream pushes heights over SSE, so there's no request to count —
// only the pushes themselves tell whether a subscribed chain is still being fed.
// Accepted and ignored pushes are counted separately: a chain frozen at head
// with `heightPush` flat means the stream went quiet, while `heightPushIgnored`
// climbing means the stream is alive but re-emitting a head we already know.
let scenario = Scenario.make(
  ~configYaml=`
name: height-push-metric
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("Height subscription push metrics", () => {
  scenario->Scenario.it(
    "Counts accepted and ignored height pushes separately",
    ~sources=[
      {
        chain: 1337,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes, #createHeightSubscription],
        pollingInterval: 1,
      },
    ],
    ~reducedPollingInterval=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)

      // Backfill to head so the indexer flips to realtime — the height
      // subscription is only created there.
      sourceMock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      await Utils.delay(0)

      await MockSource.waitItemsQuery(sourceMock)
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 50, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
        ~knownHeight=100,
      )
      await indexer.getBatchWritePromise()

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
        let samples = await indexer.metric("envio_source_request_total")
        samples
        ->Array.filterMap(
          ({value, labels}: IndexerRunner.metric) =>
            switch labels->Dict.get("method") {
            | Some(method) if method->String.startsWith("height") => Some((method, value))
            | _ => None
            },
        )
        ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
      }

      t.expect(
        await heightPushSamples(),
        ~message="opening a subscription is not a request and no push has arrived yet",
      ).toEqual([])

      // The stream finds a new block.
      sourceMock.triggerHeightSubscription(101)
      await MockSource.waitItemsQuery(sourceMock)

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
    },
  )
})
