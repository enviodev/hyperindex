open Vitest

let parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: internal-entities
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Account {
  id: ID!
  balance: BigInt!
}

type Secret @internal {
  id: ID!
  note: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Account.set({ id: event.params.to, balance: event.params.value });
  context.Secret.set({ id: event.params.to, note: "hidden" });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Account, type Secret, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("@internal entity in handlers", () => {
  it("sets and reads an @internal entity like any other", async (t) => {
    const indexer = createTestIndexer();
    const to = Addresses.defaultAddress;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Token",
              event: "Transfer",
              params: { from: Addresses.mockAddresses[1], to, value: 5n },
            },
          ],
        },
      },
    });

    const expectedAccount: Account = { id: to, balance: 5n };
    const expectedSecret: Secret = { id: to, note: "hidden" };
    t.expect({
      account: await indexer.Account.getOrThrow(to),
      secret: await indexer.Secret.getOrThrow(to),
    }).toEqual({ account: expectedAccount, secret: expectedSecret });
  });
});
`,
)

let config = parsed.config

describe("@internal entity config", () => {
  it("keeps internal entities in userEntities with the internal flag set", t => {
    t.expect(config.userEntities->Array.map(e => (e.name, e.internal))).toEqual([
      ("Account", false),
      ("Secret", true),
    ])
  })

  it("excludes internal entities from the Hasura table configs", t => {
    let tableNames =
      Hasura.makeTableConfigs(~userEntities=config->Config.getPgUserEntities)->Array.map(
        tableConfig => tableConfig.Hasura.tableName,
      )
    t.expect(tableNames).toEqual(["raw_events", "_meta", "chain_metadata", "Account"])
  })
})
