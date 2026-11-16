// Live test against eth.hypersync.xyz, driven through the user API. The
// expected counts were tallied from the JSON endpoint's transaction rows, and
// the first ten match the length of a public RPC's eth_getBlockByNumber
// transactions list. The server ends a counting page near 1,100 blocks, so the
// 2,000 blocks take two pages: a block split or repeated across them would
// change the totals or the counts at 23,501,161 and 23,501,162.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live EVM onBlock transaction count test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: evm-onblock-transaction-count-live
chains:
  - id: 1
    start_block: 23500000
    end_block: 23501999
`,
  ~schema=`
type BlockCount {
  id: ID!
  transactions: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock(
  { name: "counts", fields: { block: ["transactionCount"] } },
  async ({ block, context }) => {
    context.BlockCount.set({ id: \`\${block.number}\`, transactions: block.transactionCount });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onBlock transaction count over live HyperSync", () => {
  it("counts every block's transactions once across pages", { timeout: 120_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 23500000, endBlock: 23501999 } } });

    const counts = Object.fromEntries(
      (await indexer.BlockCount.getAll()).map((row) => [row.id, row.transactions]),
    );
    const ids = Object.keys(counts);
    t.expect({
      blocks: ids.length,
      transactions: Object.values(counts).reduce((sum, count) => sum + count, 0),
      firstTen: ids.filter((id) => Number(id) < 23500010).sort().map((id) => counts[id]),
      firstPageEnd: counts["23501161"],
      secondPageStart: counts["23501162"],
      empty: ids.filter((id) => counts[id] === 0).sort(),
    }).toEqual({
      blocks: 2000,
      transactions: 389199,
      firstTen: [233, 196, 184, 212, 141, 151, 306, 131, 215, 161],
      firstPageEnd: 198,
      secondPageStart: 158,
      empty: ["23501190", "23501952"],
    });
  });
});
`,
)
