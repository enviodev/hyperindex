open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: concurrent-write
chains:
  - id: 1337
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
`,
  ~schema=`
type SimpleEntity {
  id: ID!
  value: String!
}
`,
)

type simpleEntity = {id: string, value: string}
type simpleEntityOps = {
  set: simpleEntity => unit,
  deleteUnsafe: string => unit,
}
type handlerContext = {@as("SimpleEntity") simpleEntity: simpleEntityOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

// The stall is driven from the test body but installed by `mapStorage`, which
// is an argument to the test rather than part of its body — so the handles live
// out here, where both can reach them.
let writeBatchCalls = ref(0)
let writeBatchErrors = []
let stallWriteBatch: ref<option<promise<unit>>> = ref(None)

describe("Concurrent batch write and processing", () => {
  scenario->Scenario.it(
    "Should not rewrite a history change already persisted by an in-flight write",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
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
        ~registeredAddresses,
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
            ~registeredAddresses,
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
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler: async args => {
              (args->contextOf).simpleEntity.set({
                id: "1",
                value: "created",
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=101,
      )
      await indexer.getBatchWritePromise()

      // Delete the entity and stall the batch write so it stays in flight
      let resolveStall = ref(() => ())
      stallWriteBatch := Some(Promise.make((resolve, _reject) => resolveStall := (() => resolve())))
      let writeBatchCallsBeforeStall = writeBatchCalls.contents
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              (args->contextOf).simpleEntity.deleteUnsafe("1")
            },
          },
        ],
        ~latestFetchedBlockNumber=102,
      )
      await Scenario.waitUntil(
        () => writeBatchCalls.contents != writeBatchCallsBeforeStall,
        ~message="the delete's batch write to start",
      )

      // Re-create the entity while the delete's write is still in flight
      let recreateProcessed = ref(false)
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 103,
            logIndex: 0,
            handler: async args => {
              (args->contextOf).simpleEntity.set({
                id: "1",
                value: "recreated",
              })
              recreateProcessed := true
            },
          },
        ],
        // The chain has already chunked the rest of the range into queries; this
        // answers the one that carries block 103.
        ~filter=query => query["fromBlock"] === 103,
        ~latestFetchedBlockNumber=103,
      )
      await Scenario.waitUntil(
        () => recreateProcessed.contents,
        ~message="the recreate handler to run",
      )
      // Let the processed batch get queued for the next write
      await Utils.delay(1)

      stallWriteBatch := None
      resolveStall.contents()
      await indexer.getBatchWritePromise()

      t.expect(
        (
          writeBatchErrors,
          await (indexer.queryHistory("SimpleEntity"): promise<array<Change.t<simpleEntity>>>),
        ),
        ~message="The delete history row persisted by the in-flight write must not be written again by the next write",
      ).toEqual((
        [],
        [
          Set({
            checkpointId: 2n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {id: "1", value: "created"},
          }),
          Delete({
            checkpointId: 3n,
            entityId: "1"->EntityId.unsafeOfString,
          }),
          Set({
            checkpointId: 4n,
            entityId: "1"->EntityId.unsafeOfString,
            entity: {id: "1", value: "recreated"},
          }),
        ],
      ))
    },
  )
})
