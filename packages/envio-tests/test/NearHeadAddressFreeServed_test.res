open Vitest

// Near the head against real sources: dynamic contracts are read in one
// address-free query per block, routed against the address store on our side.
// Over RPC, a block too large for the provider's result cap is read again by
// the contracts' addresses, and the block after it is address-free again.
// Backfill more than 100 blocks from the head keeps sending addresses.
let rpcPort = 18731
let hyperSyncPort = 18732

let factory = "0x1000000000000000000000000000000000000001"
let pair1 = "0x2000000000000000000000000000000000000002"
let pair2 = "0x3000000000000000000000000000000000000003"
let pair3 = "0x4000000000000000000000000000000000000004"
let spamToken = "0x5000000000000000000000000000000000000005"

let pairCreated = "0xb14a725aeeb25d591b81b16b4c5b25403dd8867bdd1876fa787867f566206be1"
let transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let created = (~blockNumber, ~logIndex, pair): ServedEvmChain.log => {
  blockNumber,
  logIndex,
  address: factory,
  topics: [pairCreated],
  data: pair->ServedEvmChain.dropPrefix->ServedEvmChain.word,
}

let transferred = (~blockNumber, ~logIndex, token): ServedEvmChain.log => {
  blockNumber,
  logIndex,
  address: token,
  topics: [transfer, factory->ServedEvmChain.addressTopic, pair1->ServedEvmChain.addressTopic],
  data: logIndex->ServedEvmChain.hex->ServedEvmChain.dropPrefix->ServedEvmChain.word,
}

// More logs than this in one answer and the RPC provider refuses it, the way
// providers cap eth_getLogs at 10,000 results.
let resultCap = 5

// The backfill ends here, more than 100 blocks past the factory's events.
let backfillHead = 300
let headBlock = 301
let lastBlock = 302
let logs = Array.flat([
  [
    created(~blockNumber=2, ~logIndex=0, pair1),
    created(~blockNumber=2, ~logIndex=1, pair2),
    transferred(~blockNumber=3, ~logIndex=0, pair1),
    transferred(~blockNumber=3, ~logIndex=1, pair2),
    // Registered at the head, emitting in its registration block.
    created(~blockNumber=headBlock, ~logIndex=0, pair3),
    transferred(~blockNumber=headBlock, ~logIndex=1, pair3),
  ],
  // A spam token flooding the head block past the cap.
  Array.fromInitializer(~length=resultCap + 1, i =>
    transferred(~blockNumber=headBlock, ~logIndex=2 + i, spamToken)
  ),
  [
    transferred(~blockNumber=lastBlock, ~logIndex=0, pair1),
    transferred(~blockNumber=lastBlock, ~logIndex=1, pair3),
  ],
])

let rpcHeight = ref(backfillHead)

// Every eth_getLogs the provider was asked, as `from-to address outcome`.
let getLogsCalls: array<string> = []

let envelope = (request, field, value) =>
  JSON.stringify(
    JSON.Object(
      Dict.fromArray([
        ("jsonrpc", JSON.String("2.0")),
        ("id", request->Dict.getUnsafe("id")),
        (field, value),
      ]),
    ),
  )

// A log filter as `events addresses`, e.g. `Transfer any` for an address-free one.
let describeLogFilter = (filter: ServedEvmChain.logFilter) => {
  let events =
    filter.topics
    ->Array.get(0)
    ->Option.getOr([])
    ->Array.map(topic0 => topic0 == pairCreated ? "PairCreated" : "Transfer")
    ->Array.join(",")
  let addresses = switch filter.address {
  | [] => "any"
  | addresses => addresses->Array.join(",")
  }
  `${events} ${addresses}`
}

