// `context.sidecar.<fn>(input)`: typed from the contract, returns the call id
// at once, and records the call on the batch for delivery after the commit.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-sidecar
sidecar:
  contract: src/sidecar/contract.ts
  entry: src/sidecar/index.ts
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "NewGravatar(uint256 id, address owner, string displayName, string imageUrl)"
`,
  ~schema=`
type Probe {
  id: ID!
  callIds: String!
}
`,
  ~sidecarContract=`
import { defineSidecar, S } from "envio";

export default defineSidecar({
  functions: {
    priceSwap: { input: { owner: S.string, amount: S.bigint } },
    notify: { input: { text: S.string } },
  },
});
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ event, context }) => {
  const priced: string = context.sidecar.priceSwap({ owner: event.params.owner, amount: event.params.id });
  const notified = context.sidecar.notify({ text: event.params.displayName });
  // Input that slipped past the types is dropped, never thrown into the handler.
  const dropped = context.sidecar.notify({ text: 42 } as unknown as { text: string });
  context.Probe.set({ id: priced, callIds: [notified, dropped].join(",") });

  if (event.params.displayName === "never") {
    // @ts-expect-error not a function of the contract
    context.sidecar.missing({});
    // @ts-expect-error the input doesn't match the contract's schema
    context.sidecar.notify({ text: 1 });
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const [owner] = TestHelpers.Addresses.mockAddresses;

describe("context.sidecar through a test indexer", () => {
  it("records each call once, with a deterministic id and the input's JSON form", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: { id: 7n, owner, displayName: "hi", imageUrl: "" },
              block: { number: 5 },
              logIndex: 3,
            },
          ],
        },
      },
    });

    t.expect(result.changes).toEqual([
      {
        block: 5,
        chainId: 1,
        eventsProcessed: 1,
        sidecar: {
          calls: [
            { id: "1:5:3:0", fn: "priceSwap", input: { owner, amount: "7" } },
            { id: "1:5:3:1", fn: "notify", input: { text: "hi" } },
          ],
        },
        Probe: { sets: [{ id: "1:5:3:0", callIds: "1:5:3:1,1:5:3:2" }] },
      },
    ]);
  });
});
`,
)
