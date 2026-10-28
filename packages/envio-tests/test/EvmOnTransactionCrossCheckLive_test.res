// Live cross-check: the transactions `indexer.onTransaction` runs on over
// HyperSync must be exactly the ones a public RPC node holds, for a sender
// filter (reverted included) and a recipient-plus-selector filter.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live onTransaction cross-check",
  )

let wallet = "0x28C6c06298d514Db089934071355E5743bf21d60"
let usdt = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
let fromBlock = 23500000
let toBlock = 23500003

let handlers = `
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "hot-wallet",
    where: () => ({ transaction: { from: ["${wallet}"] } }),
    fields: { transaction: ["value", "status", "nonce"], block: ["timestamp"] },
  },
  async ({ transaction, block, context }) => {
    context.Sent.set({
      id: transaction.hash,
      from: (transaction.from ?? "none").toLowerCase(),
      to: (transaction.to ?? "none").toLowerCase(),
      value: transaction.value,
      status: transaction.status ?? -1,
      nonce: transaction.nonce,
      number: block.number,
      timestamp: block.timestamp,
      transactionIndex: transaction.transactionIndex,
    });
  },
);

indexer.onTransaction(
  {
    name: "usdt-transfers",
    where: () => ({ transaction: { to: ["${usdt}"], sighash: ["0xa9059cbb"] } }),
    fields: { transaction: ["input"] },
  },
  async ({ transaction, block, context }) => {
    context.UsdtTransferCall.set({
      id: transaction.hash,
      from: (transaction.from ?? "none").toLowerCase(),
      number: block.number,
      transactionIndex: transaction.transactionIndex,
      selector: transaction.input.slice(0, 10),
    });
  },
);
`

let schema = `
type Sent {
  id: ID!
  from: String!
  to: String!
  value: BigInt!
  status: Int!
  nonce: BigInt!
  number: Int!
  timestamp: Int!
  transactionIndex: Int!
}

type UsdtTransferCall {
  id: ID!
  from: String!
  number: Int!
  transactionIndex: Int!
  selector: String!
}
`

let test = `
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const wallet = "${wallet}".toLowerCase();
const usdt = "${usdt}".toLowerCase();
const fromBlock = ${fromBlock->Int.toString};
const toBlock = ${toBlock->Int.toString};

// The public node is load-balanced and rate-limited: a null or an error for
// something the chain has is asked again, the way the indexer's source does.
const rpc = async (method: string, params: unknown[]) => {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch("https://ethereum-rpc.publicnode.com", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
      const body = (await response.json()) as { error?: unknown; result: any };
      if (body.error) throw new Error(JSON.stringify(body.error));
      if (body.result !== null) return body.result;
      throw new Error(\`null result for \${method}\`);
    } catch (error) {
      if (attempt >= 8) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
    }
  }
};
const hex = (n: number) => "0x" + n.toString(16);
const byId = (a: { id: string }, b: { id: string }) => a.id.localeCompare(b.id);

// What the node says: every transaction of the range, read in full.
const groundTruth = async () => {
  const sent: any[] = [];
  const usdtCalls: any[] = [];
  for (let n = fromBlock; n <= toBlock; n++) {
    const block = await rpc("eth_getBlockByNumber", [hex(n), true]);
    for (const tx of block.transactions) {
      const from = tx.from.toLowerCase();
      const to = tx.to ? tx.to.toLowerCase() : "none";
      if (from === wallet) {
        const receipt = await rpc("eth_getTransactionReceipt", [tx.hash]);
        sent.push({
          id: tx.hash,
          from,
          to,
          value: BigInt(tx.value),
          status: Number(receipt.status),
          nonce: BigInt(tx.nonce),
          number: n,
          timestamp: Number(block.timestamp),
          transactionIndex: Number(tx.transactionIndex),
        });
      }
      if (to === usdt && tx.input.startsWith("0xa9059cbb")) {
        usdtCalls.push({
          id: tx.hash,
          from,
          number: n,
          transactionIndex: Number(tx.transactionIndex),
          selector: tx.input.slice(0, 10),
        });
      }
    }
  }
  return { sent: sent.sort(byId), usdtCalls: usdtCalls.sort(byId) };
};

describe("onTransaction against a public RPC node", () => {
  it("runs on exactly the transactions the node holds for each filter", { timeout: 180_000 }, async (t) => {
    const expected = await groundTruth();
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: fromBlock, endBlock: toBlock } } });
    const actual = {
      sent: (await indexer.Sent.getAll()).sort(byId),
      usdtCalls: (await indexer.UsdtTransferCall.getAll()).sort(byId),
    };
    t.expect({
      sentCount: actual.sent.length,
      usdtCount: actual.usdtCalls.length,
      sentHasReverted: expected.sent.some((tx) => tx.status === 0),
      ...actual,
    }).toEqual({
      sentCount: expected.sent.length,
      usdtCount: expected.usdtCalls.length,
      sentHasReverted: expected.sent.some((tx) => tx.status === 0),
      ...expected,
    });
    t.expect(expected.sent.length > 0 && expected.usdtCalls.length > 0).toBe(true);
  });
});
`

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: evm-ontransaction-cross-check-live
chains:
  - id: 1
    start_block: ${fromBlock->Int.toString}
    end_block: ${toBlock->Int.toString}
`,
  ~schema,
  ~handlers,
  ~test,
)
