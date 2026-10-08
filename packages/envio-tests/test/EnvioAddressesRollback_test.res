open Vitest

// https://github.com/enviodev/hyperindex/issues/1187
// An address can be registered for two contracts, one row each. A reorg that
// undoes only the later registration removes only that row: the earlier one,
// below the rollback target, has to survive under the same address.

let scenario = Scenario.make(
  ~configYaml=`
name: envio-addresses-rollback
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
      - name: NftFactory
        address: "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c4"
        events:
          - event: "SimpleNftCreated(string name, string symbol, uint256 maxSupply, address contractAddress)"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async () => {});
`,
)

let shared = "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow
let late = "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow

type contractOps = {add: Address.t => unit}
type registerContext = {chain: {"Gravatar": contractOps, "NftFactory": contractOps}}

let registering = (~blockNumber, ~register): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  handler: async _ => (),
  contractRegister: async args =>
    register(args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)),
}

let registered = (indexer: IndexerRunner.t) =>
  indexer.queryAddresses()->Promise.thenResolve(rows =>
    rows
    ->Array.filter(row => row.registrationBlock !== -1)
    ->Array.map(row => (row.address, row.contractName, row.registrationBlock))
    ->Array.toSorted((a, b) => {
      let key = ((address, contract, block)) =>
        `${block->Int.toString->String.padStart(10, "0")} ${contract} ${address->Address.toString}`
      String.compare(key(a), key(b))
    })
  )

describe("A rollback of an address registration", () => {
  scenario->Scenario.it(
    "removes only the registrations after the target, by contract",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [registering(~blockNumber=50, ~register=context => context.chain["Gravatar"].add(shared))],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()
      source.drainItemsQueries(~latestFetchedBlockNumber=100)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          registering(
            ~blockNumber=200,
            ~register=context => {
              context.chain["NftFactory"].add(shared)
              context.chain["NftFactory"].add(late)
            },
          ),
        ],
        // The partition the config's addresses are fetched in.
        ~filter=query => query["p"] === "0",
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()
      source.drainItemsQueries(~latestFetchedBlockNumber=300)
      await indexer.waitUntilIdle()
      let beforeReorg = await registered(indexer)

      await Scenario.reorgAbove(~indexer, ~source, ~head=300, ~validUpTo=100)

      t.expect((beforeReorg, await registered(indexer))).toEqual((
        [(shared, "Gravatar", 50), (shared, "NftFactory", 200), (late, "NftFactory", 200)],
        [(shared, "Gravatar", 50)],
      ))
    },
  )
})
