open Vitest

// A transaction handler runs on the rows a source fetched, so a reorg has to
// drop what it wrote from orphaned blocks and run it again on the new chain's
// transactions.

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-reorg
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
  number: Int!
  value: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.onTransaction(
  {
    name: "sends",
    where: () => ({ transaction: { from: ["0x1111111111111111111111111111111111111111"] } }),
    fields: { transaction: ["value"] },
  },
  async ({ transaction, block, context }) => {
    context.Sent.set({ id: transaction.hash, number: block.number, value: transaction.value });
  },
);
`,
)

type sent = {id: string, number: int, value: bigint}

let sent = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Sent"))->Array.toSorted((a: sent, b: sent) =>
    a.number == b.number ? String.compare(a.id, b.id) : Int.compare(a.number, b.number)
  )

let hash = marker => "0x" ++ marker->String.padStart(64, "0")

// Keyed by hash, so a row an orphaned transaction wrote can't hide behind the
// new chain's row for the same block.
let transaction = (blockNumber, ~marker, ~value): MockSource.transactionMock => {
  blockNumber,
  transactionIndex: 0,
  fields: dict{
    "hash": hash(marker)->(Utils.magic: string => unknown),
    "from": "0x1111111111111111111111111111111111111111"->(Utils.magic: string => unknown),
    "value": value->(Utils.magic: bigint => unknown),
  },
}

// Every pending query is answered from the chain as it now stands, until the
// rollback settles. On the re-orged chain every block above 100 has a new
// hash, which a query reports for the block before its range.
let answerFromChain = async (
  ~source: MockSource.t,
  ~transactions: array<MockSource.transactionMock>,
  ~head,
  ~reorged=false,
) =>
  for _ in 0 to 300 {
    if source.getBlockHashesCalls->Array.length > 0 {
      let requested = source.getBlockHashesCalls->Array.copy
      source.resolveGetBlockHashes(
        requested
        ->Array.flat
        ->Array.map((blockNumber): BufferPage.observedBlock => {
          blockNumber,
          blockHash: blockNumber <= 100
            ? `0x${blockNumber->Int.toString}`
            : `0x${blockNumber->Int.toString}a`,
          blockTimestamp: blockNumber,
        }),
      )
      source.getBlockHashesCalls->Utils.Array.clearInPlace
    }
    source.pendingItemsQueries
    ->Array.copy
    ->Array.forEach(query => {
      let toBlock = switch query.toBlock {
      | Bounded(toBlock) => Pervasives.min(toBlock, head)
      | Unbounded => head
      }
      (query->MockSource.control).respond({
        items: [],
        transactions: query.partitionId === "0"
          ? transactions->Array.filter(transaction =>
              transaction.blockNumber >= query.fromBlock && transaction.blockNumber <= toBlock
            )
          : [],
        latestFetchedBlockNumber: toBlock,
        prevRangeLastBlock: ?(
          reorged && query.fromBlock - 1 > 100
            ? Some({
                ReorgDetection.blockNumber: query.fromBlock - 1,
                blockHash: `0x${(query.fromBlock - 1)->Int.toString}a`,
              })
            : None
        ),
      })
    })
    await Utils.delay(0)
  }

describe("A reorg under a transaction handler", () => {
  scenario->Scenario.it(
    "runs it again on the new chain's transactions",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await answerFromChain(
        ~source,
        ~transactions=[
          transaction(51, ~marker="51", ~value=1n),
          transaction(151, ~marker="151", ~value=2n),
          transaction(251, ~marker="251", ~value=3n),
        ],
        ~head=300,
      )
      await indexer.waitUntilIdle()
      let beforeReorg = await sent(indexer)

      // The next block arrives on a new chain: everything above 100 re-orged,
      // and block 251's transaction is gone.
      source.resolveGetHeightOrThrow(301)
      await answerFromChain(
        ~source,
        ~transactions=[
          transaction(51, ~marker="51", ~value=1n),
          transaction(151, ~marker="151a", ~value=20n),
          transaction(201, ~marker="201a", ~value=30n),
        ],
        ~head=301,
        ~reorged=true,
      )
      await indexer.waitUntilIdle()

      t.expect((beforeReorg, await sent(indexer))).toEqual((
        [
          {id: hash("51"), number: 51, value: 1n},
          {id: hash("151"), number: 151, value: 2n},
          {id: hash("251"), number: 251, value: 3n},
        ],
        [
          {id: hash("51"), number: 51, value: 1n},
          {id: hash("151a"), number: 151, value: 20n},
          {id: hash("201a"), number: 201, value: 30n},
        ],
      ))
    },
  )
})
