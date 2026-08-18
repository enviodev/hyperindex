// https://github.com/enviodev/hyperindex/issues/1187
//
// One address indexed by two contract definitions. Each contract keeps its own
// events, its own start block and its own handlers; the address is registered
// once per contract rather than claimed by whichever got there first.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: shared-address
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
      - name: Vault
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Deposit(address indexed owner, uint256 amount)
      - name: Factory
        address: "0x2222222222222222222222222222222222222222"
        events:
          - event: VaultCreated(address vault)
`,
  ~schema=`
type Seen {
  id: ID!
  contract: String!
  amount: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({
    id: \`Token-\${event.srcAddress}\`,
    contract: "Token",
    amount: event.params.value,
  });
});

indexer.onEvent({ contract: "Vault", event: "Deposit" }, async ({ event, context }) => {
  context.Seen.set({
    id: \`Vault-\${event.srcAddress}\`,
    contract: "Vault",
    amount: event.params.amount,
  });
});

indexer.contractRegister(
  { contract: "Factory", event: "VaultCreated" },
  async ({ event, context }) => {
    context.chain.Vault.add(event.params.vault);
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const shared = "0x1111111111111111111111111111111111111111";

describe("An address shared by two contracts", () => {
  it("runs both contracts' handlers for the one address", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Token",
              event: "Transfer",
              params: { from: Addresses.mockAddresses[1], to: Addresses.mockAddresses[2], value: 5n },
            },
            {
              contract: "Vault",
              event: "Deposit",
              params: { owner: Addresses.mockAddresses[1], amount: 7n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Seen.getAll()).toEqual([
      { id: \`Token-\${shared}\`, contract: "Token", amount: 5n },
      { id: \`Vault-\${shared}\`, contract: "Vault", amount: 7n },
    ]);
  });

  it("indexes an address the config already gave another contract, once registered", async (t) => {
    const indexer = createTestIndexer();
    const dynamic = Addresses.mockAddresses[3];

    await indexer.process({
      chains: {
        1: {
          simulate: [
            // Registers an address for Vault that isn't in the config at all,
            // alongside the shared one Token already holds.
            {
              contract: "Factory",
              event: "VaultCreated",
              block: { number: 1 },
              params: { vault: dynamic },
            },
            {
              contract: "Vault",
              event: "Deposit",
              block: { number: 2 },
              srcAddress: dynamic,
              params: { owner: Addresses.mockAddresses[1], amount: 11n },
            },
            // The config-shared address keeps working alongside it.
            {
              contract: "Token",
              event: "Transfer",
              block: { number: 3 },
              params: { from: Addresses.mockAddresses[1], to: Addresses.mockAddresses[2], value: 3n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Seen.getAll()).toEqual([
      { id: \`Vault-\${dynamic}\`, contract: "Vault", amount: 11n },
      { id: \`Token-\${shared}\`, contract: "Token", amount: 3n },
    ]);
  });
});
`,
)
