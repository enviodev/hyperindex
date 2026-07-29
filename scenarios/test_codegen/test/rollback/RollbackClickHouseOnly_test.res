open Vitest

// Regression test for https://github.com/enviodev/hyperindex/issues/1512:
// reorg rollback used to touch the Postgres envio_history_* table of every
// entity, including ClickHouse-only ones whose history tables are never
// created, crashing with `relation "public.envio_history_..." does not exist`.

let chOnlyEntityName = "EntityWithTimestamp"

// The generated config with one entity rerouted to ClickHouse-only storage,
// like `@storage(clickhouse: {...})` produces — Postgres owns neither its
// entity table nor its history table.
let makeConfig = () => {
  let base = MockIndexer.config
  let userEntities = base.userEntities->Array.map((entityConfig: Internal.entityConfig) =>
    entityConfig.name === chOnlyEntityName
      ? {
          ...entityConfig,
          storage: ({postgres: false, clickhouse: true}: Internal.entityStorage),
        }
      : entityConfig
  )
  let userEntitiesByName = Dict.make()
  userEntities->Array.forEach(entityConfig =>
    userEntitiesByName->Dict.set(entityConfig.name, entityConfig)
  )
  {
    ...base,
    // The mock source registration binds to the chain's first contract, which
    // must have config addresses for the fetch partition to exist. Contracts
    // are ordered alphabetically, so put the ones with addresses first.
    chainMap: base.chainMap->ChainMap.mapWithKey((_, chain) => {
      ...chain,
      contracts: chain.contracts->Array.toSorted((a, b) =>
        Int.toFloat(b.addresses->Array.length - a.addresses->Array.length)
      ),
    }),
    userEntities,
    userEntitiesByName,
    allEntities: userEntities->Array.concat([Config.EnvioAddresses.entityConfig]),
  }
}

describe("Rollback with a ClickHouse-only entity", () => {
  Async.it(
    "Skips ClickHouse-only entities on rollback instead of querying their missing history tables",
    async t => {
      let sourceMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chainId=#1337,
      )
      let resolveIndexerError = ref(None)
      let indexerErrorPromise = Promise.make((resolve, _reject) => {
        resolveIndexerError := Some(resolve)
      })
      let raiseOnIndexerError = promise =>
        Promise.race([
          promise->Promise.thenResolve(_ => None),
          indexerErrorPromise->Promise.thenResolve(errHandler => Some(errHandler)),
        ])->Promise.thenResolve(result =>
          switch result {
          | None => ()
          | Some(errHandler) => errHandler->ErrorHandling.raiseExn
          }
        )
      let indexerMock = await MockIndexer.Indexer.make(
        ~config=makeConfig(),
        ~chains=[
          {
            chain: #1337,
            sourceConfig: Config.CustomSources([sourceMock.source]),
          },
        ],
        ~onError=errHandler => {
          let resolve = resolveIndexerError.contents->Option.getOrThrow(
            ~message="Indexer error observer was not initialized",
          )
          resolve(errHandler)
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
              context.\"SimpleEntity".set({id: "1", value: "value-1"})
              context.\"EntityWithTimestamp".set({
                id: "ch-only",
                timestamp: Date.fromTime(101.),
              })
            },
          },
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({id: "1", value: "value-2"})
              context.\"EntityWithTimestamp".set({
                id: "ch-only",
                timestamp: Date.fromTime(102.),
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=102,
      )
      await indexerMock.getBatchWritePromise()->raiseOnIndexerError

      let missingHistoryRelationError = try {
        let _ = await indexerMock.queryHistory(chOnlyEntityName)
        "the history table exists"
      } catch {
      | exn =>
        exn
        ->JsExn.fromException
        ->Option.flatMap(JsExn.message)
        ->Option.getOr("unknown error")
      }
      t.expect(
        (
          missingHistoryRelationError->String.includes(
            `relation "public.envio_history_${chOnlyEntityName}" does not exist`,
          ),
          await (
            indexerMock.query("SimpleEntity"): promise<array<Indexer.Entities.SimpleEntity.t>>
          ),
        ),
        ~message="The ClickHouse-only entity should have no Postgres history table, while the Postgres entity is written",
      ).toEqual((true, [{Indexer.Entities.SimpleEntity.id: "1", value: "value-2"}]))

      // Should trigger rollback
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=103,
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102-reorged"},
      )
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock.getBlockHashesCalls,
        ~message="Should have called getBlockHashes to find rollback depth",
      ).toEqual([[100]])
      sourceMock.resolveGetBlockHashes([
        // The block 100 is untouched so we can rollback to it
        {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
      ])

      await indexerMock.getRollbackReadyPromise()->raiseOnIndexerError

      // Commit the rollback diff with an empty reprocessing batch. The write
      // prunes post-target history rows, exercising the same per-entity filter.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=102,
        ~latestFetchedBlockHash="0x102-reorged",
      )
      await indexerMock.getBatchWritePromise()->raiseOnIndexerError

      t.expect(
        await (
          indexerMock.query("SimpleEntity"): promise<array<Indexer.Entities.SimpleEntity.t>>
        ),
        ~message="The Postgres entity created after the rollback target should be reverted",
      ).toEqual([])
    },
  )
})
