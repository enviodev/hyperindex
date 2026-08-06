// A materialized table is derived from its `select`, so a handler write would be
// silently reverted the next time the source event is reprocessed. Handlers can
// read one; only the materializer writes it. An entity from schema.graphql
// alongside it stays fully writable.
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
  // Reading a materialized table from a handler is fine.
  const account = await context.Accounts.get(event.params.to);
  context.Note.set({
    id: event.params.to,
    note: account ? \`received \${account.received}\` : "unseen",
  });

  if (event.params.value === 13n) {
    context.Accounts.set({ id: event.params.to, received: 0n });
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

describe("materialized tables are read-only from handlers", () => {
  it("lets a handler read one, and runs the materializer first", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [transfer(5n)] } } });

    t.expect({
      accounts: await indexer.Accounts.getAll(),
      notes: await indexer.Note.getAll(),
    }).toEqual({
      accounts: [{ id: alice, received: 5n, chainId: 1 }],
      notes: [{ id: alice, note: "received 5", chainId: 1 }],
    });
  });

  it("rejects a handler write with a message naming the table", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({ chains: { 1: { simulate: [transfer(13n)] } } })
    );

    t.expect(message).toBe(
      "context.Accounts.set() is unavailable: \`accounts\` is materialized by its \`select\` in config.yaml, so the indexer owns its rows. Read it here, or move the table to schema.graphql to write it from handlers."
    );
  });
});
`,
)
