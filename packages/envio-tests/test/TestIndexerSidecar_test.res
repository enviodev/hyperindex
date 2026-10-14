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

// The same log feeds a second registration, whose own call count starts at 0
// again: the registration index keeps its ids apart from the first one's.
indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ event, context }) => {
  context.sidecar.notify({ text: \`again \${event.params.displayName}\` });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, defineSidecar, S, TestHelpers } from "envio";

const [owner] = TestHelpers.Addresses.mockAddresses;

const newGravatar = (displayName: string) => ({
  chains: {
    1: {
      startBlock: 1,
      endBlock: 100,
      simulate: [
        {
          contract: "Gravatar" as const,
          event: "NewGravatar" as const,
          params: { id: 7n, owner, displayName, imageUrl: "" },
          block: { number: 5 },
          logIndex: 3,
        },
      ],
    },
  },
});

describe("context.sidecar through a test indexer", () => {
  it("records each call once, with a deterministic id and the input's JSON form", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process(newGravatar("hi"));

    t.expect(result.changes).toEqual([
      {
        block: 5,
        chainId: 1,
        eventsProcessed: 1,
        sidecar: {
          calls: [
            { id: "1:5:3r2:0", fn: "priceSwap", input: { owner, amount: "7" } },
            { id: "1:5:3r2:1", fn: "notify", input: { text: "hi" } },
            { id: "1:5:3r3:0", fn: "notify", input: { text: "again hi" } },
          ],
        },
        Probe: { sets: [{ id: "1:5:3r2:0", callIds: "1:5:3r2:1,1:5:3r2:2" }] },
      },
    ]);
  });

  // A second contract in the same process (another fixture, another package of
  // a monorepo) must not rebind context.sidecar away from the configured one.
  it("keeps the configured contract when another one is defined in the process", async (t) => {
    defineSidecar({ functions: { unrelated: { input: { text: S.string } } } });
    const first = createTestIndexer();
    const second = createTestIndexer();
    const fns = async (indexer: typeof first, displayName: string) =>
      (await indexer.process(newGravatar(displayName))).changes.map((change) =>
        change.sidecar?.calls.map(({ fn, input }) => ({ fn, input })),
      );

    t.expect([await fns(first, "a"), await fns(second, "b")]).toEqual([
      [[
        { fn: "priceSwap", input: { owner, amount: "7" } },
        { fn: "notify", input: { text: "a" } },
        { fn: "notify", input: { text: "again a" } },
      ]],
      [[
        { fn: "priceSwap", input: { owner, amount: "7" } },
        { fn: "notify", input: { text: "b" } },
        { fn: "notify", input: { text: "again b" } },
      ]],
    ]);
  });
});
`,
)

// Without `sidecar:` in config.yaml, `context.sidecar` is the message saying
// what to add, so any call on it is a type error.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-sidecar-not-configured
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "NewGravatar(uint256 id, address owner, string displayName, string imageUrl)"
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ context }) => {
  const message: "context.sidecar is not available. Add \`sidecar: { contract, entry }\` in config.yaml and run 'envio codegen'" =
    context.sidecar;
  // @ts-expect-error no sidecar is configured
  context.sidecar.notify({ text: message });
});
`,
)
