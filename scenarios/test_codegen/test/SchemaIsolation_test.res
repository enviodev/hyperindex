open Vitest

// The batch-set query has the schema baked into its text and used to be cached
// per table alone, so a second indexer in the same process sent its rows to the
// first one's schema. Two indexers back to back is what surfaces it: the second
// one writes into a schema that is no longer there.
describe("Schema isolation between indexers in one process", () => {
  let writeEntity = async (~value, ~onError) => {
    let sourceMock = MockIndexer.Source.make(~chainId=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let rows = ref([])
    await MockIndexer.Indexer.run(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~onError,
      async indexerMock => {
        await Utils.delay(0)
        sourceMock.resolveGetHeightOrThrow(300)
        await Utils.delay(0)
        await Utils.delay(0)

        sourceMock.resolveGetItemsOrThrow(
          [
            {
              blockNumber: 1,
              logIndex: 0,
              handler: async ({context}) => {
                context.\"SimpleEntity".set({id: "1", value})
              },
            },
          ],
          ~latestFetchedBlockNumber=100,
        )
        await indexerMock.getBatchWritePromise()

        rows :=
          (
            await (
              indexerMock.query("SimpleEntity"): promise<array<Indexer.Entities.SimpleEntity.t>>
            )
          )
      },
    )
    rows.contents
  }

  Async.it("writes land in the schema of the indexer that made them", async t => {
    // Recorded rather than fatal: a write against the first indexer's dropped
    // schema would otherwise take the whole worker down with it.
    let errors = []
    let onError = (errHandler: ErrorHandling.t) => {
      errors
      ->Array.push(
        errHandler.exn->Utils.prettifyExn->Utils.magic->JsExn.message->Option.getOr("unknown"),
      )
      ->ignore
    }

    let first = await writeEntity(~value="first", ~onError)
    let second = await writeEntity(~value="second", ~onError)

    t.expect(
      (first, second, errors),
      ~message="each indexer reads back its own write from its own schema",
    ).toEqual((
      [{Indexer.Entities.SimpleEntity.id: "1", value: "first"}],
      [{Indexer.Entities.SimpleEntity.id: "1", value: "second"}],
      [],
    ))
  })
})
