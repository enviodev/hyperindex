open Vitest

// https://github.com/enviodev/hyperindex/issues/1810
// The factory's one response holds two registrations of a child, at blocks 10
// and 50, and its contractRegister run collects the later one first. Real
// HyperSync (chain 1) and RPC (chain 2) sources fetch from local servers, so
// the child's pings reach the handler only through the sources' own address
// gate.

let factory = "0x2222222222222222222222222222222222222222"
let child = "0x00000000000000000000000000000000000000c1"

let pointedSighash = "0x8b6d9a9f96300f6c4f945a0cf685cc68e61ed4e0b9f64b4a925e758f5513960f"
let spawnedSighash = "0x0146a4cbbb264a99e78339a2b567e605e6c5e8a133e8e9ceede9f78998cefc99"
let pingSighash = "0xca6e822df923f741dfe968d15d80a18abd25bd1e748bcb9ad81fea5bbb7386af"

let registering = (~blockNumber, ~sighash): ServedEvmChain.log => {
  blockNumber,
  logIndex: 0,
  address: factory,
  topics: [sighash, child->ServedEvmChain.addressTopic],
}

let ping = (~blockNumber): ServedEvmChain.log => {
  blockNumber,
  logIndex: 1,
  address: child,
  topics: [pingSighash],
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18705,
  ~rpcPort=18706,
  ~height=80,
  ~logs=[
    ping(~blockNumber=5),
    registering(~blockNumber=10, ~sighash=spawnedSighash),
    ping(~blockNumber=20),
    registering(~blockNumber=50, ~sighash=pointedSighash),
    ping(~blockNumber=60),
  ],
)

let scenario = Scenario.make(
  ~configYaml=`
name: earliest-registration-served
rollback_on_reorg: false
contracts:
  - name: Factory
    events:
      - event: Pointed(address indexed child)
      - event: Spawned(address indexed child)
  - name: Child
    events:
      - event: Ping()
chains:${served->ServedEvmChain.chainsYaml(
      ~hyperSync=[1],
      ~rpc=[2],
      ~contracts=`
      - name: Factory
        address: "${factory}"`,
    )}
`,
  ~schema=`
type Ping {
  id: ID!
  chainId: Int!
  block: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.contractRegister({ contract: "Factory", event: "Pointed" }, async ({ event, context }) => {
  context.chain.Child.add(event.params.child);
});
indexer.contractRegister({ contract: "Factory", event: "Spawned" }, async ({ event, context }) => {
  // Resolves after the \`Pointed\` handler of the same run, so the run
  // collects the later block's registration first.
  for (let hop = 0; hop < 5; hop++) await Promise.resolve();
  context.chain.Child.add(event.params.child);
});

indexer.onEvent({ contract: "Child", event: "Ping" }, async ({ event, context }) => {
  context.Ping.set({
    id: \`\${event.chainId}-\${event.block.number}\`,
    chainId: event.chainId,
    block: event.block.number,
  });
});
`,
)

type ping = {id: string, chainId: int, block: int}

describe("An address registered twice in one contractRegister run, later block first", () => {
  Async.it("is indexed from the earlier block by real HyperSync and RPC sources", async t =>
    await served->ServedEvmChain.run(
      scenario,
      async indexer => {
        let pings: array<ping> = await indexer.query("Ping")
        let registered =
          (await indexer.queryAddresses())
          ->Array.filter(row => row.contractName === "Child")
          ->Array.map(row => (row.chainId->ChainId.toInt, row.registrationBlock))
        t.expect((
          pings->Array.map(ping => ping.id)->Array.toSorted(String.compare),
          registered->Array.toSorted(((a, _), (b, _)) => Int.compare(a, b)),
        )).toEqual((["1-20", "1-60", "2-20", "2-60"], [(1, 10), (2, 10)]))
      },
    )
  )
})
