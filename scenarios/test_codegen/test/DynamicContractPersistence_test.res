open Vitest

// Registered addresses reach `envio_addresses` by being drained from the chain's
// address store when the batch that processed their registering event is
// written — not by riding along on the item. These guard the two properties
// that hand-off has to keep: a rejected registration never produces a row, and
// an accepted one produces exactly one.

let queryAddresses = (indexerMock: MockIndexer.Indexer.t) =>
  (
    indexerMock.queryRaw(InternalTable.EnvioAddresses.entityConfig): promise<
      array<InternalTable.EnvioAddresses.t>,
    >
  )->Promise.thenResolve(rows =>
    rows
    ->Array.filter(r => r.registrationBlock !== -1)
    ->Array.map(r => (r.id, r.contractName, r.registrationBlock))
  )

let dcAddress = "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow

let handler = (async _ => ())->Obj.magic

describe("Dynamic contract persistence", () => {
  Async.it("writes one row for an address registered by several events", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(1000)
    await Utils.delay(0)
    await Utils.delay(0)

    // Two events in different blocks register the same address. The second is a
    // duplicate the store rejects, so only the first is ever written.
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 10,
          logIndex: 0,
          handler,
          contractRegister: async ({context}) => context.chain.\"Gravatar".add(dcAddress),
        },
        {
          blockNumber: 11,
          logIndex: 0,
          handler,
          contractRegister: async ({context}) => context.chain.\"Gravatar".add(dcAddress),
        },
      ],
      ~resolveAt=#all,
      ~latestFetchedBlockNumber=200,
    )
    await indexerMock.getBatchWritePromise()
    // Registering spawns a partition for the new address, and the chain can't
    // progress past the registering block until it has fetched.
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all, ~latestFetchedBlockNumber=200)
    await indexerMock.getBatchWritePromise()

    t.expect(
      await queryAddresses(indexerMock),
      ~message="the duplicate registration doesn't produce a second row",
    ).toEqual([(`1337-${dcAddress->Address.toString}`, "Gravatar", 10)])
  })

  Async.it("writes no row for an address rejected as a conflict", async t => {
    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(1000)
    await Utils.delay(0)
    await Utils.delay(0)

    // One address claimed by two contracts: the first wins, the second is
    // rejected and must not reach the database under either name.
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 10,
          logIndex: 0,
          handler,
          contractRegister: async ({context}) => context.chain.\"Gravatar".add(dcAddress),
        },
        {
          blockNumber: 11,
          logIndex: 0,
          handler,
          contractRegister: async ({context}) => context.chain.\"NftFactory".add(dcAddress),
        },
      ],
      ~resolveAt=#all,
      ~latestFetchedBlockNumber=200,
    )
    await indexerMock.getBatchWritePromise()
    // Registering spawns a partition for the new address, and the chain can't
    // progress past the registering block until it has fetched.
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all, ~latestFetchedBlockNumber=200)
    await indexerMock.getBatchWritePromise()

    t.expect(
      await queryAddresses(indexerMock),
      ~message="the conflicting registration is dropped, the first one stands",
    ).toEqual([(`1337-${dcAddress->Address.toString}`, "Gravatar", 10)])
  })
})
