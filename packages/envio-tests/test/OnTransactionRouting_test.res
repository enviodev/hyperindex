open Vitest

// Transaction handlers, from a user's config.yaml and handler source to the
// rows the indexer writes. Chain 1 fetches over HyperSync and chain 2 over RPC,
// from the same served transactions; each handler writes one Routed row per
// transaction it runs on.

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"
let carol = "0x3333333333333333333333333333333333333333"
let transfer = "0xa9059cbb"
let approve = "0x095ea7b3"
let args = String.repeat("0", 64)

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18761,
  ~rpcPort=18762,
  ~height=6,
  ~logs=[],
  ~transactions=[
    {blockNumber: 1, transactionIndex: 0, from: alice, to: bob, input: transfer ++ args},
    {blockNumber: 2, transactionIndex: 0, from: carol, to: bob},
    // A contract creation: it has no `to`.
    {blockNumber: 3, transactionIndex: 0, from: alice, input: "0x6080604052"},
    {blockNumber: 4, transactionIndex: 1, from: carol, to: carol, input: approve ++ args},
    {blockNumber: 5, transactionIndex: 0, from: bob, to: alice, input: transfer, status: 0},
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: on-transaction-routing
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[2],
      ~contracts=`
      - name: Token
        address: "${carol}"`,
    )}
`,
  ~schema=ServedEvmChain.routedSchema,
  ~handlers=`
import { indexer } from "envio";

const route =
  (name: string) =>
  async ({ transaction, block, context }: { transaction: { transactionIndex: number }; block: { number: number }; context: any }) =>
    context.Routed.set({ id: \`\${context.chain.id}-\${block.number}-\${transaction.transactionIndex}-\${name}\` });

indexer.onTransaction(
  { name: "from-alice", where: () => ({ transaction: { from: ["${alice}"] } }) },
  route("from-alice"),
);
indexer.onTransaction(
  { name: "to-bob-or-carol", where: () => ({ transaction: { to: ["${bob}", "${carol}"] } }) },
  route("to-bob-or-carol"),
);
indexer.onTransaction(
  { name: "transfer-or-approve", where: () => ({ transaction: { sighash: ["${transfer}", "${approve}"] } }) },
  route("transfer-or-approve"),
);
indexer.onTransaction(
  { name: "alice-transfers", where: () => ({ transaction: { from: ["${alice}"], sighash: ["${transfer}"] } }) },
  route("alice-transfers"),
);
indexer.onTransaction(
  { name: "succeeded", where: () => ({ transaction: { status: 1 } }) },
  route("succeeded"),
);
indexer.onTransaction(
  { name: "reverted-from-bob", where: () => ({ transaction: { from: ["${bob}"], status: 0 } }) },
  route("reverted-from-bob"),
);
indexer.onTransaction({ name: "everything", where: () => true }, route("everything"));
indexer.onTransaction({ name: "nothing", where: () => false }, route("nothing"));
indexer.onTransaction(
  { name: "to-alice-on-rpc", where: ({ chain }) => chain.id === 2 && { transaction: { to: ["${alice}"] } } },
  route("to-alice-on-rpc"),
);
`,
)

describe("onTransaction routing", () => {
  Async.it(
    "runs each handler on the transactions its filter matches, over both sources",
    async t => {
      await served->ServedEvmChain.run(
        scenario,
        async indexer => {
          let routed = (~chainId, ~blockNumber, ~transactionIndex=0, name) =>
            ServedEvmChain.routed(~chainId, ~blockNumber, ~logIndex=transactionIndex, name)
          t.expect(await indexer->ServedEvmChain.readRouted).toEqual(
            [1, 2]
            ->Array.flatMap(
              chainId => {
                let routed = routed(~chainId, ...)
                [
                  routed(~blockNumber=1, "from-alice"),
                  routed(~blockNumber=1, "to-bob-or-carol"),
                  routed(~blockNumber=1, "transfer-or-approve"),
                  routed(~blockNumber=1, "alice-transfers"),
                  routed(~blockNumber=1, "succeeded"),
                  routed(~blockNumber=1, "everything"),
                  routed(~blockNumber=2, "to-bob-or-carol"),
                  routed(~blockNumber=2, "succeeded"),
                  routed(~blockNumber=2, "everything"),
                  routed(~blockNumber=3, "from-alice"),
                  routed(~blockNumber=3, "succeeded"),
                  routed(~blockNumber=3, "everything"),
                  routed(~blockNumber=4, ~transactionIndex=1, "to-bob-or-carol"),
                  routed(~blockNumber=4, ~transactionIndex=1, "transfer-or-approve"),
                  routed(~blockNumber=4, ~transactionIndex=1, "succeeded"),
                  routed(~blockNumber=4, ~transactionIndex=1, "everything"),
                  routed(~blockNumber=5, "transfer-or-approve"),
                  routed(~blockNumber=5, "reverted-from-bob"),
                  routed(~blockNumber=5, "everything"),
                  ...chainId == 2 ? [routed(~blockNumber=5, "to-alice-on-rpc")] : [],
                ]
              },
            )
            ->ServedEvmChain.sorted,
          )
        },
      )
    },
  )

  // A filter naming no call field is also what a `where` forgetting its
  // filter object evaluates to, so registering one is said once per chain,
  // with what it costs over RPC.
  Async.it("warns about a filter that runs on every transaction", async t => {
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let warning = (~name, ~chainId, ~rpcCost) =>
          `\`indexer.onTransaction("${name}")\` runs on every transaction of chain ${chainId->Int.toString}: its filter names no \`from\`, \`to\` or \`sighash\`.${rpcCost}`
        t.expect(
          indexer.infoAndAboveLogs()
          ->Array.filter(({msg}) => msg->String.includes("runs on every transaction"))
          ->Array.map(({msg}) => msg),
        ).toEqual([
          warning(~name="succeeded", ~chainId=1, ~rpcCost=""),
          warning(
            ~name="succeeded",
            ~chainId=2,
            ~rpcCost=" Over RPC that reads every block in full, and a receipt for every transaction to check its status.",
          ),
          warning(~name="everything", ~chainId=1, ~rpcCost=""),
          warning(
            ~name="everything",
            ~chainId=2,
            ~rpcCost=" Over RPC that reads every block in full.",
          ),
        ])
      },
    )
  })
})
