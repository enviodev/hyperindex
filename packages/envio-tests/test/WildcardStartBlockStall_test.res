open Vitest

// https://github.com/enviodev/hyperindex/issues/1650
let configYaml = (~name) => `
name: ${name}
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
      - name: Bribe
        events:
          - event: "Bribe()"
`

let schema = `
type Gravatar {
  id: ID!
  owner: String!
}
`

let scenario = Scenario.make(
  ~configYaml=configYaml(~name="wildcard-start-block-stall"),
  ~schema,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.onEvent(
  {
    contract: "Bribe",
    event: "Bribe",
    wildcard: true,
    where: { block: { number: { _gte: 100000 } } },
  },
  async () => {},
);
`,
)

let wildcardOnlyScenario = Scenario.make(
  ~configYaml=`
name: wildcard-only-start-block
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Bribe
        events:
          - event: "Bribe()"
`,
  ~schema,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  {
    contract: "Bribe",
    event: "Bribe",
    wildcard: true,
    where: { block: { number: { _gte: 100000 } } },
  },
  async () => {},
);
`,
)

let sources = [
  {Scenario.chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
]

let pendingFromBlocks = (sourceMock: MockSource.t) =>
  sourceMock.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"])

describe("Wildcard event starting above the chain's start block", () => {
  scenario->Scenario.it(
    "keeps fetching the address partition until the wildcard's range is in reach",
    ~sources,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1_000_000)

      // Every open-ended probe is answered 20_000 blocks deep with no items,
      // so the chain stays cold and its target moves one cold range per round.
      let rounds = []
      for _ in 1 to 5 {
        await MockSource.waitItemsQuery(sourceMock)
        let fromBlocks = pendingFromBlocks(sourceMock)->Array.toSorted(Int.compare)
        rounds->Array.push(fromBlocks)->ignore
        let fromBlock = fromBlocks->Array.getUnsafe(0)
        sourceMock.resolveGetItemsOrThrow(
          [],
          ~filter=query => query["fromBlock"] === fromBlock,
          ~latestFetchedBlockNumber=fromBlock + 19_999,
        )
      }

      t.expect(rounds).toEqual([[1], [20_001], [40_001], [60_001], [80_001, 100_000]])
    },
  )

  wildcardOnlyScenario->Scenario.it(
    "starts a wildcard-only chain at the wildcard's start block",
    ~sources,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1_000_000)
      await MockSource.waitItemsQuery(sourceMock)

      t.expect(pendingFromBlocks(sourceMock)).toEqual([100_000])
    },
  )

  wildcardOnlyScenario->Scenario.it(
    "waits for the head to reach the wildcard's start block, then queries from it",
    ~sources,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(50_000)
      await Utils.delay(200)
      let belowStartBlock = pendingFromBlocks(sourceMock)

      sourceMock.setAutoHeight(1_000_000)
      await MockSource.waitItemsQuery(sourceMock)

      t.expect((belowStartBlock, pendingFromBlocks(sourceMock))).toEqual(([], [100_000]))
    },
  )
})
