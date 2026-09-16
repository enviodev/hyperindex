// Registration closes once the indexer finishes initializing, so an onEvent or
// onBlock call made from inside a handler has to fail rather than silently
// register something the run will never fetch for.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: register-after-init
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "FactoryEvent(address indexed contract, string testCase)"
`,
  ~schema=`
type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (context.isPreload) {
    return;
  }
  switch (event.params.testCase) {
    case "handlerInHandler":
      indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async () => {});
      return;
    case "onBlockInHandler":
      indexer.onBlock({ name: "onblock_late", where: ({ chain }) => chain.id === 1 }, async () => {});
      return;
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Address } from "envio";

const dcAddress: Address = "0x1234567890123456789012345678901234567890";

const run = (indexer: ReturnType<typeof createTestIndexer>, testCase: string) =>
  indexer.process({
    chains: {
      1: {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          {
            contract: "Gravatar",
            event: "FactoryEvent",
            params: { contract: dcAddress, testCase },
          },
        ],
      },
    },
  });

describe("Registering after initialization", () => {
  it("rejects an onEvent registered from inside a handler", async (t) => {
    const indexer = createTestIndexer();

    await t.expect(run(indexer, "handlerInHandler")).rejects.toThrow();
  });

  it("rejects an onBlock registered from inside a handler", async (t) => {
    const indexer = createTestIndexer();

    await t.expect(run(indexer, "onBlockInHandler")).rejects.toThrow();
  });
});
`,
)
