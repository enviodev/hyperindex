open Vitest

// A chain served by HyperSync with an RPC to fall back on. One transaction
// page HyperSync can't answer whole goes to the RPC, and the pages around it
// come back to HyperSync: every transaction still runs its handler once.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let height = 6

let transactions = Array.fromInitializer(~length=height, index => {
  let transaction: ServedEvmChain.transaction = {
    blockNumber: index + 1,
    transactionIndex: 0,
    from: alice,
    to: bob,
  }
  transaction
})

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18769,
  ~rpcPort=18770,
  ~height,
  ~logs=[],
  ~transactions,
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-fallback
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 1
    end_block: ${height->Int.toString}
    hypersync_config:
      url: ${ServedEvmChain.url(18769)}
    rpc:
      url: ${ServedEvmChain.url(18770)}
      for: fallback
    contracts:
      - name: Token
        address: "${bob}"
`,
  ~schema=`
type Sent {
  id: ID!
  runs: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  { name: "sends", where: () => ({ transaction: { from: ["${alice}"] } }) },
  async ({ block, context }) => {
    if (context.isPreload) return;
    const id = \`\${block.number}\`;
    const runs = ((await context.Sent.get(id))?.runs ?? 0) + 1;
    context.Sent.set({ id, runs });
  },
);
// Matches nothing served, and names no call field: the chain syncs over
// HyperSync, so its warning says nothing of what RPC would cost.
indexer.onTransaction({ name: "reverted", where: () => ({ transaction: { status: 0 } }) }, async () => {});
`,
)

let page = (~fromBlock, ~toBlock, ~transaction): MockHyperSyncServer.page => {
  let blocks = Array.fromInitializer(~length=toBlock - fromBlock + 1, index => {
    let number = fromBlock + index
    JSON.Object(
      dict{
        "number": JSON.Number(number->Int.toFloat),
        "timestamp": JSON.Number(number->Int.toFloat),
        "hash": JSON.String(number->ServedEvmChain.blockHash),
      },
    )
  })
  {
    blocks,
    transactions: Array.fromInitializer(~length=toBlock - fromBlock + 1, index =>
      transaction(transactions->Array.getUnsafe(fromBlock + index - 1))
    ),
    nextBlock: toBlock + 1,
  }
}

type sent = {id: string, runs: int}

describe("onTransaction falling back from HyperSync to RPC", () => {
  Async.it("runs every transaction once across the sources", async t => {
    let hyperSync = (served->ServedEvmChain.servers).hyperSync
    // A whole first page, then one without the transactions' hashes, which
    // HyperSync can't serve: that query moves to the RPC.
    hyperSync->MockHyperSyncServer.pushResponse(
      page(
        ~fromBlock=1,
        ~toBlock=2,
        ~transaction=transaction => {
          let row =
            transaction->ServedEvmChain.hyperSyncTransaction->JSON.Decode.object->Option.getOrThrow
          row->Dict.delete("input")
          row->Dict.delete("value")
          row->Dict.delete("status")
          row->Dict.delete("gas_used")
          JSON.Object(row)
        },
      ),
    )
    hyperSync->MockHyperSyncServer.pushResponse(
      page(
        ~fromBlock=3,
        ~toBlock=3,
        ~transaction=transaction => JSON.Object(
          dict{
            "block_number": JSON.Number(transaction.blockNumber->Int.toFloat),
            "transaction_index": JSON.Number(0.),
            "from": JSON.String(transaction.from),
          },
        ),
      ),
    )
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let sent: array<sent> = await indexer.query("Sent")
        let rpcFullBlockReads =
          (served->ServedEvmChain.servers).rpc.requests->Array.filter(
            body => body->String.includes("eth_getBlockByNumber") && body->String.includes("true"),
          )
        t.expect((
          sent->Array.toSorted((a, b) => String.compare(a.id, b.id)),
          rpcFullBlockReads->Utils.Array.notEmpty,
          indexer.infoAndAboveLogs()
          ->Array.filter(({msg}) => msg->String.includes("runs on every transaction"))
          ->Array.map(({msg}) => msg),
        )).toEqual((
          Array.fromInitializer(
            ~length=height,
            index => {
              id: (index + 1)->Int.toString,
              runs: 1,
            },
          ),
          true,
          [
            "`indexer.onTransaction(\"reverted\")` runs on every transaction of chain 1: its filter names no `from` or `to`.",
          ],
        ))
      },
    )
  })
})
