open Vitest

// End-to-end guard that switching a contract to client-side address filtering
// never double-processes an event. When the switch collapses a contract's
// partitions into one address-free partition at their minimum frontier, the
// address-free partition re-fetches the overlap; those re-delivered events must be
// deduped against the ones still in the buffer (nothing above the min frontier
// has been processed yet).
describe("Client-side address filtering item dedup", () => {
  Async.it("does not process an event twice across the switch to client-side filtering", async t => {
    let processed = []
    let record = (~blockNumber, ~logIndex) =>
      (async _ => processed->Array.push((blockNumber, logIndex))->ignore)->Obj.magic

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      // Switch Gravatar to client-side filtering as soon as it has >2 registered addresses.
      ~clientFilterAddressThreshold=2,
      ~maxAddrInPartition=1,
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(1000)
    await Utils.delay(0)
    await Utils.delay(0)

    // Snapshot the pre-switch queries so we can require a *newly appended*
    // post-switch re-fetch below — the initial fetch also starts at/below block
    // 10, so it must not satisfy the overlap assertion on its own.
    let preSwitchCalls = sourceMock.getItemsOrThrowCalls->Utils.Array.copy

    // Fetch a Gravatar event at block 10 that registers 3 dynamic Gravatar
    // addresses. That pushes Gravatar past the threshold and collapses its
    // partitions into a single address-free partition mid-response.
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 10,
          logIndex: 0,
          handler: record(~blockNumber=10, ~logIndex=0),
          contractRegister: async ({context}) => {
            context.chain.\"Gravatar".add(
              "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow,
            )
            context.chain.\"Gravatar".add(
              "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow,
            )
            context.chain.\"Gravatar".add(
              "0x3333333333333333333333333333333333333333"->Address.Evm.fromStringOrThrow,
            )
          },
        },
      ],
      ~latestFetchedBlockNumber=10,
    )
    await Utils.delay(0)
    await Utils.delay(0)
    await Utils.delay(0)

    // The switch dragged the collapsed partition's frontier back below block 10,
    // so a *newly issued* query (not one of the pre-switch calls) re-queries a
    // range covering block 10 — the overlap the dedup must absorb.
    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.some(c =>
        !(preSwitchCalls->Array.includes(c)) && c.payload["fromBlock"] <= 10
      ),
      ~message="a new query re-fetches over block 10 after the switch",
    ).toBe(true)

    // The address-free partition re-fetches from its (min) frontier and re-delivers
    // the block-10 event; advance it to the head so the buffered block-10 event
    // becomes processable. The re-delivered copy must be deduped.
    sourceMock.resolveGetItemsOrThrow(
      [{blockNumber: 10, logIndex: 0, handler: record(~blockNumber=10, ~logIndex=0)}],
      ~resolveAt=#all,
      ~latestFetchedBlockNumber=200,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      processed,
      ~message="the block-10 event is processed exactly once despite the backfill re-fetch",
    ).toEqual([(10, 0)])
  })
})
