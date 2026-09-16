// Effects reached through a test indexer, and how a throw from a handler or an
// effect surfaces at the process() call site.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-effects
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "FactoryEvent(address indexed contract, string testCase)"
      - name: SimpleNft
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
`,
  ~schema=`
type Probe {
  id: ID!
  value: String!
}
`,
  ~handlers=`
import { indexer, createEffect, S } from "envio";

const cachedEffect = createEffect(
  { name: "cachedEffect", input: { id: S.string }, output: S.string, rateLimit: false, cache: true },
  async ({ input }) => "test-" + input.id
);

const throwingEffect = createEffect(
  { name: "throwingEffect", input: { id: S.string }, output: S.string, rateLimit: false },
  async () => {
    throw new Error("Error from effect");
  }
);

indexer.contractRegister({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (event.params.testCase === "registerAndCachedEffect") {
    context.chain.SimpleNft.add(event.params.contract);
  }
});

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (context.isPreload) {
    return;
  }
  switch (event.params.testCase) {
    case "cachedEffect":
    case "registerAndCachedEffect": {
      const key = event.block.number.toString();
      const value = await context.effect(cachedEffect, { id: key });
      context.Probe.set({ id: key, value });
      return;
    }
    case "throwingEffect":
      await context.effect(throwingEffect, { id: "1" });
      return;
    case "throwInHandler":
      throw new Error("Error from handler");
  }
});

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async () => {});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Address } from "envio";

const dcAddress: Address = "0x1234567890123456789012345678901234567890";

const item = (testCase: string, blockNumber: number) => ({
  contract: "Gravatar" as const,
  event: "FactoryEvent" as const,
  params: { contract: dcAddress, testCase },
  block: { number: blockNumber },
});

describe("Effects through a test indexer", () => {
  it("runs a cached effect once per distinct key", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [item("cachedEffect", 2), item("cachedEffect", 3)],
        },
      },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([
      { id: "2", value: "test-2" },
      { id: "3", value: "test-3" },
    ]);
  });

  // Regression: handleLoad crashed with "Cannot read properties of undefined
  // (reading 'table')" when a later batch loaded a cached effect back. The load
  // passes the effect-cache table (envio_effect_<name>), which isn't among the
  // entity configs. A contractRegister at a later block is what splits the run
  // into the two batches this needs.
  it("loads a cached effect in a batch split off by a later registration", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 10,
          simulate: [item("cachedEffect", 2), item("registerAndCachedEffect", 3)],
        },
      },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([
      { id: "2", value: "test-2" },
      { id: "3", value: "test-3" },
    ]);
  });

  it("propagates an effect throw to the process() call site", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(
        indexer.process({
          chains: { 1: { startBlock: 1, endBlock: 100, simulate: [item("throwingEffect", 2)] } },
        })
      )
      .rejects.toThrow("Error from effect");
  });

  it("propagates a handler throw to the process() call site with its message", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(
        indexer.process({
          chains: { 1: { startBlock: 1, endBlock: 100, simulate: [item("throwInHandler", 2)] } },
        })
      )
      .rejects.toThrow("Error from handler");
  });
});
`,
)
