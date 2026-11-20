open Vitest

// `sighash` is a transaction field like any other: the first four bytes of the
// calldata, which a transaction or event handler lists in `fields` and reads
// without fetching the calldata itself. Calldata shorter than a selector has
// none. Chain 1 fetches over HyperSync and chain 2 over RPC.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let token = "0x3333333333333333333333333333333333333333"
let transfer = "0xa9059cbb"
let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18773,
  ~rpcPort=18774,
  ~height=3,
  ~logs=[
    {
      blockNumber: 2,
      logIndex: 0,
      transactionIndex: 0,
      address: token,
      topics: [transferTopic, alice->ServedEvmChain.addressTopic, bob->ServedEvmChain.addressTopic],
      data: ServedEvmChain.uintTopic(1n),
    },
  ],
  ~transactions=[
    {
      blockNumber: 2,
      transactionIndex: 0,
      from: alice,
      to: token,
      input: transfer ++ String.repeat("0", 128),
    },
    {blockNumber: 2, transactionIndex: 1, from: alice, to: bob},
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: transaction-sighash
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
type Seen {
  id: ID!
  sighash: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "from-alice",
    where: () => ({ transaction: { from: ["${alice}"] } }),
    fields: { transaction: ["sighash"] },
  },
  async ({ transaction, context }) => {
    const sighash: string | undefined = transaction.sighash;
    context.Seen.set({
      id: \`\${context.chain.id}-transaction-\${transaction.transactionIndex}\`,
      sighash: sighash ?? "none",
    });
  },
);
indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { transaction: ["sighash"] } },
  async ({ event, context }) => {
    const sighash: string | undefined = event.transaction.sighash;
    context.Seen.set({ id: \`\${context.chain.id}-event-\${event.logIndex}\`, sighash: sighash ?? "none" });
  },
);
`,
)

type seen = {id: string, sighash: string}

describe("transaction.sighash", () => {
  Async.it(
    "reads the calldata's selector on transaction and event handlers, over both sources",
    async t => {
      await served->ServedEvmChain.run(
        scenario,
        async indexer => {
          let seen: array<seen> = await indexer.query("Seen")
          t.expect(seen->Array.toSorted((a, b) => String.compare(a.id, b.id))).toEqual(
            [1, 2]->Array.flatMap(
              chainId => {
                let id = suffix => `${chainId->Int.toString}-${suffix}`
                [
                  {id: id("event-0"), sighash: transfer},
                  {id: id("transaction-0"), sighash: transfer},
                  {id: id("transaction-1"), sighash: "none"},
                ]
              },
            ),
          )
        },
      )
    },
  )
})
