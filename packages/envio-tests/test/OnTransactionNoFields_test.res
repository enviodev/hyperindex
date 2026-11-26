open Vitest

// A handler that reads only `transaction.block.number` and filters on nothing
// fetched, `status: [0, 1]` with no address, asks a source for no transaction
// field. It still runs on every transaction. Chain 1 fetches over HyperSync and
// chain 2 over RPC.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18773,
  ~rpcPort=18774,
  ~height=3,
  ~logs=[],
  ~transactions=[
    {blockNumber: 2, transactionIndex: 0, from: alice, to: bob},
    {blockNumber: 3, transactionIndex: 0, from: bob, to: alice, status: 0},
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-no-fields
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[2],
      ~contracts=`
      - name: Token
        address: "${bob}"`,
    )}
`,
  ~schema=`
type Run {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  { name: "every", where: () => ({ transaction: { status: [0, 1] } }) },
  async ({ transaction, context }) => {
    context.Run.set({ id: \`\${context.chain.id}-\${transaction.block.number}\` });
  },
);
`,
)

describe("onTransaction asking for no transaction field", () => {
  Async.it("runs on every transaction over both sources", async t => {
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let runs: array<{"id": string}> = await indexer.query("Run")
        t.expect(runs->Array.map(run => run["id"])->Array.toSorted(String.compare)).toEqual([
          "1-2",
          "1-3",
          "2-2",
          "2-3",
        ])
      },
    )
  })
})
