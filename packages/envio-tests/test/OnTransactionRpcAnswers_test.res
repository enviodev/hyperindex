open Vitest

// An RPC answer a transaction page can't trust is retried rather than read: a
// recipient that isn't a 20-byte address would otherwise match no filter and
// drop its transaction, and a receipt
// from another block than the one its transaction was read from would decide
// a `status` filter on another fork's outcome. Each kind is answered badly
// once, then well.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let carol = "0x3333333333333333333333333333333333333333"
let rpcPort = 18771
let height = 3

let transactions: array<ServedEvmChain.transaction> = [
  // Only the \`to\` filter matches it, so nothing else reads it in full.
  {blockNumber: 2, transactionIndex: 0, from: carol, to: bob},
  {blockNumber: 3, transactionIndex: 0, from: alice, to: bob, status: 1},
]

let corruptedRecipient = ref(false)
let movedReceipt = ref(false)

let getResult = (~method, ~params) => {
  let result = ServedEvmChain.rpcResult(~logs=[], ~transactions, ~height, ~method, ~params)
  switch (method, result) {
  // After the moved receipt fails the first read, so no other retry re-reads
  // the block for it.
  | ("eth_getBlockByNumber", JSON.Object(block))
    if movedReceipt.contents && !corruptedRecipient.contents =>
    switch block->Dict.get("transactions") {
    | Some(JSON.Array([JSON.Object(transaction)]))
      if block->Dict.get("number") == Some(JSON.String("0x2")) =>
      corruptedRecipient := true
      transaction->Dict.set("to", JSON.String(bob ++ "00"))
    | _ => ()
    }
    result
  | ("eth_getTransactionReceipt", JSON.Object(receipt)) if !movedReceipt.contents =>
    movedReceipt := true
    receipt->Dict.set("blockHash", JSON.String(99->ServedEvmChain.blockHash))
    receipt->Dict.set("status", JSON.String("0x0"))
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
name: on-transaction-rpc-answers
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
  to: String!
  runs: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

const record = (name: string) => async ({ transaction, context }: any) => {
  if (context.isPreload) return;
  const id = \`\${name} \${transaction.block.number}\`;
  const runs = ((await context.Sent.get(id))?.runs ?? 0) + 1;
  context.Sent.set({ id, to: (transaction.to ?? "none").toLowerCase(), runs });
};

indexer.onTransaction(
  { name: "to-bob", where: () => ({ transaction: { to: ["${bob}"] } }), fields: { transaction: ["to"] } },
  record("to-bob"),
);
indexer.onTransaction(
  {
    name: "succeeded",
    where: () => ({ transaction: { from: ["${alice}"], status: [1] } }),
    fields: { transaction: ["to"] },
  },
  record("succeeded"),
);
`,
)

type sent = {id: string, to: string, runs: int}

describe("onTransaction over RPC answers it can't trust", () => {
  Async.it("retries them and runs each handler once on the good answer", async t => {
    let exited = ref(false)
    await scenario->Scenario.run(
      ~yamlSources=true,
      ~onExit=() => exited := true,
      async (~indexer, ~source as _) => {
        // Real time: the RPC server answers off the indexer's clock, and the
        // retries wait on it.
        for _ in 0 to 600 {
          if !exited.contents {
            await indexer.advanceTime(1000)
            await Utils.delay(5)
          }
        }
        let sent: array<sent> = await indexer.query("Sent")
        t.expect((
          exited.contents,
          corruptedRecipient.contents,
          movedReceipt.contents,
          sent->Array.toSorted((a, b) => String.compare(a.id, b.id)),
        )).toEqual((
          true,
          true,
          true,
          [
            {id: "succeeded 3", to: bob, runs: 1},
            {id: "to-bob 2", to: bob, runs: 1},
            {id: "to-bob 3", to: bob, runs: 1},
          ],
        ))
      },
    )
  })
})