let _ = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.start(~port=rpcPort, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let params = request->Dict.getUnsafe("params")
    switch request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow {
    | "eth_getLogs" =>
      let filter =
        params
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.getOrThrow
      let matched = logs->Array.filter(log => ServedEvmChain.rpcFilterMatches(filter, log))
      let capped = matched->Array.length > resultCap
      // A served block's hash is its number.
      let blocks = switch filter->Dict.get("blockHash") {
      | Some(hash) => `block ${hash->ServedEvmChain.quantity->Int.toString}`
      | None =>
        `${filter->Dict.getUnsafe("fromBlock")->ServedEvmChain.quantity->Int.toString}-${filter
          ->Dict.getUnsafe("toBlock")
          ->ServedEvmChain.quantity
          ->Int.toString}`
      }
      getLogsCalls
      ->Array.push(
        `${blocks} ${filter->ServedEvmChain.logFilter->describeLogFilter} ${capped
            ? "capped"
            : "ok"}`,
      )
      ->ignore
      (
        200,
        capped
          ? envelope(
              request,
              "error",
              JSON.Object(
                dict{
                  "code": JSON.Number(-32005.),
                  "message": JSON.String(
                    `query returned more than ${resultCap->Int.toString} results`,
                  ),
                },
              ),
            )
          : envelope(request, "result", JSON.Array(matched->Array.map(ServedEvmChain.rpcLog))),
      )
    | method => (
        200,
        envelope(
          request,
          "result",
          ServedEvmChain.rpcResult(~logs, ~height=rpcHeight.contents, ~method, ~params),
        ),
      )
    }
  })
)

let hyperSync: ref<option<MockHyperSyncServer.t>> = ref(None)
Async.beforeAll(async () => {
  let server = MockHyperSyncServer.make(~height=backfillHead, ~port=hyperSyncPort)
  server->MockHyperSyncServer.serveChain(ServedEvmChain.hyperSyncChain(~logs, ~height=lastBlock))
  hyperSync := Some(server)
})
Async.afterAll(async () => hyperSync.contents->Option.forEach(MockHyperSyncServer.close))
let hyperSyncServer = () =>
  hyperSync.contents->Option.getOrThrow(~message="the HyperSync server was never started")

let scenario = (~name, ~source) =>
  Scenario.make(
    ~configYaml=`
name: ${name}
rollback_on_reorg: false
contracts:
  - name: Factory
    events:
      - event: PairCreated(address pair)
  - name: Pair
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1337${source}
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Factory
      - name: Pair
`,
    ~schema=`
type Seen {
  id: ID!
}
`,
    ~handlers=`
import { indexer } from "envio";

// Wildcard, so the factory event shares the address-free query with the Pair
// events at the head: a registration then always lands after the routing of
// the response it came in, and the test doesn't race two partitions.
indexer.contractRegister(
  { contract: "Factory", event: "PairCreated", wildcard: true },
  async ({ event, context }) => {
    context.chain.Pair.add(event.params.pair);
  },
);

indexer.onEvent({ contract: "Pair", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}-\${event.logIndex}\` });
});
`,
  )

let rpcScenario = scenario(
  ~name="near-head-address-free-rpc",
  ~source=`
    rpc:
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync
      polling_interval: 10`,
)

let hyperSyncScenario = scenario(
  ~name="near-head-address-free-hypersync",
  ~source=`
    hypersync_config:
      url: ${ServedEvmChain.url(hyperSyncPort)}`,
)

type seen = {id: string}

let seenIds = async (indexer: IndexerRunner.t) => {
  let rows: array<seen> = await indexer.query("Seen")
  rows->Array.map(row => row.id)->Array.toSorted(String.compare)
}

let waitForSeen = async (indexer, id) => {
  let deadline = Date.now() +. 10_000.
  while !((await indexer->seenIds)->Array.includes(id)) {
    if Date.now() > deadline {
      JsError.throwWithMessage(`Timed out waiting for ${id} to be indexed`)
    }
    await Utils.delay(10)
  }
}

// The eth_getLogs calls made since the last take, sorted: a block's reads go
// out at once.
let takeRpcCalls = () => {
  let calls = getLogsCalls->Array.toSorted(String.compare)
  getLogsCalls->Utils.Array.clearInPlace
  calls
}

