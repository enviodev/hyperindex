open Vitest

// https://github.com/enviodev/hyperindex/issues/1188
//
// Contract registers run per partition response, so the block a registration
// carries is the block of whichever partition answered — not the chain's
// progress. A partition lagging behind can therefore register an address that a
// partition running ahead already registered, at an earlier block. The store
// rejects that as a duplicate with only a warning, so the address is never
// fetched over the range between the two blocks and its events there are lost.
//
// The first case pins what is lost today; the second is the control showing the
// same registration is honoured in full when nothing holds the address yet. A
// fix that backfills the missing range flips the first case's expectations to
// the second's — queried from block 50, persisted at block 50.

let handler: Internal.genericHandlerArgs<
  MockIndexer.eventLog<unknown>,
  MockIndexer.handlerContext,
> => promise<unit> = async _ => ()

let registeringItem = (~blockNumber, ~register): MockIndexer.Source.itemMock => {
  blockNumber,
  logIndex: 0,
  handler,
  contractRegister: async ({context}) => register(context),
}

// The Gravatar address the chain is configured with — the partition that runs ahead.
let configured = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Address.Evm.fromStringOrThrow
let lagging = "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow
let contested = "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow
let fresh = "0x3333333333333333333333333333333333333333"->Address.Evm.fromStringOrThrow

let queriesFor = (sourceMock: MockIndexer.Source.t, ~address) =>
  sourceMock.getItemsOrThrowCalls->Array.filter(call =>
    call.payload->MockIndexer.Source.CallPayload.addresses->Array.includes(address)
  )

let pendingQuery = (sourceMock, ~address) =>
  sourceMock
  ->queriesFor(~address)
  ->Array.get(0)
  ->Option.getOrThrow(~message=`No pending query for ${address->Address.toString}`)

let fromBlocks = (sourceMock, ~address) =>
  sourceMock->queriesFor(~address)->Array.map(call => call.payload["fromBlock"])

let registrationBlocks = (indexerMock: MockIndexer.Indexer.t) =>
  (
    indexerMock.queryRaw(InternalTable.EnvioAddresses.entityConfig): promise<
      array<InternalTable.EnvioAddresses.t>,
    >
  )->Promise.thenResolve(rows =>
    rows
    ->Array.filter(r => r.registrationBlock !== -1)
    ->Array.map(r => (r.id, r.registrationBlock))
  )

// Long enough for every response below to land inside the fetch loop.
let settle = async () => {
  await Utils.delay(0)
  await Utils.delay(0)
  await Utils.delay(0)
}

// Leaves the chain with one partition stuck on its block 10 query while the
// configured address's partition has already registered `contested` at block 900.
let startTheRace = async () => {
  let sourceMock = MockIndexer.Source.make(
    [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
    ~chainId=#1337,
  )
  let indexerMock = await MockIndexer.Indexer.make(
    ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
    // One address per partition, so every registration gets a partition of its
    // own and the query ranges below name a single address.
    ~maxAddrInPartition=1,
  )
  await Utils.delay(0)

  sourceMock.resolveGetHeightOrThrow(10000)
  await settle()

  // The configured address registers a second Gravatar address at block 10,
  // spawning the partition that will lag behind.
  (sourceMock->pendingQuery(~address=configured)).resolve(
    [registeringItem(~blockNumber=10, ~register=context => context.chain.\"Gravatar".add(lagging))],
    ~latestFetchedBlockNumber=100,
  )
  await settle()

  // The configured address races ahead and registers the contested address at
  // block 900 while the block 10 partition is still on its first query.
  (sourceMock->pendingQuery(~address=configured)).resolve(
    [registeringItem(~blockNumber=900, ~register=context => context.chain.\"Gravatar".add(contested))],
    ~latestFetchedBlockNumber=1000,
  )
  await settle()

  (sourceMock, indexerMock)
}

describe("Duplicate address registration from a lagging partition", () => {
  Async.it("drops the earlier registration and never fetches the blocks it covered", async t => {
    let (sourceMock, indexerMock) = await startTheRace()

    let laggingFromBlocks = sourceMock->fromBlocks(~address=lagging)
    let contestedBeforeDuplicate = sourceMock->fromBlocks(~address=contested)

    // The lagging partition answers, registering the same address 850 blocks
    // earlier than the registration already in the store.
    (sourceMock->pendingQuery(~address=lagging)).resolve(
      [
        registeringItem(~blockNumber=50, ~register=context =>
          context.chain.\"Gravatar".add(contested)
        ),
      ],
      ~latestFetchedBlockNumber=100,
    )
    await settle()

    let contestedAfterDuplicate = sourceMock->fromBlocks(~address=contested)

    // Drain everything so the accepted registrations reach the database.
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all, ~latestFetchedBlockNumber=9800)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (
        laggingFromBlocks,
        contestedBeforeDuplicate,
        contestedAfterDuplicate,
        await registrationBlocks(indexerMock),
      ),
      ~message="the block 50 registration buys nothing: blocks 50-899 are never queried for the contested address",
    ).toEqual((
      [10],
      [900],
      [900],
      [(`1337-${lagging->Address.toString}`, 10), (`1337-${contested->Address.toString}`, 900)],
    ))
  })

  // The control: the very same lagging registration is honoured in full when the
  // address isn't already in the store, so the case above is a loss and not just
  // a partition the mock never spawns.
  Async.it("fetches from block 50 when the lagging partition registers a fresh address", async t => {
    let (sourceMock, indexerMock) = await startTheRace()

    (sourceMock->pendingQuery(~address=lagging)).resolve(
      [registeringItem(~blockNumber=50, ~register=context => context.chain.\"Gravatar".add(fresh))],
      ~latestFetchedBlockNumber=100,
    )
    await settle()

    let freshFromBlocks = sourceMock->fromBlocks(~address=fresh)

    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#all, ~latestFetchedBlockNumber=9800)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (freshFromBlocks, await registrationBlocks(indexerMock)),
      ~message="an unclaimed address registered at block 50 is queried from block 50",
    ).toEqual((
      [50],
      [
        (`1337-${lagging->Address.toString}`, 10),
        (`1337-${contested->Address.toString}`, 900),
        (`1337-${fresh->Address.toString}`, 50),
      ],
    ))
  })
})
