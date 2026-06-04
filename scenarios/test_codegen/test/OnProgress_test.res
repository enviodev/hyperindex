open Vitest

let chainAfterBatch = (~chainId, ~progressBlockNumber): Batch.chainAfterBatch => {
  batchSize: 1,
  progressBlockNumber,
  sourceBlockNumber: progressBlockNumber,
  totalEventsProcessed: 0.,
  // The invoker only reads `fetchState.chainId`, so a minimal stand-in is enough.
  fetchState: {"chainId": chainId}->(Utils.magic: {"chainId": int} => FetchState.t),
  isProgressAtHeadWhenBatchCreated: false,
}

let progressedChainsById = Dict.fromArray([
  ("1", chainAfterBatch(~chainId=1, ~progressBlockNumber=50)),
  ("2", chainAfterBatch(~chainId=2, ~progressBlockNumber=60)),
])

let chains: Internal.chains = Dict.fromArray([
  ("1", ({id: 1, isRealtime: true}: Internal.chainInfo)),
  ("2", ({id: 2, isRealtime: false}: Internal.chainInfo)),
])

// Captures (chainId, isRealtime, rollbackToBlock) the user callback observes.
let makeCapturingInvoker = () => {
  let received = []
  let handler = (args: Internal.onProgressArgs) => {
    let context =
      args.context->(Utils.magic: Internal.onProgressContext => Envio.onProgressContext)
    received->Array.push((context.chain.id, context.chain.isRealtime, args.rollbackToBlock))->ignore
    Promise.resolve()
  }
  (received, OnProgress.makeInvoker(~handlers=[handler])->Option.getUnsafe)
}

describe("indexer.onProgress invoker", () => {
  it("returns None when no handlers are registered", t => {
    t.expect(OnProgress.makeInvoker(~handlers=[])->Option.isNone).toBe(true)
  })

  Async.it("fires once per progressed chain without a rollback", async t => {
    let (received, invoker) = makeCapturingInvoker()
    await invoker(~progressedChainsById, ~chains, ~rollback=None)
    t.expect(received).toEqual([(1, true, None), (2, false, None)])
  })

  Async.it("surfaces rollbackToBlock only for the rolled-back chain", async t => {
    let (received, invoker) = makeCapturingInvoker()
    let rollback: Persistence.rollback = {
      targetCheckpointId: 0n,
      diffCheckpointId: 1n,
      progressBlockNumberByChainId: Dict.fromArray([("2", 100)]),
    }
    await invoker(~progressedChainsById, ~chains, ~rollback=Some(rollback))
    t.expect(received).toEqual([(1, true, None), (2, false, Some(100))])
  })

  Async.it("is invoked by the write loop after a committed batch", async t => {
    let (received, invoker) = makeCapturingInvoker()
    let base = MockIndexer.Storage.make([])
    let storage = {
      ...base.storage,
      writeBatch: (
        ~batch as _,
        ~rollback as _,
        ~isInReorgThreshold as _,
        ~config as _,
        ~allEntities as _,
        ~updatedEffectsCache as _,
        ~updatedEntities as _,
        ~chainMetaData as _,
      ) => Promise.resolve(),
    }
    let persistence = {
      ...PgStorage.makePersistenceFromConfig(~config=MockIndexer.config, ~storage),
      storageStatus: Persistence.Ready({
        cleanRun: false,
        cache: Dict.make(),
        chains: [],
        reorgCheckpoints: [],
        checkpointId: 0n,
        envioInfo: None,
      }),
    }
    let store = InMemoryStore.make(
      ~entities=MockIndexer.config.allEntities,
      ~persistence,
      ~config=MockIndexer.config,
      ~onError=exn => exn->ErrorHandling.mkLogAndRaise(~msg="Unexpected persistence write failure"),
      ~onProgress=invoker,
    )

    let batch: Batch.t = {
      totalBatchSize: 0,
      items: [],
      progressedChainsById,
      isInReorgThreshold: false,
      checkpointIds: [1n],
      checkpointChainIds: [1],
      checkpointBlockNumbers: [1],
      checkpointBlockHashes: [Null.null],
      checkpointEventsProcessed: [0],
    }
    store->InMemoryStore.commitBatch(~batch, ~chains)
    await store->InMemoryStore.flush

    t.expect(received).toEqual([(1, true, None), (2, false, None)])
  })
})
