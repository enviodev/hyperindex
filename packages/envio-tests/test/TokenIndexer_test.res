// `handlers` and `test` are ordinary user modules — the same source a project
// would put in `src/handlers/` and `src/indexer.test.ts` — type-checked against
// this config's generated types and then actually executed.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: token-indexer
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
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  const existing = await context.Account.get(event.params.to);
  context.Account.set({
    id: event.params.to,
    balance: (existing?.balance ?? 0n) + event.params.value,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Account, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Token transfers", () => {
  it("creates an Account from a Transfer", async (t) => {
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

    const expected: Account = { id: to, balance: 5n };
    t.expect(await indexer.Account.getOrThrow(to)).toEqual(expected);
  });

  it("accumulates balance across two Transfers", async (t) => {
    const indexer = createTestIndexer();
    const to = Addresses.defaultAddress;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Token",
              event: "Transfer",
              params: { from: Addresses.mockAddresses[1], to, value: 3n },
            },
            {
              contract: "Token",
              event: "Transfer",
              params: { from: Addresses.mockAddresses[1], to, value: 4n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Account.getOrThrow(to)).toEqual({ id: to, balance: 7n });
  });
});
`,
)
