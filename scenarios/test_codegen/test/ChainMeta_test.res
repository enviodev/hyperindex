open Vitest

let metaFields = (
  ~buffer,
  ~firstEvent=?,
  ~readyAt=?,
  ~isHyperSync=false,
): InternalTable.Chains.metaFields => {
  firstEventBlockNumber: firstEvent->Null.fromOption,
  latestFetchedBlockNumber: buffer,
  timestampCaughtUpToHeadOrEndblock: readyAt->Null.fromOption,
  isHyperSync,
}

let emptyBatch = (~checkpointId): Batch.t => {
  totalBatchSize: 0,
  items: [],
  progressedChainsById: Dict.make(),
  isInReorgThreshold: false,
  checkpointIds: [checkpointId],
  checkpointChainIds: [1],
  checkpointBlockNumbers: [checkpointId->BigInt.toInt],
  checkpointBlockHashes: [`0x${checkpointId->BigInt.toString}`->Null.make],
  checkpointEventsProcessed: [0],
}

// Records chain-metadata writes, split by path: idle upsert vs. folded batch write.
let makeStore = () => {
  let setChainMetaCalls = []
  let writeBatchChainMetaCalls = []
  let base = MockIndexer.Storage.make([])
  let storage = {
    ...base.storage,
    setChainMeta: chainsData => {
      setChainMetaCalls->Array.push(chainsData)->ignore
      Promise.resolve(%raw(`undefined`))
    },
    writeBatch: (
      ~batch as _,
      ~rawEvents as _,
      ~rollback as _,
      ~isInReorgThreshold as _,
      ~config as _,
      ~allEntities as _,
      ~updatedEffectsCache as _,
      ~updatedEntities as _,
      ~chainMetaData,
    ) => {
      writeBatchChainMetaCalls->Array.push(chainMetaData)->ignore
      Promise.resolve()
    },
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
  )
  (store, setChainMetaCalls, writeBatchChainMetaCalls)
}

describe("InMemoryStore chain metadata", () => {
  Async.it("Folds the staged delta into the batch write when a batch is queued", async t => {
    let (store, setChainMetaCalls, writeBatchChainMetaCalls) = makeStore()
    let meta = metaFields(~buffer=10)

    store->InMemoryStore.setChainMeta(Dict.fromArray([("1", meta)]))
    store->InMemoryStore.commitBatch(~batch=emptyBatch(~checkpointId=1n))
    await store->InMemoryStore.flush

    t.expect((setChainMetaCalls, writeBatchChainMetaCalls)).toEqual((
      [],
      [Some(Dict.fromArray([("1", meta)]))],
    ))
  })

  Async.it("Flushes metadata via a standalone upsert when no batch is queued", async t => {
    let (store, setChainMetaCalls, writeBatchChainMetaCalls) = makeStore()
    let meta = metaFields(~buffer=10, ~firstEvent=3, ~isHyperSync=true)

    store->InMemoryStore.setChainMeta(Dict.fromArray([("1", meta)]))
    await store->InMemoryStore.flush

    t.expect((setChainMetaCalls, writeBatchChainMetaCalls)).toEqual((
      [Dict.fromArray([("1", meta)])],
      [],
    ))
  })

  Async.it("Drops unchanged metadata so it isn't written twice", async t => {
    let (store, setChainMetaCalls, _) = makeStore()
    let meta = metaFields(~buffer=10)

    store->InMemoryStore.setChainMeta(Dict.fromArray([("1", meta)]))
    await store->InMemoryStore.flush
    // Identical value restaged, so no further write.
    store->InMemoryStore.setChainMeta(Dict.fromArray([("1", metaFields(~buffer=10))]))
    await store->InMemoryStore.flush

    t.expect(setChainMetaCalls).toEqual([Dict.fromArray([("1", meta)])])
  })

  Async.it("Writes the full snapshot whenever any chain changed", async t => {
    let (store, setChainMetaCalls, _) = makeStore()
    let chain1 = metaFields(~buffer=10)
    let chain2 = metaFields(~buffer=20)

    store->InMemoryStore.setChainMeta(Dict.fromArray([("1", chain1), ("2", chain2)]))
    await store->InMemoryStore.flush
    // Only chain 2 advances, but the write carries the whole snapshot (one upsert).
    let chain2Next = metaFields(~buffer=25)
    store->InMemoryStore.setChainMeta(
      Dict.fromArray([("1", metaFields(~buffer=10)), ("2", chain2Next)]),
    )
    await store->InMemoryStore.flush

    t.expect(setChainMetaCalls).toEqual([
      Dict.fromArray([("1", chain1), ("2", chain2)]),
      Dict.fromArray([("1", chain1), ("2", chain2Next)]),
    ])
  })
})
