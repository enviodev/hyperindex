open Vitest

// `respondUpTo` answers every query the indexer has for blocks up to the one
// given, waiting for the indexer to settle between waves, so a partition that
// ends below it or appears on the way is answered too.
let scenario = Scenario.make(
  ~configYaml=`
name: mock-source-respond-up-to
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

type Event = { block: { number: number }; srcAddress: string };

indexer.contractRegister({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  if (event.block.number === 50) context.chain.Gravatar.add("0x0000000000000000000000000000000000000002");
});

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.srcAddress}@\${event.block.number}\` });
});
`,
)

type seen = {id: string}

describe("MockSource.respondUpTo", () => {
  scenario->Scenario.it(
    "answers a backfill bounded below the block and delivers the items each range covers",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.respondUpTo(
        300,
        ~items=[
          {
            event: "Gravatar.TestEvent",
            blockNumber: 50,
            logIndex: 0,
            srcAddress: "0x0000000000000000000000000000000000000001",
          },
          {
            event: "Gravatar.TestEvent",
            blockNumber: 60,
            logIndex: 0,
            srcAddress: "0x0000000000000000000000000000000000000002",
          },
          {
            event: "Gravatar.TestEvent",
            blockNumber: 250,
            logIndex: 0,
            srcAddress: "0x0000000000000000000000000000000000000002",
          },
        ],
      )
      t.expect(
        (await indexer.query("Seen"): array<seen>)
        ->Array.map(({id}) => id)
        ->Array.toSorted(String.compare),
      ).toEqual([
        "0x0000000000000000000000000000000000000001@50",
        "0x0000000000000000000000000000000000000002@250",
        "0x0000000000000000000000000000000000000002@60",
      ])
    },
  )

  scenario->Scenario.it(
    "fetches empty ranges past a backfill bounded below the block",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {
          reply: Respond({
            items: [
              {
                event: "Gravatar.TestEvent",
                blockNumber: 50,
                logIndex: 0,
                srcAddress: "0x0000000000000000000000000000000000000001",
              },
            ],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await mock.respondEmptyUpTo(300)
      t.expect(
        (await indexer.metric("envio_progress_block"))->Array.map(
          ({value}: IndexerRunner.metric) => value,
        ),
      ).toEqual(["300"])
    },
  )
})
