open Vitest

// A reorg drops what a transaction handler wrote from orphaned blocks and runs
// it again on the new chain's transactions.

let wallet = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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
      # Starts past the head, so only the transaction handler's partition queries.
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        start_block: 1000000
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Stamp {
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
    name: "stamps",
    where: () => ({ transaction: { from: ["${wallet}"] } }),
    fields: { transaction: ["value"] },
  },
  async ({ transaction, block, context }) => {
    context.Stamp.set({ id: transaction.hash, number: block.number, value: transaction.value });
  },
);
`,
)

type stamp = {id: string, number: int, value: bigint}

let stamps = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Stamp"))->Array.toSorted((a: stamp, b: stamp) =>
    Int.compare(a.number, b.number)
  )

// Keyed by the hash the mock derives from the coordinates, so a transaction
// the new chain holds at another position gets a new row and the orphaned one
// has to go.
let transaction = (blockNumber, ~value): MockSource.transactionMock => {
  blockNumber,
  transactionIndex: 0,
  transactionFields: dict{
    "from": wallet->(Utils.magic: string => unknown),
    "value": value->(Utils.magic: bigint => unknown),
  },
}

let hashOf = blockNumber => MockSource.evmBlockHash(`0x${blockNumber->Int.toString}0`)

// Two partitions: the transaction handler's and the mock source's own event
// registration, which returns nothing. Above block 100 the re-orged chain has
// new hashes, reported for the block before a query's range.
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
        ->Array.map((blockNumber): BlockStore.inputBlock => {
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
          ? transactions->Array.filter(tx =>
              tx.blockNumber >= query.fromBlock && tx.blockNumber <= toBlock
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
          transaction(51, ~value=1n),
          transaction(151, ~value=2n),
          transaction(251, ~value=3n),
        ],
        ~head=300,
      )
      await indexer.waitUntilIdle()
      let beforeReorg = await stamps(indexer)

      // The next block arrives on a new chain: everything above 100 re-orged.
      // The second transaction moved a block, the third changed.
      source.resolveGetHeightOrThrow(301)
      await answerFromChain(
        ~source,
        ~transactions=[
          transaction(51, ~value=1n),
          transaction(152, ~value=2n),
          transaction(251, ~value=30n),
        ],
        ~head=301,
        ~reorged=true,
      )
      await indexer.waitUntilIdle()

      t.expect((beforeReorg, await stamps(indexer))).toEqual((
        [
          {id: hashOf(51), number: 51, value: 1n},
          {id: hashOf(151), number: 151, value: 2n},
          {id: hashOf(251), number: 251, value: 3n},
        ],
        [
          {id: hashOf(51), number: 51, value: 1n},
          {id: hashOf(152), number: 152, value: 2n},
          {id: hashOf(251), number: 251, value: 30n},
        ],
      ))
    },
  )
})
