open Vitest

// A query is sent with the shorter near-head request timeout once every
// partition of its chain is within 100 blocks of the head the chain can fetch,
// and with the backfill timeout before that. A chain that stops at an end block
// short of the head never follows the head, so it never uses the shorter one.
let scenarioOf = (~name, ~options="") =>
  Scenario.make(
    ~configYaml=`
name: ${name}
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1${options}
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
    ~schema=`
type Gravatar {
  id: ID!
}
`,
  )

let isNearHead = (query: MockSource.pendingItemsQuery) => query->MockSource.isNearHead
let isBackfill = (query: MockSource.pendingItemsQuery) => !(query->MockSource.isNearHead)

let upTo = block => MockSource.Respond({items: [], latestFetchedBlockNumber: block})

describe("Request timeout of an item query", () => {
  scenarioOf(
    ~name="request-timeouts",
  )->Scenario.it(
    "switches to the near-head timeout within 100 blocks of the head",
    ~sources=[{chain: 1337}],
    async (~t as _, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1_000)

      await sourceMock.expectItemsQueries([{fromBlock: 1, where: isBackfill, reply: upTo(800)}])
      // 200 blocks from the head.
      await sourceMock.expectItemsQueries([{fromBlock: 801, where: isBackfill, reply: upTo(900)}])
      await sourceMock.expectItemsQueries([
        {fromBlock: 901, where: isNearHead, reply: LeavePending},
      ])
    },
  )

  scenarioOf(
    ~name="request-timeouts-end-block",
    ~options="\n    end_block: 900",
  )->Scenario.it(
    "keeps the backfill timeout on a chain that ends short of the head",
    ~sources=[{chain: 1337}],
    async (~t as _, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1_000)

      await sourceMock.expectItemsQueries([{fromBlock: 1, where: isBackfill, reply: upTo(800)}])
      await sourceMock.expectItemsQueries([
        {fromBlock: 801, where: isBackfill, reply: LeavePending},
      ])
    },
  )
})
