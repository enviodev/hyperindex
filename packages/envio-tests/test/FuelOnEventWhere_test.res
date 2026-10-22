// A Fuel block is keyed by height, so `where.block` is too: `height._gte` is an
// event's start block, and `number` is a key it doesn't take.
//
// Both cases fail today, so they are marked `it.fails`: a Fuel registration
// drops its `where` without reading it, so the start block never applies and
// the bad key is never rejected. Once that is fixed they pass, and vitest
// reports the `it.fails` as the failure.
let _ = InternalTestIndexer.fromUserApi(
  ~files=dict{"abis/greeter-abi.json": FuelAbiFixtures.greeter},
  ~configYaml=`
name: fuel-on-event-where
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: Greeter
        address: 0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b
        abi_file_path: abis/greeter-abi.json
        events:
          - name: NewGreeting
          - name: ClearGreeting
`,
  ~schema=`
type Greeted {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Greeter", event: "NewGreeting", where: { block: { height: { _gte: 42 } } } },
  async ({ event, context }) => {
    context.Greeted.set({ id: String(event.block.height) });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, indexer, TestHelpers } from "envio";

const greeting = (height: number) => ({
  contract: "Greeter" as const,
  event: "NewGreeting" as const,
  params: { greeting: { value: "hi" }, user: { bits: TestHelpers.Addresses.defaultAddress } },
  block: { height },
});

describe("Fuel onEvent where block", () => {
  // Registration closes once a test indexer starts, so this runs first.
  it.fails("rejects block.number", (t) => {
    let message = "no error";
    try {
      indexer.onEvent(
        {
          contract: "Greeter",
          event: "ClearGreeting",
          where: { block: { number: { _gte: 42 } } } as any,
        },
        async () => {},
      );
    } catch (error) {
      message = (error as Error).message;
    }
    t.expect(message).toBe(
      'Invalid where configuration for Greeter. \\\`block\\\` filter is invalid: RescriptSchemaError: Failed parsing at ["block"]. Reason: Encountered disallowed excess key "number" on an object. Only \\\`_gte\\\` is supported on event filters — use \\\`indexer.onBlock\\\` for \\\`_lte\\\` or \\\`_every\\\`.',
    );
  });

  // A simulated item the start block excludes never reaches a handler, which
  // the test indexer reports rather than dropping silently.
  it.fails("starts the event at block.height._gte", async (t) => {
    const testIndexer = createTestIndexer();
    await t
      .expect(
        testIndexer.process({
          chains: { 0: { startBlock: 0, endBlock: 50, simulate: [greeting(42), greeting(41)] } },
        }),
      )
      .rejects.toThrow("1 item you passed to simulate never reached a handler");
  });
});
`,
)
