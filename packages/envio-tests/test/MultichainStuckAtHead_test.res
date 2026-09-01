open Vitest

// Regression for v3.3.0: a multichain indexer's chain with a HyperSync height
// subscription stopped progressing at head while the other chains kept
// indexing.
//
// The wait loop's REST polling fallback short-circuits forever once the
// subscription advances the wait's height only partially — reachable on
// v3.3.0 because sourceState.knownHeight (written only by the subscription
// callback there) lagged fetchState.knownHeight (raised by getLogs
// responses). After that, no getHeight request was ever made again
// ("envio_source_request_total" for getHeight stayed flat) and the chain
// waited for a new block forever. Since v3.3.1 executeQuery syncs
// sourceState.knownHeight from response heights, which keeps the gap from
// opening for a single source.
let scenario = Scenario.make(
  ~configYaml=`
name: multichain-stuck-at-head
rollback_on_reorg: false
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 100
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("Multichain: chain with height subscription stuck at head", () => {
  scenario->Scenario.it(
    "polling fallback takes over when the subscription goes quiet after a partial height advance",
    ~sources=[
      {
        chain: 100,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes, #createHeightSubscription],
        pollingInterval: 1,
      },
      {
        chain: 1337,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        pollingInterval: 1,
      },
    ],
    ~reducedPollingInterval=1,
    // A 5s wait for the subscription plus a 25s polling fallback doesn't fit
    // the suite's default budget.
    ~timeout=60_000,
    async (~t, ~indexer, ~source) => {
      let stuckChain = source(100)
      let healthyChain = source(1337)

      // Backfill both chains to head 100 so the indexer flips to realtime —
      // the height subscription is only created in realtime mode.
      stuckChain.resolveGetHeightOrThrow(100)
      healthyChain.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      await Utils.delay(0)

      await MockSource.waitItemsQuery(stuckChain)
      stuckChain.resolveGetItemsOrThrow(
        [{blockNumber: 50, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
        ~knownHeight=100,
      )
      await MockSource.waitItemsQuery(healthyChain)
      healthyChain.resolveGetItemsOrThrow(
        [{blockNumber: 60, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
        ~knownHeight=100,
      )
      await indexer.getBatchWritePromise()

      // The realtime wait polls height once more; a same-height response is
      // what makes it open the subscription. Waits parked before the realtime
      // flip keep REST-polling — feed them the same height until the
      // subscription appears.
      let subscriptionOpened = () => stuckChain.heightSubscriptionCalls->Array.length > 0
      let deadline = Date.now() +. 5_000.
      while !subscriptionOpened() && Date.now() < deadline {
        try stuckChain.resolveGetHeightOrThrow(100) catch {
        | _ => ()
        }
        await Utils.delay(1)
      }
      t.expect(
        subscriptionOpened(),
        ~message="realtime transition should open the height subscription",
      ).toBe(true)
      // Release any pre-realtime wait still REST-polling at the same height so
      // it exits and gets discarded as stale.
      try stuckChain.resolveGetHeightOrThrow(101) catch {
      | _ => ()
      }

      // The stream finds block 101.
      stuckChain.triggerHeightSubscription(101)
      await MockSource.waitItemsQuery(stuckChain)
      t.expect(
        stuckChain.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="the new block from the subscription should be queried",
      ).toEqual([101])
      // The getLogs response's archive height is already 102 — ahead of the
      // stream. It raises fetchState.knownHeight, while on v3.3.0
      // sourceState.knownHeight stays at the subscription's last height (101).
      stuckChain.resolveGetItemsOrThrow(
        [{blockNumber: 101, logIndex: 0}],
        ~latestFetchedBlockNumber=101,
        ~knownHeight=102,
      )
      await indexer.getBatchWritePromise()

      await MockSource.waitItemsQuery(stuckChain)
      t.expect(
        stuckChain.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="the newly known block 102 should be queried",
      ).toEqual([102])
      stuckChain.resolveGetItemsOrThrow(
        [{blockNumber: 102, logIndex: 0}],
        ~latestFetchedBlockNumber=102,
        ~knownHeight=102,
      )
      await indexer.getBatchWritePromise()

      // The chain is at head again: waiting for a block above 102 while the
      // wait started from the subscription's last height 101. The stream
      // re-emits the current head (as it does on reconnect) — a partial
      // advance within the wait — and then goes quiet for good.
      await Utils.delay(10)
      stuckChain.triggerHeightSubscription(102)

      // Meanwhile the other chain keeps progressing, so the cross-chain
      // scheduler keeps ticking — ticks alone must not be needed to heal the
      // stuck chain's wait.
      try healthyChain.resolveGetHeightOrThrow(101) catch {
      | _ => ()
      }
      await MockSource.waitItemsQuery(healthyChain)
      healthyChain.resolveGetItemsOrThrow(
        [{blockNumber: 101, logIndex: 0}],
        ~latestFetchedBlockNumber=101,
        ~knownHeight=101,
      )
      await indexer.getBatchWritePromise()

      // The subscription is quiet, so the wait must fall back to REST height
      // polling within the realtime stall window (10..20s). On v3.3.0 the
      // fallback short-circuits without a single getHeight request and the
      // chain stays stuck at head forever.
      let heightCallsBefore = stuckChain.getHeightOrThrowCalls->Array.length
      let pollDeadline = Date.now() +. 25_000.
      while (
        stuckChain.getHeightOrThrowCalls->Array.length === heightCallsBefore &&
          Date.now() < pollDeadline
      ) {
        await Utils.delay(50)
      }
      t.expect(
        stuckChain.getHeightOrThrowCalls->Array.length > heightCallsBefore,
        ~message="the polling fallback should take over when the height subscription goes quiet",
      ).toBe(true)

      t.expect(
        stuckChain.heightSubscriptionCalls->Array.length,
        ~message="the subscription should not be recreated",
      ).toEqual(1)

      // The fallback poll finds block 103 and the chain resumes indexing.
      stuckChain.resolveGetHeightOrThrow(103)
      await MockSource.waitItemsQuery(stuckChain)
      t.expect(
        stuckChain.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="the chain should resume fetching from the fallback-discovered height",
      ).toEqual([103])
    },
  )
})
