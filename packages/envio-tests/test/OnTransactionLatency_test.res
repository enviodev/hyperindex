open Vitest

// The progress latency is read off the block of a batch's last item. A
// transaction handler's block is that item's, so it carries the block's
// timestamp whether or not the handler lists it, as an event's block does.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18773,
  ~rpcPort=18774,
  ~height=3,
  ~logs=[],
  ~transactions=[{blockNumber: 2, transactionIndex: 0, from: alice, to: bob}],
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-latency
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
type Sent {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  { name: "from-alice", where: () => ({ transaction: { from: ["${alice}"] } }) },
  async ({ transaction, context }) => {
    context.Sent.set({ id: \`\${context.chain.id}-\${transaction.block.number}\` });
  },
);
`,
)

describe("onTransaction progress latency", () => {
  Async.it("is reported for a chain with only transaction handlers", async t => {
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let latencies = await indexer.metric("envio_progress_latency")
        let sent: array<{"id": string}> = await indexer.query("Sent")
        t.expect((
          latencies->Array.length,
          sent->Array.map(sent => sent["id"])->Array.toSorted(String.compare),
        )).toEqual((2, ["1-2", "2-2"]))
      },
    )
  })
})
