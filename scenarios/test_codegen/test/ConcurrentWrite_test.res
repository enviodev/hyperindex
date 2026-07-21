open Vitest

describe("Concurrent batch write and processing", () => {
  Async.it(
    "Should not rewrite a history change already persisted by an in-flight write",
    async t => {
      let writeBatchCalls = ref(0)
      let writeBatchErrors = []
      let stallWriteBatch: ref<option<promise<unit>>> = ref(None)

      let sourceMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sourceConfig: Config.CustomSources([sourceMock.source]),
          },
        ],
        ~mapStorage=storage => {
          ...storage,
          writeBatch: (
            ~batch,
            ~rollback,
            ~isInReorgThreshold,
            ~config,
            ~allEntities,
            ~updatedEffectsCache,
            ~updatedEntities,
            ~chainMetaData,
            ~onWrite,
          ) => {
            writeBatchCalls := writeBatchCalls.contents + 1
            let run = async () => {
              switch stallWriteBatch.contents {
              | Some(gate) => await gate
              | None => ()
              }
              // Record failures instead of rethrowing: a write failure crashes
              // the indexer process, which would kill the test run.
              switch await storage.writeBatch(
                ~batch,
                ~rollback,
                ~isInReorgThreshold,
                ~config,
                ~allEntities,
                ~updatedEffectsCache,
                ~updatedEntities,
                ~chainMetaData,
                ~onWrite,
              ) {
              | exception exn =>
                let message = switch exn->JsExn.anyToExnInternal {
                | JsExn(error) => error->JsExn.message->Option.getOr("unknown error")
                | _ => "unknown error"
                }
                writeBatchErrors->Array.push(message)->ignore
              | () => ()
              }
            }
            run()
          },
        },
      )
      await Utils.delay(0)
      await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "1",
                value: "created",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=101,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      // Delete the entity and stall the batch write so it stays in flight
      let resolveStall = ref(() => ())
      stallWriteBatch := Some(Promise.make((resolve, _reject) => resolveStall := () => resolve()))
      let writeBatchCallsBeforeStall = writeBatchCalls.contents
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".deleteUnsafe("1")
            },
          },
        ],
        ~latestFetchedBlockNumber=102,
        ~resolveAt=#first,
      )
      while writeBatchCalls.contents == writeBatchCallsBeforeStall {
        await Utils.delay(1)
      }

      // Re-create the entity while the delete's write is still in flight
      let recreateProcessed = ref(false)
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({
                id: "1",
                value: "recreated",
              })
              recreateProcessed := true
            },
          },
        ],
        ~latestFetchedBlockNumber=103,
        ~resolveAt=#first,
      )
      while !recreateProcessed.contents {
        await Utils.delay(1)
      }
      // Let the processed batch get queued for the next write
      await Utils.delay(1)

      stallWriteBatch := None
      resolveStall.contents()
      await indexerMock.getBatchWritePromise()

      t.expect(
        (writeBatchErrors, await indexerMock.queryHistory(SimpleEntity)),
        ~message="The delete history row persisted by the in-flight write must not be written again by the next write",
      ).toEqual((
        [],
        [
          Set({
            checkpointId: 2n,
            entityId: "1",
            entity: {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "created",
            },
          }),
          Delete({
            checkpointId: 3n,
            entityId: "1",
          }),
          Set({
            checkpointId: 4n,
            entityId: "1",
            entity: {
              Indexer.Entities.SimpleEntity.id: "1",
              value: "recreated",
            },
          }),
        ],
      ))
    },
  )
})
