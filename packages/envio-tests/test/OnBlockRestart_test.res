open Vitest

// A block handler selecting fields is fetched by a partition of its own, which
// a restart rebuilds from the committed progress. Each run counts itself, so a
// block the resumed run reads twice or skips shows in the counts.

let scenario = Scenario.make(
  ~configYaml=`
name: on-block-restart
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      # Starts past the head, so only the block handler's partition reads blocks.
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        start_block: 1000000
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Stamp {
  id: ID!
  timestamp: Int!
  runs: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.onBlock(
  {
    name: "stamps",
    where: () => ({ block: { number: { _gte: 51, _every: 100 } } }),
    fields: { block: ["timestamp"] },
  },
  async ({ block, context }) => {
    const id = \`\${block.number}\`;
    const runs = ((await context.Stamp.get(id))?.runs ?? 0) + 1;
    context.Stamp.set({ id, timestamp: block.timestamp, runs });
  },
);
`,
)

type stamp = {id: string, timestamp: int, runs: int}

let stamps = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Stamp"))->Array.toSorted((a: stamp, b: stamp) =>
    Int.compare(a.id->Int.fromString->Option.getOr(0), b.id->Int.fromString->Option.getOr(0))
  )

let handlerBlocks = (~upTo) =>
  Array.fromInitializer(~length=(upTo - 51) / 100 + 1, i => {
    let blockNumber = 51 + i * 100
    let block: MockSource.blockMock = {
      blockNumber,
      blockFields: dict{"timestamp": (1000 + blockNumber)->(Utils.magic: int => unknown)},
    }
    block
  })

// Answers every pending query from a chain whose head is `head`, recording
// where the block handler's partition asked to start.
let answerUpTo = async (~source: MockSource.t, ~head, ~fromBlocks: array<int>) =>
  for _ in 0 to 300 {
    source.pendingItemsQueries
    ->Array.copy
    ->Array.forEach(query => {
      let toBlock = switch query.toBlock {
      | Bounded(toBlock) => Pervasives.min(toBlock, head)
      | Unbounded => head
      }
      if query.partitionId === "0" {
        fromBlocks->Array.push(query.fromBlock)->ignore
      }
      (query->MockSource.control).respond({
        items: [],
        blocks: query.partitionId === "0"
          ? handlerBlocks(~upTo=head)->Array.filter(block =>
              block.blockNumber >= query.fromBlock && block.blockNumber <= toBlock
            )
          : [],
        latestFetchedBlockNumber: toBlock,
      })
    })
    await Utils.delay(0)
  }

describe("A restart under a block handler selecting fields", () => {
  scenario->Scenario.it(
    "resumes where the committed progress left it, running each block once",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.setAutoHeight(300)
      let beforeRestart = []
      await answerUpTo(~source, ~head=300, ~fromBlocks=beforeRestart)
      await indexer.waitUntilIdle()

      source.setAutoHeight(600)
      let restarted = await indexer.restart()
      let afterRestart = []
      await answerUpTo(~source, ~head=600, ~fromBlocks=afterRestart)
      await restarted.waitUntilIdle()

      t.expect((afterRestart->Array.get(0), await stamps(restarted))).toEqual((
        Some(301),
        [51, 151, 251, 351, 451, 551]->Array.map(
          blockNumber => {
            id: blockNumber->Int.toString,
            timestamp: 1000 + blockNumber,
            runs: 1,
          },
        ),
      ))
    },
  )
})
