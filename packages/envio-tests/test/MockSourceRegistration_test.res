open Vitest

// A mock source delivers its own items through a synthetic registration. A
// scenario names the contract it joins, so a contract without handlers that
// sorts first doesn't get its addresses fetched.
let scenario = Scenario.make(
  ~configYaml=`
name: mock-source-registration
contracts:
  - name: Alpha
    events:
      - event: Transfer()
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Alpha
        address: "0x00000000000000000000000000000000000000a1"
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Counter {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Counter.set({ id: \`\${event.srcAddress}@\${event.block.number}\` });
});
`,
)

describe("MockSource's own registration", () => {
  scenario->Scenario.it(
    "keeps a contract without handlers out of every query",
    ~sources=[{chain: 1, mockEventContract: "Token"}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([{reply: LeavePending}])
      await indexer.waitUntilIdle()
      t.expect(
        mock.pendingItemsQueries->Array.map(
          query => query->MockSource.addresses->Array.map(Address.toString),
        ),
      ).toEqual([["0x0000000000000000000000000000000000000001"]])
    },
  )

  scenario->Scenario.it(
    "delivers an item only from an address the query fetches",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {
          reply: Respond({
            items: [
              {
                event: "Token.Transfer",
                blockNumber: 5,
                logIndex: 0,
                srcAddress: "0x0000000000000000000000000000000000000001",
              },
              {
                event: "Token.Transfer",
                blockNumber: 6,
                logIndex: 0,
                srcAddress: "0x0000000000000000000000000000000000000099",
              },
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      t.expect((await indexer.query("Counter"): array<{"id": string}>)).toEqual([
        {"id": "0x0000000000000000000000000000000000000001@5"},
      ])
    },
  )
})
