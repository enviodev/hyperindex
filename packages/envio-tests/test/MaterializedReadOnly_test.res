// A table isn't an entity: nothing opts one into the handler context, so a
// handler can't reach it at all, and the error says which table it is rather
// than sending the user to codegen. An entity from schema.graphql alongside it
// stays fully writable.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-read-only
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  accounts:
    from: evm.events
    where:
      contractName: ERC20
      eventName: Transfer
    select:
      id: params.to
      received:
        _sum: params.value
`,
  ~schema=`
type Note {
  id: ID!
  note: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "ERC20", event: "Transfer" }, async ({ event, context }) => {
  context.Note.set({ id: event.params.to, note: "seen" });

  if (event.params.value === 13n) {
    // Not part of the handler context: config.yaml writes this table.
    (context as any).Accounts.get(event.params.to);
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

const transfer = (value: bigint) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  params: { from: Addresses.defaultAddress, to: alice, value },
});

const messageOf = async (run: () => Promise<unknown>): Promise<string | undefined> => {
  try {
    await run();
    return undefined;
  } catch (error) {
    return (error as Error).message;
  }
};

describe("a table config.yaml writes", () => {
  it("leaves a handler on the same event running normally", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [transfer(5n)] } } });

    t.expect(await indexer.Note.getAll()).toEqual([
      { id: alice, note: "seen", chainId: 1 },
    ]);
  });

  it("is absent from the handler context, with a message naming the table", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({ chains: { 1: { simulate: [transfer(13n)] } } })
    );

    t.expect(message).toBe(
      "context.Accounts is unavailable: config.yaml writes the table \`accounts\` from its \`select\`, so it isn't part of the handler context. Define the table in schema.graphql to read and write it from a handler."
    );
  });
});
`,
)
