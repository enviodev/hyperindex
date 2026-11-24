// Live test against a public Ethereum RPC: the HyperSync live test's handler,
// read through the RPC source over a few blocks near the head. A public node
// keeps receipts only for recent blocks, so the expected rows are read from
// the same node while the test runs. What the RPC source requests is pinned
// against a mock node in OnTransactionWire_test.

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-rpc-live
chains:
  - id: 1
    rpc:
      url: https://ethereum-rpc.publicnode.com
      for: sync
    start_block: 0
`,
  ~schema=OnTransactionLive.schema,
  ~handlers=OnTransactionLive.handlers,
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

const usdt = "0xdac17f958d2ee523a2206206994597c13d831ec7";

describe("onTransaction over a live RPC", () => {
  it("runs on every succeeded USDT transfer call, with its receipt fields", { timeout: 120_000 }, async (t) => {
    const head = parseInt(await rpc("eth_blockNumber", []), 16);
    const startBlock = head - 22;
    const endBlock = head - 20;
    const expected = [];
    for (let number = startBlock; number <= endBlock; number++) {
      const block = await rpc("eth_getBlockByNumber", ["0x" + number.toString(16), true]);
      for (const transaction of block.transactions) {
        if (transaction.to?.toLowerCase() !== usdt || !transaction.input.startsWith("0xa9059cbb")) continue;
        const receipt = await rpc("eth_getTransactionReceipt", [transaction.hash]);
        if (parseInt(receipt.status, 16) !== 1) continue;
        expected.push({
          id: transaction.hash,
          transactionIndex: parseInt(transaction.transactionIndex, 16),
          from: transaction.from.toLowerCase(),
          status: 1,
          gasUsed: BigInt(receipt.gasUsed),
          timestamp: parseInt(block.timestamp, 16),
        });
      }
    }
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock, endBlock } } });
    const order = (a: { timestamp: number; transactionIndex: number }, b: typeof a) =>
      a.timestamp - b.timestamp || a.transactionIndex - b.transactionIndex;
    t.expect((await indexer.UsdtTransfer.getAll()).sort(order)).toEqual(expected.sort(order));
  });
});
`,
)
