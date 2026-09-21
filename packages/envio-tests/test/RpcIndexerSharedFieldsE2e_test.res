// The rule the chain-wide read lives under, from the outside: what any
// registration selects decides how much of a response is decoded, never whether
// one is fetched. Here one event selects transaction and block fields and
// another selects none, and the page carrying both must still pay for a receipt
// only where an event asked for one.
//
// A regression here is invisible in the entities — every value still comes out
// right — and shows up only as requests, so the wire traffic is the assertion.
let port = 18548
let url = `http://127.0.0.1:${port->Int.toString}`

let approvalSighash = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

open RpcE2eChain

let height = 105
let transferBlock = 100
let approvalBlock = 101

let blockJson = blockNumber =>
  JSON.parseOrThrow(
    `{"number":"${blockNumber->hex}","timestamp":"${blockNumber->hex}","hash":"${blockNumber->blockHash}","parentHash":"${(blockNumber - 1)
        ->blockHash}","gasUsed":"${(blockNumber * 2)->hex}"}`,
  )

let logJson = (~blockNumber, ~sighash, ~value) =>
  JSON.parseOrThrow(
    `{"address":"${contractAddress}","topics":["${sighash}","${sender->addressTopic}","${recipient->addressTopic}"],"data":"${value
      ->hex
      ->dropPrefix
      ->padded}","blockNumber":"${blockNumber->hex}","transactionHash":"${blockNumber->transactionHash}","transactionIndex":"0x0","blockHash":"${blockNumber->blockHash}","logIndex":"0x0","removed":false}`,
  )

let receiptJson = blockNumber =>
  JSON.parseOrThrow(
    `{"transactionHash":"${blockNumber->transactionHash}","blockNumber":"${blockNumber->hex}","transactionIndex":"0x0","gasUsed":"${(blockNumber * 3)
      ->hex}"}`,
  )

let getResult = (~method, ~params) => {
  let arg = i => params->JSON.Decode.array->Option.getOrThrow->Array.getUnsafe(i)
  switch method {
  | "eth_blockNumber" => JSON.String(height->hex)
  | "eth_getBlockByNumber" => arg(0)->hexParam->blockJson
  | "eth_getTransactionReceipt" => approvalBlock->receiptJson
  | "eth_getLogs" =>
    let filter = arg(0)->JSON.Decode.object->Option.getOrThrow
    let fromBlock = filter->Dict.getUnsafe("fromBlock")->hexParam
    let toBlock = filter->Dict.getUnsafe("toBlock")->hexParam
    JSON.Array(
      [
        logJson(~blockNumber=transferBlock, ~sighash=transferSighash, ~value=3),
        logJson(~blockNumber=approvalBlock, ~sighash=approvalSighash, ~value=4),
      ]->Array.filter(log => {
        let blockNumber =
          log->JSON.Decode.object->Option.getOrThrow->Dict.getUnsafe("blockNumber")->hexParam
        blockNumber >= fromBlock && blockNumber <= toBlock
      }),
    )
  | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
  }
}

let server = ref(None)
let mock = () =>
  server.contents->Option.getOrThrow(~message="the mock RPC server was never started")

Vitest.Async.beforeAll(async () => {
  let started = await MockRpcServer.makeWithParams(~port, ~getResult)
  server := Some(started)
})

Vitest.Async.afterAll(async () => {
  switch server.contents {
  | Some(started) => await started.closeAsync()
  | None => ()
  }
})

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: rpc-indexer-shared-fields-e2e
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 1337
    start_block: 100
    rpc:
      url: ${url}
      for: sync
    contracts:
      - name: Token
        address: "${contractAddress}"
`,
  ~schema=`
type Transfer {
  id: ID!
  value: BigInt!
}

type Approval {
  id: ID!
  blockGasUsed: BigInt!
  txGasUsed: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

// Selects nothing of its block or transaction beyond what the log carries.
indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Transfer.set({
    id: \`\${event.block.number}\`,
    value: event.params.value,
  });
});

indexer.onEvent(
  { contract: "Token", event: "Approval", fields: { block: ["gasUsed"], transaction: ["gasUsed"] } },
  async ({ event, context }) => {
    context.Approval.set({
      id: \`\${event.block.number}\`,
      blockGasUsed: event.block.gasUsed,
      txGasUsed: event.transaction.gasUsed,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Approval, type Transfer } from "envio";

describe("Two registrations selecting different fields of the same chain", () => {
  it("serves each its own fields", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 101 } } });

    const expected: [Transfer, Approval] = [
      { id: "100", value: 3n },
      { id: "101", blockGasUsed: 202n, txGasUsed: 303n },
    ];
    t.expect([
      await indexer.Transfer.get("100"),
      await indexer.Approval.get("101"),
    ]).toEqual(expected);
  });
});
`,
)

// Block 100 carries only the Transfer, which selects no transaction field, so
// the receipt read belongs to block 101 alone. Both blocks are read either way:
// they are the range's own boundaries.
Vitest.it("pays for a receipt only where an event selected one", t => {
  t.expect(mock()->RpcE2eChain.callSummary).toEqual([
    "eth_getBlockByNumber",
    "eth_getBlockByNumber",
    `eth_getLogs "0x64"-"0x65"`,
    "eth_getTransactionReceipt",
  ])
})
