open Vitest

// A batch takes chains in priority order: a chain with a full batch ready first,
// then the chain furthest behind its head. Progress is measured from the chain's
// first event block, so every chain processes one event at block 1 before the
// batch under test is built. Chain 4 holds processing while the chains under
// test buffer, so they all land in the same batch.
let chainYaml = id =>
  `
  - id: ${id->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-batch-priority
rollback_on_reorg: false
full_batch_size: 2
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${[1, 2, 3, 4]->Array.map(chainYaml)->Array.join("")}
`,
  ~schema=`
type Run {
  id: ID!
  order: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  if (event.block.number === 1) {
    return;
  }
  const label = \`\${event.chainId}@\${event.block.number}\`;
  const run = await context.Run.get("run");
  context.Run.set({ id: "run", order: run ? run.order + " " + label : label });
});
`,
)

type run = {id: string, order: string}

let sources: array<Scenario.sourceMock> = [{chain: 1}, {chain: 2}, {chain: 3}, {chain: 4}]

let transferAt = (blockNumber): MockSource.itemMock => {
  event: "Token.Transfer",
  blockNumber,
  logIndex: 0,
}

let handlerOrder = async (
  ~indexer: IndexerRunner.t,
  ~source: (int, ~index: int=?) => MockSource.t,
  ~itemBlocksByChain: array<(int, array<int>)>,
) => {
  sources->Array.forEach(({chain}) => source(chain).resolveGetHeightOrThrow(100))
  for i in 0 to itemBlocksByChain->Array.length - 1 {
    let (chain, _) = itemBlocksByChain->Array.getUnsafe(i)
    await source(chain).expectItemsQueries([
      {fromBlock: 1, reply: Respond({items: [transferAt(1)], latestFetchedBlockNumber: 1})},
    ])
  }
  await indexer.waitUntilIdle()

  let holdProcessing = MockSource.Gate.make()
  await source(4).expectItemsQueries([
    {
      fromBlock: 1,
      reply: Respond({
        items: [{blockNumber: 1, logIndex: 0, handler: _ => holdProcessing.wait()}],
        latestFetchedBlockNumber: 1,
      }),
    },
  ])
  // Real time: handlers run off the clock.
  await Scenario.waitUntil(
    () => holdProcessing.entered.contents > 0,
    ~message="chain 4 to hold processing",
  )

  for i in 0 to itemBlocksByChain->Array.length - 1 {
    let (chain, blocks) = itemBlocksByChain->Array.getUnsafe(i)
    await source(chain).expectItemsQueries([
      {
        fromBlock: 2,
        reply: Respond({items: blocks->Array.map(transferAt), latestFetchedBlockNumber: 95}),
      },
    ])
  }
  holdProcessing.release()
  await indexer.waitUntilIdle()
  let runs: array<run> = await indexer.query("Run")
  runs
}

describe("FetchState batch priority across chains", () => {
  scenario->Scenario.it(
    "takes the chain furthest behind its head first",
    ~sources,
    ~targetBufferSize=1000,
    async (~t, ~indexer, ~source) => {
      let runs = await handlerOrder(
        ~indexer,
        ~source,
        ~itemBlocksByChain=[(1, [80]), (2, [10]), (3, [50])],
      )
      t.expect(runs).toEqual([{id: "run", order: "2@10 3@50 1@80"}])
    },
  )

  // Chain 3 is never answered here, so its first probe holds its 5000-item
  // page throughout: the pool leaves room beside it for the other chains.
  scenario->Scenario.it(
    "takes a chain with a full batch before one further behind",
    ~sources,
    ~targetBufferSize=100_000,
    async (~t, ~indexer, ~source) => {
      let runs = await handlerOrder(
        ~indexer,
        ~source,
        ~itemBlocksByChain=[(1, [10]), (2, [70, 80, 90])],
      )
      t.expect(runs).toEqual([{id: "run", order: "2@70 2@80 1@10 2@90"}])
    },
  )

  scenario->Scenario.it(
    "counts a chain holding exactly a batch as full",
    ~sources,
    ~targetBufferSize=100_000,
    async (~t, ~indexer, ~source) => {
      let runs = await handlerOrder(
        ~indexer,
        ~source,
        ~itemBlocksByChain=[(1, [10]), (2, [20, 30])],
      )
      t.expect(runs).toEqual([{id: "run", order: "2@20 2@30 1@10"}])
    },
  )
})
