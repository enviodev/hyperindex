open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: entity-timestamp
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type EntityWithTimestamp {
  id: ID!
  timestamp: Timestamp!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ context }) => {
  context.EntityWithTimestamp.set({
    id: "testEntity",
    timestamp: new Date("1970-01-01T00:02:03.456Z"),
  });
});
`,
)

type entityWithTimestamp = {id: string, timestamp: Date.t}

describe("Load and save an entity with a Timestamp from DB", () => {
  scenario->Scenario.it(
    "be able to set and read entities with Timestamp from DB",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(300)
      await source.expectItemsQueries([
        {
          fromBlock: 1,
          toBlock: Bounded(100),
          reply: Respond({
            items: [{event: "Gravatar.TestEvent", blockNumber: 100, logIndex: 0}],
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let entities: array<entityWithTimestamp> = await indexer.query("EntityWithTimestamp")

      t.expect(
        entities->Array.map(entity => (entity.id, entity.timestamp->Date.toISOString)),
      ).toEqual([("testEntity", "1970-01-01T00:02:03.456Z")])
    },
  )
})
