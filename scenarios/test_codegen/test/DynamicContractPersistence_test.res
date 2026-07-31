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
let lateDcAddress = "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow

let row = (address, contractName, registrationBlock) => (
  `1337-${address->Address.toString}`,
  contractName,
  registrationBlock,
)

let handler: Internal.genericHandlerArgs<
  MockIndexer.eventLog<unknown>,
  MockIndexer.handlerContext,
> => promise<unit> = async _ => ()

let startIndexer = async () => {
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

  (sourceMock, indexerMock)
}

// An event whose only job is to register `address` for `contractName`.
let registeringItem = (~blockNumber, ~register): MockIndexer.Source.itemMock => {
  blockNumber,
  logIndex: 0,
  handler,
  contractRegister: async ({context}) => register(context),
}

describe("Dynamic contract persistence", () => {
  Async.it("writes one row for an address registered by several events", async t => {
    let (sourceMock, indexerMock) = await startIndexer()

    // Two events in different blocks register the same address. The second is a
    // duplicate the store rejects, so only the first is ever written.
    sourceMock.resolveGetItemsOrThrow(
      [
        registeringItem(~blockNumber=10, ~register=context =>
          context.chain.\"Gravatar".add(dcAddress)
        ),
        registeringItem(~blockNumber=11, ~register=context =>
          context.chain.\"Gravatar".add(dcAddress)
        ),
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
    ).toEqual([row(dcAddress, "Gravatar", 10)])
  })

  Async.it("writes no row for an address rejected as a conflict", async t => {
    let (sourceMock, indexerMock) = await startIndexer()

    // One address claimed by two contracts: the first wins, the second is
    // rejected and must not reach the database under either name.
    sourceMock.resolveGetItemsOrThrow(
      [
        registeringItem(~blockNumber=10, ~register=context =>
          context.chain.\"Gravatar".add(dcAddress)
        ),
        registeringItem(~blockNumber=11, ~register=context =>
          context.chain.\"NftFactory".add(dcAddress)
        ),
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
    ).toEqual([row(dcAddress, "Gravatar", 10)])
  })

  Async.it("writes a registration the first batch didn't progress past", async t => {
    let (sourceMock, indexerMock) = await startIndexer()

    // Both registrations happen at fetch time, but registering the block 10
    // address spawns a partition that hasn't fetched yet — so the first batch
    // can't progress past block 10, and the block 150 registration has to stay
    // pending until a later batch covers it.
    sourceMock.resolveGetItemsOrThrow(
      [
        registeringItem(~blockNumber=10, ~register=context =>
          context.chain.\"Gravatar".add(dcAddress)
        ),
        registeringItem(~blockNumber=150, ~register=context =>
          context.chain.\"Gravatar".add(lateDcAddress)
        ),
      ],
      ~resolveAt=#all,
      ~latestFetchedBlockNumber=200,
    )
    await indexerMock.getBatchWritePromise()
    // Nothing is written yet: the chain hasn't progressed to block 10, so both
    // registrations sit pending across this write.
    let afterFirstWrite = await queryAddresses(indexerMock)

    // Let the new partition fetch only to block 50. Progress lands between the
    // two registration blocks, so the drain has to split the queue: block 10 is
    // covered, block 150 stays pending.
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all, ~latestFetchedBlockNumber=50)
    await indexerMock.getBatchWritePromise()
    let afterPartialDrain = await queryAddresses(indexerMock)

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all, ~latestFetchedBlockNumber=200)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (afterFirstWrite, afterPartialDrain, await queryAddresses(indexerMock)),
      ~message="each registration lands in the batch that progressed past its block",
    ).toEqual((
      [],
      [row(dcAddress, "Gravatar", 10)],
      [row(dcAddress, "Gravatar", 10), row(lateDcAddress, "Gravatar", 150)],
    ))
  })
})
