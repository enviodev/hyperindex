open Vitest

// End-to-end guard that switching a contract to client-side address filtering
// never double-processes an event. When the switch collapses a contract's
// partitions into one address-free partition at their minimum frontier, the
// address-free partition re-fetches the overlap; those re-delivered events must be
// deduped against the ones still in the buffer (nothing above the min frontier
// has been processed yet).
let scenario = Scenario.make(
  ~configYaml=`
name: client-filter-dedup
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
`,
  ~schema=`
type Processed {
  id: ID!
  times: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.contractRegister({ contract: "Gravatar", event: "TestEvent" }, async ({ context }) => {
  context.chain.Gravatar.add("0x1111111111111111111111111111111111111111");
  context.chain.Gravatar.add("0x2222222222222222222222222222222222222222");
  context.chain.Gravatar.add("0x3333333333333333333333333333333333333333");
});

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  const id = \`\${event.block.number}-\${event.logIndex}\`;
  const existing = await context.Processed.get(id);
  context.Processed.set({ id, times: (existing?.times ?? 0) + 1 });
});
`,
)

type processed = {id: string, times: int}

describe("Client-side address filtering item dedup", () => {
  scenario->Scenario.it(
    "does not process an event twice across the switch to client-side filtering",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    // Switch Gravatar to client-side filtering as soon as it has >2 registered addresses.
    ~clientFilterAddressThreshold=2,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)

      sourceMock.resolveGetHeightOrThrow(1000)

      // Fetch a Gravatar event at block 10 that registers 3 dynamic Gravatar
      // addresses. That pushes Gravatar past the threshold and collapses its
      // partitions into a single address-free partition mid-response.
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({
            items: [{event: "Gravatar.TestEvent", blockNumber: 10, logIndex: 0}],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])

      // The switch dragged the collapsed partition's frontier back below block 10,
      // so a newly issued query re-queries a range covering block 10 — the
      // overlap the dedup must absorb. It re-delivers the block-10 event;
      // advance it to the head so the buffered block-10 event becomes
      // processable. The re-delivered copy must be deduped.
      await sourceMock.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 1,
          toBlock: Bounded(800),
          reply: Respond({
            items: [{event: "Gravatar.TestEvent", blockNumber: 10, logIndex: 0}],
            latestFetchedBlockNumber: 200,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (await indexer.query("Processed"): array<processed>),
        ~message="the block-10 event is processed exactly once despite the backfill re-fetch",
      ).toEqual([{id: "10-0", times: 1}])
    },
  )
})
