open Vitest

// A node serves pre-Byzantium receipts with `root` and no `status`, so over
// RPC a `status` filter can't tell whether such a transaction succeeded.
// Running nothing on it would silently skip every transaction of those blocks,
// so the run stops and says how to index them instead.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let rpcPort = 18772
let height = 2

let transactions: array<ServedEvmChain.transaction> = [
  {blockNumber: 2, transactionIndex: 0, from: alice, to: bob},
]

let getResult = (~method, ~params) => {
  let result = ServedEvmChain.rpcResult(~logs=[], ~transactions, ~height, ~method, ~params)
  switch (method, result) {
  | ("eth_getTransactionReceipt", JSON.Object(receipt)) =>
    receipt->Dict.delete("status")
    receipt->Dict.set("root", JSON.String(`0x${"ab"->String.repeat(32)}`))
    result
  | _ => result
  }
}

let server = ref(None)
Async.beforeAll(async () =>
  server := Some(await MockRpcServer.makeWithParams(~port=rpcPort, ~getResult))
)
Async.afterAll(async () =>
  switch server.contents {
  | Some(server) => await server.closeAsync()
  | None => ()
  }
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-rpc-no-status
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 1
    end_block: ${height->Int.toString}
    rpc:
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync
    contracts:
      - name: Token
        address: "${bob}"
`,
  ~schema=`
type Sent {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  { name: "from-alice", where: () => ({ transaction: { from: ["${alice}"] } }) },
  async ({ transaction, context }) => {
    context.Sent.set({ id: transaction.hash });
  },
);
`,
)

describe("onTransaction over RPC on a receipt without status", () => {
  Async.it("stops the run with how to index the block", async t => {
    let errors = []
    let exited = ref(false)
    await scenario->Scenario.run(
      ~yamlSources=true,
      ~onError=errHandler =>
        errors
        ->Array.push(errHandler.exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))
        ->ignore,
      ~onExit=() => exited := true,
      async (~indexer, ~source as _) => {
        // Real time: the RPC server answers off the indexer's clock.
        for _ in 0 to 100 {
          if errors->Array.length === 0 && !exited.contents {
            await indexer.advanceTime(1000)
            await Utils.delay(5)
          }
        }
        let sent: array<{"id": string}> = await indexer.query("Sent")
        t.expect((errors->Array.map(error => error["message"]), sent)).toEqual((
          [
            "The indexer doesn't have data-sources which can continue fetching. The last one was disabled because the RPC receipt of transaction 0x000000000000000000000000000000000000000000000000000000000000a200 in block 2 has no status (blocks before Byzantium have none), so an onTransaction `status` filter can't be decided over RPC. Index these blocks with HyperSync, or list `status: [0, 1]` to run on every transaction.",
          ],
          [],
        ))
      },
    )
  })
})
