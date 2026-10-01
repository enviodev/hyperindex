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

// Both events ride the same contract, so one log stream carries both: a
// Transfer in 100 whose registration selects nothing off its transaction, and
// an Approval in 101 whose registration selects a receipt field.
let transferBlock = 100
let approvalBlock = 101

let logs: array<RpcE2eChain.transfer> = [
  {blockNumber: transferBlock, value: 3, logIndex: 0},
  {blockNumber: approvalBlock, value: 4, logIndex: 0, sighash: approvalSighash},
]

let receiptJson = hash =>
  JSON.parseOrThrow(
    `{"transactionHash":"${hash}","blockNumber":"${approvalBlock->hex}","transactionIndex":"0x0","gasUsed":"${(approvalBlock *
      3)->hex}"}`,
  )

let mock = serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    resultFor(
      ~transfers=logs,
      ~height=105,
      ~blockFields=blockNumber => `,"gasUsed":"${(blockNumber * 2)->hex}"`,
      ~receiptFor=receiptJson,
      ~method,
      ~params,
    )
  )
)

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
