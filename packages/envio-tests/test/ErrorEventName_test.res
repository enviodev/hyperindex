// https://github.com/enviodev/hyperindex/issues/655
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: error-event
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: error(address indexed to, uint256 error)
`,
  ~schema=`
type Account {
  id: ID!
  balance: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "error" }, async ({ event, context }) => {
  context.Account.set({
    id: event.params.to,
    balance: event.params.error,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Account, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("error in event signature", () => {
  it("indexes an event and a param named error", async (t) => {
    const indexer = createTestIndexer();
    const to = Addresses.defaultAddress;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Token", event: "error", params: { to, error: 5n } },
          ],
        },
      },
    });

    const expected: Account = { id: to, balance: 5n };
    t.expect(await indexer.Account.getOrThrow(to)).toEqual(expected);
  });
});
`,
)
