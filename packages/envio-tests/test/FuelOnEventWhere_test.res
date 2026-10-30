// A Fuel block is keyed by height, so `where.block` is too: `height._gte` is an
// event's start block, and `number` is a key it doesn't take. Fuel events have
// no indexed params, so `where.params` is rejected.
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

indexer.contractRegister(
  { contract: "Greeter", event: "NewGreeting" },
  async ({ event, context }) => {
    context.chain.Greeter.add(event.params.user.bits);
  },
);

indexer.onEvent(
  { contract: "Greeter", event: "ClearGreeting", where: ({ chain }) => chain.id !== 0 },
  async ({ context }) => {
    context.Greeted.set({ id: "cleared" });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, indexer, TestHelpers } from "envio";

const user = { bits: "0x1111111111111111111111111111111111111111111111111111111111111111" as const };

const greeting = (height: number) => ({
  contract: "Greeter" as const,
  event: "NewGreeting" as const,
  params: { greeting: { value: "hi" }, user },
  block: { height },
});

const registrationError = (register: () => void) => {
  try {
    register();
    return "no error";
  } catch (error) {
    return (error as Error).message;
  }
};

describe("Fuel onEvent where", () => {
  // Registration closes once a test indexer starts, so these run first.
  it("rejects block.number", (t) => {
    t.expect(
      registrationError(() =>
        indexer.onEvent(
          {
            contract: "Greeter",
            event: "ClearGreeting",
            where: { block: { number: { _gte: 42 } } } as any,
          },
          async () => {},
        ),
      ),
    ).toBe(
      'Invalid where configuration for Greeter. \\\`block\\\` filter is invalid: RescriptSchemaError: Failed parsing at ["block"]. Reason: Encountered disallowed excess key "number" on an object. Only \\\`_gte\\\` is supported on event filters — use \\\`indexer.onBlock\\\` for \\\`_lte\\\` or \\\`_every\\\`.',
    );
  });

  it("rejects params", (t) => {
    t.expect([
      registrationError(() =>
        indexer.onEvent(
          // @ts-expect-error - Fuel events have no indexed params to filter on
          { contract: "Greeter", event: "ClearGreeting", where: { params: {} } },
          async () => {},
        ),
      ),
      registrationError(() =>
        indexer.onEvent(
          // @ts-expect-error - Fuel events have no indexed params to filter on
          { contract: "Greeter", event: "ClearGreeting", where: () => ({ params: {} }) },
          async () => {},
        ),
      ),
    ]).toEqual([
      'Invalid where configuration for Greeter. Unknown field "params". Fuel events can only be filtered by \\\`block\\\`.',
      'Invalid where configuration for Greeter. Unknown field "params". Fuel events can only be filtered by \\\`block\\\`.',
    ]);
  });

  // The contractRegister has no \`where\`, so it still sees block 41.
  it("starts the event at block.height._gte", async (t) => {
    const testIndexer = createTestIndexer();
    t.expect(
      await testIndexer.process({
        chains: { 0: { startBlock: 0, endBlock: 50, simulate: [greeting(41), greeting(42)] } },
      }),
    ).toEqual({
      changes: [
        { block: 41, chainId: 0, eventsProcessed: 1, addresses: { sets: [{ address: user.bits, contract: "Greeter" }] } },
        { block: 42, chainId: 0, eventsProcessed: 1, Greeted: { sets: [{ id: "42" }] } },
      ],
    });
  });

  it("skips a chain whose where returns false", async (t) => {
    const testIndexer = createTestIndexer();
    await t
      .expect(
        testIndexer.process({
          chains: {
            0: {
              startBlock: 0,
              endBlock: 50,
              simulate: [{ contract: "Greeter", event: "ClearGreeting", params: { user }, block: { height: 42 } }],
            },
          },
        }),
      )
      .rejects.toThrow(
        'simulate: no handler runs for event "ClearGreeting" on contract "Greeter". Register a handler with indexer.onEvent (and check any \\\`where\\\` filter isn\\'t excluding this chain) before simulating it.',
      );
  });
});
`,
)
