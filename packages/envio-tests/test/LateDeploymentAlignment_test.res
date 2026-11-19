open Vitest

// https://github.com/enviodev/hyperindex/issues/1852
//
// Both chains are configured from block 0 and have a head of 1000. Chain 1's
// contract has no events before block 820, the way a contract deployed late in
// a chain's history has none, so its first query skips the empty prefix in one
// response. Chain 2 has events from its first block.
let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: late-deployment-alignment
rollback_on_reorg: false
full_batch_size: 5
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 2
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
)

let itemPerBlock = (~fromBlock, ~toBlock): array<MockSource.itemMock> =>
  Array.fromInitializer(~length=toBlock - fromBlock + 1, index => {
    MockSource.blockNumber: fromBlock + index,
    logIndex: 0,
  })

let pendingFromBlocks = (mock: MockSource.t) =>
  mock.pendingItemsQueries->Array.map(query => query.fromBlock)

let chainLogsAfterResume = (indexer: IndexerRunner.t) => {
  let lines = indexer.allLogsAsJson()
  let resumedAt =
    lines->Array.findIndex(line =>
      line->Dict.get("msg") ==
        Some(String("Successfully resumed indexing state! Continuing from the last checkpoint."))
    )
  lines
  ->Array.slice(~start=resumedAt + 1)
  ->Array.filterMap(line =>
    switch (line->Dict.get("chainId"), line->Dict.get("msg")) {
    | (Some(chainId), Some(msg)) => Some((chainId, msg))
    | _ => None
    }
  )
}

let startBothChains = async (~late: MockSource.t, ~dense: MockSource.t) => {
  late.resolveGetHeightOrThrow(1000)
  dense.resolveGetHeightOrThrow(1000)
  await late.expectItemsQueries([
    {
      fromBlock: 0,
      reply: Respond({
        items: itemPerBlock(~fromBlock=820, ~toBlock=826),
        latestFetchedBlockNumber: 826,
      }),
    },
  ])
  await dense.expectItemsQueries([
    {
      fromBlock: 0,
      reply: Respond({
        items: itemPerBlock(~fromBlock=0, ~toBlock=9),
        latestFetchedBlockNumber: 9,
      }),
    },
  ])
}

describe("A chain whose contract deploys late in its block range", () => {
  scenario->Scenario.it(
    "EXPECTED: keeps fetching while another chain is at the start of its own range",
    ~sources=[{chain: 1}, {chain: 2}],
    ~targetBufferSize=1000,
    async (~t as _, ~indexer, ~source) => {
      let late = source(1)
      let dense = source(2)
      await startBothChains(~late, ~dense)
      await indexer.waitUntilIdle()
      await late.expectItemsQueries([{fromBlock: 827, reply: LeavePending}])
    },
  )

  scenario->Scenario.it(
    "PIN: is parked until the other chain has fetched 62.6% of its own range",
    ~sources=[{chain: 1}, {chain: 2}],
    ~targetBufferSize=1000,
    async (~t, ~indexer, ~source) => {
      let late = source(1)
      let dense = source(2)
      await startBothChains(~late, ~dense)
      await indexer.waitUntilIdle()
      let afterFirstResponses = {
        "late": late->pendingFromBlocks,
        "dense": dense->pendingFromBlocks,
        "progress": await indexer.metric("envio_progress_block"),
      }

      await dense.respondUpTo(625)
      await indexer.waitUntilIdle()
      let denseAt625 = late->pendingFromBlocks

      await dense.respondUpTo(627)
      await indexer.waitUntilIdle()
      let denseAt627 = late->pendingFromBlocks

      t.expect((afterFirstResponses, denseAt625, denseAt627)).toEqual((
        {
          "late": [],
          "dense": [10],
          "progress": [
            {IndexerRunner.value: "826", labels: dict{"chainId": "1"}},
            {value: "9", labels: dict{"chainId": "2"}},
          ],
        },
        [],
        [827],
      ))
    },
  )

  scenario->Scenario.it(
    "PIN: after a restart it makes no request and logs nothing",
    ~sources=[{chain: 1}, {chain: 2}],
    ~targetBufferSize=1000,
    async (~t, ~indexer, ~source) => {
      let late = source(1)
      let dense = source(2)
      await startBothChains(~late, ~dense)
      await indexer.waitUntilIdle()
      await late.expectNewHeightCalls(1)

      let restarted = await indexer.restart()
      await restarted.waitUntilIdle()
      await late.expectNewHeightCalls(0)

      t.expect({
        "late": late->pendingFromBlocks,
        "dense": dense->pendingFromBlocks,
        "chainLogsAfterResume": restarted->chainLogsAfterResume,
      }).toEqual({
        "late": [],
        "dense": [10],
        "chainLogsAfterResume": [(JSON.Number(2.), JSON.String("Started querying"))],
      })
    },
  )
})
