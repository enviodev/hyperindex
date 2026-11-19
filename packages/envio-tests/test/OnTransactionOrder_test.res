open Vitest

// A transaction's handlers run before the event handlers of that transaction
// and after the events of earlier ones; block handlers stay last in the block.
// Every handler appends its call to a per-chain sequence, so the rows say in
// which order the indexer ran them. Chain 1 fetches over HyperSync and chain 2
// over RPC.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let token = "0x3333333333333333333333333333333333333333"
let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let transferLog = (~logIndex, ~transactionIndex): ServedEvmChain.log => {
  blockNumber: 2,
  logIndex,
  transactionIndex,
  address: token,
  topics: [transferTopic, alice->ServedEvmChain.addressTopic, bob->ServedEvmChain.addressTopic],
  data: ServedEvmChain.uintTopic(1n),
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18763,
  ~rpcPort=18764,
  ~height=3,
  ~logs=[
    transferLog(~logIndex=0, ~transactionIndex=1),
    transferLog(~logIndex=1, ~transactionIndex=1),
    transferLog(~logIndex=2, ~transactionIndex=2),
  ],
  ~transactions=[
    {blockNumber: 2, transactionIndex: 0, from: alice, to: token},
    {blockNumber: 2, transactionIndex: 1, from: bob, to: token},
    {blockNumber: 2, transactionIndex: 2, from: alice, to: token},
    {blockNumber: 2, transactionIndex: 3, from: token, to: bob},
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-order
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

indexer.onTransaction(
  { name: "to-token", where: () => ({ transaction: { to: ["${token}"] } }) },
  async ({ transaction, block, context }) =>
    record(context, \`to-token \${block.number}/\${transaction.transactionIndex}\`),
);
indexer.onTransaction(
  { name: "from-alice", where: () => ({ transaction: { from: ["${alice}"] } }) },
  async ({ transaction, block, context }) =>
    record(context, \`from-alice \${block.number}/\${transaction.transactionIndex}\`),
);
indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) =>
  record(context, \`Transfer \${event.block.number}/\${event.logIndex}\`),
);
indexer.onBlock(
  { name: "block", where: () => ({ block: { number: { _gte: 2, _lte: 2 } } }) },
  async ({ block, context }) => record(context, \`block \${block.number}\`),
);
`,
)

type call = {id: string, name: string}

describe("onTransaction order", () => {
  Async.it(
    "runs a transaction's handlers between the events of the transactions around it",
    async t => {
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
            "to-token 2/0",
            "from-alice 2/0",
            "to-token 2/1",
            "Transfer 2/0",
            "Transfer 2/1",
            "to-token 2/2",
            "from-alice 2/2",
            "Transfer 2/2",
            "block 2",
          ]
          t.expect((sequenceOf(1), sequenceOf(2))).toEqual((expected, expected))
        },
      )
    },
  )
})
