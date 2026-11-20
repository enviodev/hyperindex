// Live test at the mainnet head: transaction handlers over HyperSync across
// blocks still inside the reorg window, cross-checked against the same blocks
// read in full from a public RPC node while the test runs.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live onTransaction head test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-head-live
chains:
  - id: 1
    start_block: 0
`,
  ~schema=`
type UsdtTransfer {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "usdt-transfers",
    where: () => ({ transaction: { to: ["0xdac17f958d2ee523a2206206994597c13d831ec7"], status: [0, 1] } }),
    fields: { transaction: ["input"] },
  },
  async ({ transaction, context }) => {
    if (transaction.input.startsWith("0xa9059cbb")) context.UsdtTransfer.set({ id: transaction.hash });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

// The public node is load-balanced: a backend behind the one that answered
// \`eth_blockNumber\` can still miss a block, or a request can be rate limited,
// so a call without a result is asked again.
const rpc = async (method: string, params: unknown[]) => {
  for (let attempt = 1; ; attempt++) {
    const response = await fetch("https://ethereum-rpc.publicnode.com", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    }).catch(() => undefined);
    const result = response?.ok ? ((await response.json()) as { result?: any }).result : undefined;
    if (result != null) return result;
    if (attempt === 10) throw new Error(\`\${method} returned no result after \${attempt} attempts\`);
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
};

describe("onTransaction at the mainnet head", () => {
  it("runs on exactly the transactions the RPC node holds", { timeout: 120_000 }, async (t) => {
    const head = parseInt(await rpc("eth_blockNumber", []), 16);
    // Recent enough to sit inside the reorg window, old enough for both
    // sources to have every block.
    const startBlock = head - 30;
    const endBlock = head - 10;
    const expected: string[] = [];
    for (let number = startBlock; number <= endBlock; number++) {
      const block = await rpc("eth_getBlockByNumber", ["0x" + number.toString(16), true]);
      for (const transaction of block.transactions) {
        if (
          transaction.to?.toLowerCase() === "0xdac17f958d2ee523a2206206994597c13d831ec7" &&
          transaction.input.startsWith("0xa9059cbb")
        ) {
          expected.push(transaction.hash);
        }
      }
    }
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock, endBlock } } });
    t.expect((await indexer.UsdtTransfer.getAll()).map((row) => row.id).sort()).toEqual(expected.sort());
  });
});
`,
)
