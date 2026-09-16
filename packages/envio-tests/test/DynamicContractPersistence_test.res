open Vitest

// Dynamic registrations are drained from the address store into envio_addresses
// when the batch that processed their event is written. One row per
// (address, contract). A rejected same-pair registration is not written.
let scenario = Scenario.make(
  ~configYaml=`
name: dynamic-contract-persistence
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
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
  // A dynamically registered address only spawns a partition when some
  // registration depends on its contract, so both contracts are indexed here
  // rather than relying on the mock source's synthetic registration.
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async () => {});
`,
)

let queryAddresses = (indexer: IndexerRunner.t) =>
  indexer.queryAddresses()->Promise.thenResolve(rows =>
    rows
    ->Array.filter(r => r.registrationBlock !== -1)
    ->Array.map(r => (r.address, r.contractName, r.registrationBlock))
  )

let dcAddress = "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow
let lateDcAddress = "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow

let row = (address, contractName, registrationBlock) => (
  address,
  contractName,
  registrationBlock,
)

type contractOps = {add: Address.t => unit}
type registerContext = {chain: {"Gravatar": contractOps, "NftFactory": contractOps}}

// An event whose only job is to register `address` for `contractName`.
let registeringItem = (~blockNumber, ~register): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  handler: async _ => (),
  contractRegister: async args =>
    register(args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)),
}

let withIndexer = body =>
  scenario->Scenario.run(
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~indexer, ~source) => {
      let sourceMock = source(1337)

      sourceMock.resolveGetHeightOrThrow(1000)
      await Utils.delay(0)
      await Utils.delay(0)

      await body(sourceMock, indexer)
    },
  )

describe("Dynamic contract persistence", () => {
  Async.it("writes one row for an address registered by several events", async t => {
    await withIndexer(
      async (sourceMock, indexer) => {
        // Two events in different blocks register the same address. The second is a
        // duplicate the store rejects, so only the first is ever written.
        sourceMock.resolveGetItemsOrThrow(
          [
            registeringItem(
              ~blockNumber=10,
              ~register=context => context.chain["Gravatar"].add(dcAddress),
            ),
            registeringItem(
              ~blockNumber=11,
              ~register=context => context.chain["Gravatar"].add(dcAddress),
            ),
          ],
          ~latestFetchedBlockNumber=200,
        )
        await indexer.getBatchWritePromise()
        // Registering spawns a partition for the new address, and the chain can't
        // progress past the registering block until it has fetched.
        sourceMock.drainItemsQueries(~latestFetchedBlockNumber=200)
        await indexer.getBatchWritePromise()

        t.expect(
          await queryAddresses(indexer),
          ~message="the duplicate registration doesn't produce a second row",
        ).toEqual([row(dcAddress, "Gravatar", 10)])
      },
    )
  })

  // https://github.com/enviodev/hyperindex/issues/1187
  Async.it("writes one row per contract for a shared address", async t => {
    await withIndexer(
      async (sourceMock, indexer) => {
        // One address indexed by two contracts: each registration is its own
        // row, so a resume restores both.
        sourceMock.resolveGetItemsOrThrow(
          [
            registeringItem(
              ~blockNumber=10,
              ~register=context => context.chain["Gravatar"].add(dcAddress),
            ),
            registeringItem(
              ~blockNumber=11,
              ~register=context => context.chain["NftFactory"].add(dcAddress),
            ),
          ],
          ~latestFetchedBlockNumber=200,
        )
        await indexer.getBatchWritePromise()
        // Registering spawns a partition for the new address, and the chain can't
        // progress past the registering block until it has fetched.
        sourceMock.drainItemsQueries(~latestFetchedBlockNumber=200)
        await indexer.getBatchWritePromise()

        t.expect(
          await queryAddresses(indexer),
          ~message="each contract's registration of the address gets its own row",
        ).toEqual([row(dcAddress, "Gravatar", 10), row(dcAddress, "NftFactory", 11)])
      },
    )
  })

  Async.it("writes a registration the first batch didn't progress past", async t => {
    await withIndexer(
      async (sourceMock, indexer) => {
        // Both registrations happen at fetch time, but registering the block 10
        // address spawns a partition that hasn't fetched yet — so the first batch
        // can't progress past block 10, and the block 150 registration has to stay
        // pending until a later batch covers it.
        sourceMock.resolveGetItemsOrThrow(
          [
            registeringItem(
              ~blockNumber=10,
              ~register=context => context.chain["Gravatar"].add(dcAddress),
            ),
            registeringItem(
              ~blockNumber=150,
              ~register=context => context.chain["Gravatar"].add(lateDcAddress),
            ),
          ],
          ~latestFetchedBlockNumber=200,
        )
        await indexer.getBatchWritePromise()
        // Nothing is written yet: the chain hasn't progressed to block 10, so both
        // registrations sit pending across this write.
        let afterFirstWrite = await queryAddresses(indexer)

        // Let the new partition fetch only to block 50. Progress lands between the
        // two registration blocks, so the drain has to split the queue: block 10 is
        // covered, block 150 stays pending.
        sourceMock.drainItemsQueries(~latestFetchedBlockNumber=50)
        await indexer.getBatchWritePromise()
        let afterPartialDrain = await queryAddresses(indexer)

        sourceMock.drainItemsQueries(~latestFetchedBlockNumber=200)
        await indexer.getBatchWritePromise()

        t.expect(
          (afterFirstWrite, afterPartialDrain, await queryAddresses(indexer)),
          ~message="each registration lands in the batch that progressed past its block",
        ).toEqual((
          [],
          [row(dcAddress, "Gravatar", 10)],
          [row(dcAddress, "Gravatar", 10), row(lateDcAddress, "Gravatar", 150)],
        ))
      },
    )
  })
})
