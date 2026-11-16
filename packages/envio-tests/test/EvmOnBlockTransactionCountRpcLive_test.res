// Live test against a public Ethereum RPC, driven through the user API and a
// recording proxy: the counts of the HyperSync live test, read through the RPC
// source instead. A block's count is the length of the transactions list its
// eth_getBlockByNumber response already carries, so it costs no other call.

let proxyPort = 18563
let proxy = RecordingProxy.serveDuringSuite(
  ~port=proxyPort,
  ~upstream="https://ethereum-rpc.publicnode.com",
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: evm-onblock-transaction-count-rpc-live
chains:
  - id: 1
    rpc:
      url: http://127.0.0.1:${proxyPort->Int.toString}
      for: sync
    start_block: 23500000
    end_block: 23500009
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

describe("onBlock transaction count over a live RPC", () => {
  it("counts each block's transactions", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 23500000, endBlock: 23500009 } } });

    t.expect(
      (await indexer.BlockCount.getAll())
        .sort((a, b) => a.id.localeCompare(b.id))
        .map((row) => row.transactions),
    ).toEqual([233, 196, 184, 212, 141, 151, 306, 131, 215, 161]);
  });
});
`,
)

// Calls go out concurrently, so they are compared as a sorted list.
Vitest.it("reads each block once, with no call beyond eth_getBlockByNumber", t => {
  let asked = proxy().queries->Array.map(query => {
    let call = query->(Utils.magic: JSON.t => {"method": string, "params": array<JSON.t>})
    let block = switch call["params"]->Array.get(0) {
    | Some(JSON.String(hex)) =>
      hex
      ->String.slice(~start=2, ~end=hex->String.length)
      ->Int.fromString(~radix=16)
      ->Option.mapOr(hex, number => number->Int.toString)
    | _ => ""
    }
    `${call["method"]} ${block}`
  })
  t.expect(asked->Array.toSorted(String.compare)).toEqual([
    "eth_getBlockByNumber 23500000",
    "eth_getBlockByNumber 23500001",
    "eth_getBlockByNumber 23500002",
    "eth_getBlockByNumber 23500003",
    "eth_getBlockByNumber 23500004",
    "eth_getBlockByNumber 23500005",
    "eth_getBlockByNumber 23500006",
    "eth_getBlockByNumber 23500007",
    "eth_getBlockByNumber 23500008",
    "eth_getBlockByNumber 23500009",
  ])
})
