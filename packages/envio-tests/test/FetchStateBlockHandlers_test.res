open Vitest

let schema = `
type Run {
  id: ID!
  count: Int!
  last: Int!
}
`

let countBlocksHandler = `
import { indexer } from "envio";

indexer.onBlock(
  { name: "every", where: () => ({ block: { number: { _every: 1 } } }) },
  async ({ block, context }) => {
    const run = await context.Run.get("run");
    context.Run.set({ id: "run", count: (run?.count ?? 0) + 1, last: block.number });
  },
);
`

let chainHeader = `
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0`

// The wildcard starts past the head, so its partition sits ahead of the chain.
let laterWildcardStart = Scenario.make(
  ~configYaml=`
name: fetch-state-block-handlers-later-start
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
${chainHeader}
    contracts:
      - name: Token
        start_block: 500
`,
  ~schema,
  ~handlers=countBlocksHandler ++ `
indexer.onEvent({ contract: "Token", event: "Transfer", wildcard: true }, async () => {});
`,
)

let blockHandlersOnly = Scenario.make(
  ~configYaml=`
name: fetch-state-block-handlers-only
rollback_on_reorg: false
full_batch_size: 5
${chainHeader}
`,
  ~schema,
  ~handlers=countBlocksHandler,
)

// Block handlers interleave with events: each block's events run before its
// block handler, so `blocks` only ever grows by one per block.
let withEvents = Scenario.make(
  ~configYaml=`
name: fetch-state-block-handlers-with-events
rollback_on_reorg: false
full_batch_size: 100
contracts:
  - name: Token
    events:
      - event: Transfer()
${chainHeader}
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Run {
  id: ID!
  blocks: Int!
  events: Int!
  outOfOrder: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

type RunStore = {
  get: (id: string) => Promise<{ blocks: number; events: number; outOfOrder: number } | undefined>;
  set: (run: { id: string; blocks: number; events: number; outOfOrder: number }) => void;
};

const record = async (context: { Run: RunStore }, isBlock: boolean, blockNumber: number) => {
  const run = (await context.Run.get("run")) ?? { blocks: 0, events: 0, outOfOrder: 0 };
  context.Run.set({
    id: "run",
    blocks: run.blocks + (isBlock ? 1 : 0),
    events: run.events + (isBlock ? 0 : 1),
    outOfOrder: run.outOfOrder + (blockNumber === run.blocks ? 0 : 1),
  });
};

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  await record(context, false, event.block.number);
});

indexer.onBlock(
  { name: "every", where: () => ({ block: { number: { _every: 1 } } }) },
  async ({ block, context }) => {
    await record(context, true, block.number);
  },
);
`,
)

type run = {id: string, count: int, last: int}
type runWithEvents = {id: string, blocks: int, events: int, outOfOrder: int}

describe("FetchState block handlers", () => {
  laterWildcardStart->Scenario.it(
    "run no further than the head while a wildcard starts past it",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      await Scenario.resolveInitialHeight(~source=mock, ~head=100)
      await indexer.waitUntilIdle()
      let atHead100: array<run> = await indexer.query("Run")

      await mock.expectNewHeightCalls(1)
      mock.resolveGetHeightOrThrow(150)
      // Past the backfill, the chain at 150 waits for the next block.
      await mock.expectNewHeightCalls(1)
      await indexer.waitUntilIdle()
      let atHead150: array<run> = await indexer.query("Run")

      t.expect((atHead100, atHead150)).toEqual((
        [{id: "run", count: 101, last: 100}],
        [{id: "run", count: 151, last: 150}],
      ))
    },
  )

  blockHandlersOnly->Scenario.it(
    "run on a chain without contracts once its head is known, without item queries",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      await indexer.waitUntilIdle()
      let beforeHead: array<run> = await indexer.query("Run")

      mock.resolveGetHeightOrThrow(20)
      await indexer.waitUntilIdle()
      let atHead: array<run> = await indexer.query("Run")

      t.expect((beforeHead, atHead, mock.pendingItemsQueries)).toEqual((
        [],
        [{id: "run", count: 21, last: 20}],
        [],
      ))
    },
  )

  withEvents->Scenario.it(
    "run once per block in order while a full buffer of events runs past the known height",
    ~sources=[{chain: 1}],
    ~targetBufferSize=1000,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([
        {
          fromBlock: 0,
          reply: Respond({
            items: Array.fromInitializer(
              ~length=200,
              i => {
                MockSource.event: "Token.Transfer",
                blockNumber: 101 + i,
                logIndex: 0,
              },
            ),
            latestFetchedBlockNumber: 300,
            knownHeight: 300,
          }),
        },
      ])
      await indexer.waitUntilIdle()

      t.expect((await indexer.query("Run"): array<runWithEvents>)).toEqual([
        {id: "run", blocks: 301, events: 200, outOfOrder: 0},
      ])
    },
  )
})
