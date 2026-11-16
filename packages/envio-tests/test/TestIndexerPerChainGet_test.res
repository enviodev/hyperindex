let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-per-chain-get
disable_default_cross_chain: true
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
  - id: 10
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Account {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Test indexer get on a per-chain id present on several chains", () => {
  // https://github.com/enviodev/hyperindex/issues/1830
  it("rejects the returned promise instead of throwing synchronously", async (t) => {
    const indexer = createTestIndexer();
    indexer.Account.set({ id: "shared", chainId: 1 });
    indexer.Account.set({ id: "shared", chainId: 10 });

    const results = await Promise.allSettled([
      indexer.Account.get("shared"),
      indexer.Account.getOrThrow("shared"),
    ]);

    const message =
      "Entity \`Account\` with id \`shared\` exists on multiple chains (1, 10) — use getWhere({chainId: {_eq: ...}}) to pick one.";
    t.expect(
      results.map((result) => result.status === "rejected" ? result.reason.message : result),
    ).toEqual([message, message]);
  });
});
`,
)