// The HyperSync queries made since the last take, as `fromBlock` and then each
// log selection, sorted.
let takeHyperSyncQueries = () =>
  hyperSyncServer()
  ->MockHyperSyncServer.takeQueries
  ->Array.map(query => {
    let query = query->JSON.Decode.object->Option.getOrThrow
    let fromBlock = query->Dict.getUnsafe("from_block")->JSON.Decode.float->Option.getOrThrow
    let selections = switch query->Dict.get("logs") {
    | Some(JSON.Array(selections)) =>
      selections->Array.map(selection =>
        selection
        ->JSON.Decode.object
        ->Option.getOrThrow
        ->ServedEvmChain.logFilter
        ->describeLogFilter
      )
    | _ => []
    }
    `${fromBlock->Float.toInt->Int.toString} ${selections->Array.join(" | ")}`
  })
  ->Array.toSorted(String.compare)

describe("Near-head address-free reads", () => {
  Async.it(
    "reads dynamic contracts over RPC address-free, by address over the result cap",
    async t => {
      await rpcScenario->Scenario.run(
        ~yamlSources=true,
        // A real RPC source against a local server: its requests resolve on real I/O.
        ~virtualTime=false,
        // One address per partition and per fallback request, so each Pair
        // address takes its own backfill query and its own fallback request.
        ~maxAddrInPartition=1,
        async (~indexer, ~source as _) => {
          await indexer->waitForSeen("3-1")
          await indexer.waitUntilReady()
          let backfill = takeRpcCalls()

          // Two new blocks at once, the first of them over the cap.
          rpcHeight := lastBlock
          await indexer->waitForSeen("302-1")
          let headBlocks = takeRpcCalls()

          t.expect((
            await indexer->seenIds,
            backfill->Array.filter(call => call->String.includes("Transfer any")),
            headBlocks,
            indexer.allLogsAsJson()->Array.filterMap(
              line =>
                switch (line->Dict.get("msg"), line->Dict.get("contractNames")) {
                | (Some(String(msg)), Some(contractNames))
                  if msg->String.includes("address-free") =>
                  Some((line->Dict.get("level"), contractNames, line->Dict.get("requests")))
                | _ => None
                },
            ),
          )).toEqual((
            ["3-0", "3-1", "301-1", "302-0", "302-1"],
            [],
            [
              // The capped block alone, still over the cap, is split up: the
              // wildcard event alone, still address-free, and the Pair events
              // by the two addresses registered before it, one per request.
              "301-301 PairCreated any ok",
              "301-301 PairCreated,Transfer any capped",
              `301-301 Transfer ${pair1} ok`,
              `301-301 Transfer ${pair2} ok`,
              // The contract registered in the block, caught up by its address.
              `301-301 Transfer ${pair3} ok`,
              // Over the cap on two blocks: the range shrinks before anything
              // is asked by address.
              "301-302 PairCreated,Transfer any capped",
              // The next block is asked address-free again.
              "302-302 PairCreated,Transfer any ok",
            ],
            // One trace line for the one fallback, counting its three requests.
            [
              (
                Some(JSON.String("trace")),
                JSON.Array([JSON.String("Pair")]),
                Some(JSON.Number(3.)),
              ),
            ],
          ))
        },
      )
    },
  )

  Async.it("reads dynamic contracts over HyperSync in one address-free query", async t => {
    await hyperSyncScenario->Scenario.run(
      ~yamlSources=true,
      // A real HyperSync source against a local server: its queries resolve on real I/O.
      ~virtualTime=false,
      ~maxAddrInPartition=1,
      async (~indexer, ~source as _) => {
        await indexer->waitForSeen("3-1")
        await indexer.waitUntilReady()
        let backfill = takeHyperSyncQueries()

        hyperSyncServer()->MockHyperSyncServer.setHeight(headBlock)
        await indexer->waitForSeen("301-1")
        let headBlock = takeHyperSyncQueries()

        hyperSyncServer()->MockHyperSyncServer.setHeight(lastBlock)
        await indexer->waitForSeen("302-1")
        let nextBlock = takeHyperSyncQueries()

        t.expect((
          await indexer->seenIds,
          backfill->Array.filter(query => query->String.includes("Transfer any")),
          headBlock,
          nextBlock,
        )).toEqual((
          ["3-0", "3-1", "301-1", "302-0", "302-1"],
          [],
          [
            "301 PairCreated,Transfer any",
            // The contract registered in the block, caught up by its address.
            `301 Transfer ${pair3}`,
          ],
          ["302 PairCreated,Transfer any"],
        ))
      },
    )
  })
})
