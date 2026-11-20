open Vitest

// Transaction handlers fetch through a partition of their own, which a restart
// rebuilds from the committed progress. Each run counts itself, so a
// transaction the resumed run reads twice or skips shows in the counts.

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-restart
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      # Starts past the head, so only the transaction handler's partition reads.
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        start_block: 1000000
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Sent {
  id: ID!
  runs: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.onTransaction(
  { name: "sends", where: () => ({ transaction: { from: ["0x1111111111111111111111111111111111111111"] } }) },
  async ({ transaction, context }) => {
    const id = \`\${transaction.block.number}\`;
    const runs = ((await context.Sent.get(id))?.runs ?? 0) + 1;
    context.Sent.set({ id, runs });
  },
);
`,
)

type sent = {id: string, runs: int}

let sent = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Sent"))->Array.toSorted((a: sent, b: sent) =>
    Int.compare(a.id->Int.fromString->Option.getOr(0), b.id->Int.fromString->Option.getOr(0))
  )

let transactions = (~upTo) =>
  Array.fromInitializer(~length=(upTo - 51) / 100 + 1, i => {
    let transaction: MockSource.transactionMock = {
      blockNumber: 51 + i * 100,
      transactionIndex: 0,
      fields: dict{
        "from": "0x1111111111111111111111111111111111111111"->(Utils.magic: string => unknown),
      },
    }
    transaction
  })

// Answers every pending query from a chain whose head is `head`, recording
// where the transaction handler's partition asked to start.
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
        transactions: query.partitionId === "0"
          ? transactions(~upTo=head)->Array.filter(transaction =>
              transaction.blockNumber >= query.fromBlock && transaction.blockNumber <= toBlock
            )
          : [],
        latestFetchedBlockNumber: toBlock,
      })
    })
    await Utils.delay(0)
  }

describe("A restart under a transaction handler", () => {
  scenario->Scenario.it(
    "resumes where the committed progress left it, running each transaction once",
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

      t.expect((afterRestart->Array.get(0), await sent(restarted))).toEqual((
        Some(301),
        [51, 151, 251, 351, 451, 551]->Array.map(
          blockNumber => {
            id: blockNumber->Int.toString,
            runs: 1,
          },
        ),
      ))
    },
  )
})
