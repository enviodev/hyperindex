open Belt
open RescriptMocha

// A workaround for ReScript v11 issue, where it makes the field optional
// instead of setting a value to undefined. It's fixed in v12.
let undefined = (%raw(`undefined`): option<'a>)

describe("E2E tests", () => {
  Async.it("Currectly starts indexing from a non-zero start block", async () => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let _indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock.source],
          startBlock: 100,
        },
      ],
    )
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock.getHeightOrThrowCalls->Array.length,
      1,
      ~message="should have called getHeightOrThrow to get initial height",
    )
    sourceMock.resolveGetHeightOrThrow(400)
    await Utils.delay(0)
    await Utils.delay(0)

    Assert.deepEqual(
      sourceMock.getItemsOrThrowCalls,
      [{"fromBlock": 100, "toBlock": Some(200), "retry": 0}],
      ~message="Should request items from start block to reorg threshold",
    )
  })

  Async.it("Correctly sets Prom metrics", async () => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sources: [sourceMock.source],
        },
      ],
    )
    await Utils.delay(0)

    Assert.deepEqual(
      await indexerMock.metric("envio_reorg_threshold"),
      [{value: "0", labels: Js.Dict.empty()}],
    )
    Assert.deepEqual(
      await indexerMock.metric("hyperindex_synced_to_head"),
      [{value: "0", labels: Js.Dict.empty()}],
    )

    await Mock.Helper.initialEnterReorgThreshold(~sourceMock)

    Assert.deepEqual(
      await indexerMock.metric("envio_reorg_threshold"),
      [{value: "1", labels: Js.Dict.empty()}],
    )
    Assert.deepEqual(
      await indexerMock.metric("hyperindex_synced_to_head"),
      [{value: "0", labels: Js.Dict.empty()}],
    )

    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()

    Assert.deepEqual(
      await indexerMock.metric("hyperindex_synced_to_head"),
      [{value: "1", labels: Js.Dict.empty()}],
      ~message="should have set hyperindex_synced_to_head metric to 1",
    )
  })
})
