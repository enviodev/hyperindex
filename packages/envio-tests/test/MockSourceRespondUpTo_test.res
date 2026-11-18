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
      await Scenario.resolveInitialHeight(~source=mock, ~head=100_000)
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
      await Scenario.resolveInitialHeight(~source=mock, ~head=100_000)
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
      await indexer.waitUntilIdle()
      let backfill =
        mock.pendingItemsQueries->Array.map(
          query => (
            query->MockSource.addresses->Array.map(Address.toString),
            query.fromBlock,
            query.toBlock,
          ),
        )
      await mock.respondUpTo(300)
      t.expect((
        backfill,
        (await indexer.metric("envio_progress_block"))->Array.map(
          ({value}: IndexerRunner.metric) => value,
        ),
      )).toEqual((
        [
          (["0x0000000000000000000000000000000000000002"], 50, Bounded(100)),
          (
            [
              "0x0000000000000000000000000000000000000001",
              "0x0000000000000000000000000000000000000002",
            ],
            101,
            Bounded(99800),
          ),
        ],
        ["300"],
      ))
    },
  )

  scenario->Scenario.it(
    "fails when the chain can't get to the block with the queries it has",
    ~sources=[{chain: 1}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      await Scenario.resolveInitialHeight(~source=mock, ~head=200)
      t.expect(
        switch await mock.respondUpTo(300) {
        | () => None
        | exception JsExn(error) => error->JsExn.message
        },
      ).toEqual(
        Some(
          "respondUpTo(300) stopped with the chain at block 200: no query asks for a block up to 300. A height the chain doesn't know yet, or a timer it waits on, holds it back.",
        ),
      )
    },
  )
  scenario->Scenario.it("fails on an item no reply covers", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer as _,
    ~source,
  ) => {
    let mock = source(1)
    await Scenario.resolveInitialHeight(~source=mock, ~head=100_000)
    await mock.expectItemsQueries([{reply: Respond({items: [], latestFetchedBlockNumber: 100})}])
    t.expect(
      switch await mock.respondUpTo(
        300,
        ~items=[
          {
            event: "Gravatar.TestEvent",
            blockNumber: 50,
            logIndex: 0,
            srcAddress: "0x0000000000000000000000000000000000000001",
          },
        ],
      ) {
      | () => None
      | exception JsExn(error) => error->JsExn.message
      },
    ).toEqual(
      Some("respondUpTo(300) answered no query covering block 50 log 0, so no reply delivered it."),
    )
  })

  scenario->Scenario.it(
    "names the query that dropped an item it doesn't fetch the address of",
    ~sources=[{chain: 1}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      await Scenario.resolveInitialHeight(~source=mock, ~head=100_000)
      await mock.respondUpTo(
        100,
        ~items=[
          {
            event: "Gravatar.TestEvent",
            blockNumber: 40,
            logIndex: 0,
            srcAddress: "0x0000000000000000000000000000000000000099",
          },
        ],
      )
      t.expect(
        mock.describeState()
        ->String.split("\n")
        ->Array.filter(line => line->String.includes("dropped")),
      ).toEqual([
        "  items dropped by a query that doesn't fetch their address: block 40 log 0 from 0x0000000000000000000000000000000000000099 by partition 0 at 1..100",
      ])
    },
  )
})
