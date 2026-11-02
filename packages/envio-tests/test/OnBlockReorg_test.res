open Vitest

// A block handler selecting fields reads them off blocks the source fetched,
// so a reorg has to drop what it wrote from orphaned blocks and run it again on
// the new chain's, with the new chain's fields.

let scenario = Scenario.make(
  ~configYaml=`
name: on-block-reorg
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      # Starts past the head, so only the block handler's partition queries.
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
  timestamp: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.onBlock(
  {
    name: "stamps",
    where: () => ({ block: { number: { _gte: 51, _every: 100 } } }),
    fields: { block: ["timestamp", "hash"] },
  },
  async ({ block, context }) => {
    context.Stamp.set({ id: block.hash, number: block.number, timestamp: block.timestamp });
  },
);
`,
)

type stamp = {id: string, number: int, timestamp: int}

let stamps = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Stamp"))->Array.toSorted((a: stamp, b: stamp) =>
    a.number == b.number ? String.compare(a.id, b.id) : Int.compare(a.number, b.number)
  )

// Keyed by hash, so a row an orphaned block wrote can't hide behind the new
// chain's row for the same number.
let block = (blockNumber, ~hash, ~timestamp): MockSource.blockMock => {
  blockNumber,
  blockFields: dict{
    "hash": hash->(Utils.magic: string => unknown),
    "timestamp": timestamp->(Utils.magic: int => unknown),
  },
}

// The chain holds two partitions: the block handler's and the mock source's
// own event registration, which has nothing to return. Every pending query is
// answered from the chain as it now stands, until the rollback settles. On the
// re-orged chain every block above 100 has a new hash, which a query reports
// for the block before its range.
let answerFromChain = async (
  ~source: MockSource.t,
  ~blocks: array<MockSource.blockMock>,
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
        blocks: query.partitionId === "0"
          ? blocks->Array.filter(block =>
              block.blockNumber >= query.fromBlock && block.blockNumber <= toBlock
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

describe("A reorg under a block handler selecting fields", () => {
  scenario->Scenario.it(
    "runs it again on the new chain's blocks, with their fields",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await answerFromChain(
        ~source,
        ~blocks=[
          block(51, ~hash="0x51", ~timestamp=1051),
          block(151, ~hash="0x151", ~timestamp=1151),
          block(251, ~hash="0x251", ~timestamp=1251),
        ],
        ~head=300,
      )
      await indexer.waitUntilIdle()
      let beforeReorg = await stamps(indexer)

      // The next block arrives on a new chain: everything above 100 re-orged.
      source.resolveGetHeightOrThrow(301)
      await answerFromChain(
        ~source,
        ~blocks=[
          block(51, ~hash="0x51", ~timestamp=1051),
          block(151, ~hash="0x151a", ~timestamp=2151),
          block(251, ~hash="0x251a", ~timestamp=2251),
        ],
        ~head=301,
        ~reorged=true,
      )
      await indexer.waitUntilIdle()

      t.expect((beforeReorg, await stamps(indexer))).toEqual((
        [
          {id: "0x51", number: 51, timestamp: 1051},
          {id: "0x151", number: 151, timestamp: 1151},
          {id: "0x251", number: 251, timestamp: 1251},
        ],
        [
          {id: "0x51", number: 51, timestamp: 1051},
          {id: "0x151a", number: 151, timestamp: 2151},
          {id: "0x251a", number: 251, timestamp: 2251},
        ],
      ))
    },
  )
})
