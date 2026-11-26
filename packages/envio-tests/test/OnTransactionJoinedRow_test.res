open Vitest

// An event handler selecting transaction fields joins its log's transaction
// into the buffer with only those fields. A transaction handler whose filter
// compares a field that row lacks runs on it only once its own fetch brings
// the field, and then once. Chain 1 fetches over HyperSync and chain 2 over
// RPC.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let token = "0x3333333333333333333333333333333333333333"
let carol = "0x4444444444444444444444444444444444444444"
let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let transferLog = (~blockNumber, ~logIndex): ServedEvmChain.log => {
  blockNumber,
  logIndex,
  transactionIndex: 0,
  address: token,
  topics: [transferTopic, alice->ServedEvmChain.addressTopic, bob->ServedEvmChain.addressTopic],
  data: ServedEvmChain.uintTopic(1n),
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18767,
  ~rpcPort=18768,
  ~height=4,
  ~logs=[
    transferLog(~blockNumber=1, ~logIndex=0),
    transferLog(~blockNumber=2, ~logIndex=0),
    transferLog(~blockNumber=4, ~logIndex=1),
  ],
  ~transactions=[
    // No filter fetches it: only its log joins it, with \`from\` alone.
    {blockNumber: 1, transactionIndex: 0, from: carol, to: token},
    {blockNumber: 2, transactionIndex: 0, from: alice, to: token},
    {blockNumber: 3, transactionIndex: 0, from: alice, to: bob},
    {blockNumber: 4, transactionIndex: 0, from: bob, to: token},
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-joined-row
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[2],
      ~contracts=`
      - name: Token
        address: "${token}"`,
    )}
`,
  ~schema=`
type Sequence {
  id: ID!
  calls: Int!
}

type Call {
  id: ID!
  name: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

const record = async (context: any, name: string) => {
  if (context.isPreload) return;
  const chainId = \`\${context.chain.id}\`;
  const sequence = (await context.Sequence.get(chainId)) ?? { id: chainId, calls: 0 };
  context.Sequence.set({ ...sequence, calls: sequence.calls + 1 });
  context.Call.set({ id: \`\${chainId}-\${sequence.calls}\`, name });
};

const route = (name: string) => async ({ transaction, context }: any) =>
  record(context, \`\${name} \${transaction.block.number}/\${transaction.transactionIndex}\`);

// The log's transaction joins with \`from\` alone.
indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { transaction: ["from"] } },
  async ({ event, context }) => record(context, \`Transfer \${event.block.number}/\${event.logIndex}\`),
);
indexer.onTransaction(
  { name: "alice-to-token", where: () => ({ transaction: { from: ["${alice}"], to: ["${token}"] } }), fields: { transaction: ["transactionIndex"] } },
  route("alice-to-token"),
);
indexer.onTransaction(
  { name: "bob-succeeded", where: () => ({ transaction: { from: ["${bob}"], status: [1] } }), fields: { transaction: ["transactionIndex"] } },
  route("bob-succeeded"),
);
indexer.onTransaction(
  { name: "alice-to-bob", where: () => ({ transaction: { from: ["${alice}"], to: ["${bob}"] } }), fields: { transaction: ["transactionIndex"] } },
  route("alice-to-bob"),
);
indexer.onTransaction(
  { name: "carol-to-alice", where: () => ({ transaction: { from: ["${carol}"], to: ["${alice}"] } }), fields: { transaction: ["transactionIndex"] } },
  route("carol-to-alice"),
);
indexer.onTransaction(
  { name: "carol-reverted", where: () => ({ transaction: { from: ["${carol}"], status: [0] } }), fields: { transaction: ["transactionIndex"] } },
  route("carol-reverted"),
);
`,
)

type call = {id: string, name: string}

describe("onTransaction over a row a log joined", () => {
  Async.it("runs once, on the row its own fetch brings", async t => {
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let calls: array<call> = await indexer.query("Call")
        let sequenceOf = chainId =>
          calls
          ->Array.filter(call => call.id->String.startsWith(`${chainId->Int.toString}-`))
          ->Array.toSorted(
            (a, b) => {
              let position = (call: call) =>
                call.id->String.split("-")->Array.getUnsafe(1)->Int.fromString->Option.getOrThrow
              Int.compare(position(a), position(b))
            },
          )
          ->Array.map(call => call.name)
        let expected = [
          "Transfer 1/0",
          "alice-to-token 2/0",
          "Transfer 2/0",
          "alice-to-bob 3/0",
          "bob-succeeded 4/0",
          "Transfer 4/1",
        ]
        t.expect((sequenceOf(1), sequenceOf(2))).toEqual((expected, expected))
      },
    )
  })
})
