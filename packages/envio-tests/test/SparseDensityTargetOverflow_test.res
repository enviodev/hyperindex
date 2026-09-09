open Vitest

// A sparse chain freezes at head: with a low events-per-block density, the
// target-block computation `bufferBlockNumber + ceil(chainTargetItems /
// density)` exceeds 2^31 and the float-to-int truncation wraps negative, so
// the target collapses below every partition's cursor and getNextQuery never
// emits a query again. The wait loop keeps finding new blocks (knownHeight
// advances) while the frontier and progress stay frozen — the chain-42161
// incident on 3.5.1.
//
// One event across 30k blocks seeds chainDensity = 1/30000; with the 100k
// buffer target the division is ~3e9, which truncates to a negative int.
let scenario = Scenario.make(
  ~configYaml=`
name: sparse-density
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("Sparse-density target overflow", () => {
  scenario->Scenario.it(
    "keeps fetching new head blocks when the chain density is very low",
    ~sources=[
      {
        chain: 1337,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        pollingInterval: 1,
      },
    ],
    ~targetBufferSize=100_000,
    ~reducedPollingInterval=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)

      sourceMock.resolveGetHeightOrThrow(30_000)
      await Utils.delay(0)
      await Utils.delay(0)

      // One event over the whole 30k-block range: the batch seeds the chain
      // density at ~1/30000 events per block.
      await MockSource.waitItemsQuery(sourceMock)
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 5, logIndex: 0}],
        ~latestFetchedBlockNumber=30_000,
      )
      await indexer.getBatchWritePromise()

      // A new block arrives. The chain is one block behind the head and must
      // query it — on the broken version the wrapped target block leaves every
      // partition out of range and the chain only ever waits.
      let attempts = ref(0)
      while sourceMock.getItemsOrThrowCalls->Array.length === 0 && attempts.contents < 2000 {
        attempts := attempts.contents + 1
        try sourceMock.resolveGetHeightOrThrow(30_001) catch {
        | _ => ()
        }
        await Utils.delay(1)
      }
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="the chain should query the new head block despite its low event density",
      ).toEqual([30_001])
    },
  )
})
