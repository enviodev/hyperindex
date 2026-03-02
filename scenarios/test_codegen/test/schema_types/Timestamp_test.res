open Vitest

describe("Load and save an entity with a Timestamp from DB", () => {
  Async.it("be able to set and read entities with Timestamp from DB", async t => {
    let sourceMock = Mock.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await Mock.Indexer.make(
      ~chains=[
        {
          chain: #1337,
          sourceConfig: Config.CustomSources([sourceMock.source]),
        },
      ],
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 100,
          logIndex: 0,
          handler: async ({context}) => {
            context.entityWithTimestamp.set({
              id: "testEntity",
              timestamp: Js.Date.fromString("1970-01-01T00:02:03.456Z"),
            })
          },
        },
      ],
      ~latestFetchedBlockNumber=100,
    )
    await indexerMock.getBatchWritePromise()

    let entities = await indexerMock.query(EntityWithTimestamp)
    switch entities->Js.Array2.find(e => e.id === "testEntity") {
    | Some(entity) =>
      t.expect(entity.timestamp->Js.Date.toISOString).toEqual("1970-01-01T00:02:03.456Z")
    | None => Js.Exn.raiseError("Entity should exist")
    }
  })
})
