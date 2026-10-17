open Vitest

// Regression test for https://github.com/enviodev/hyperindex/issues/1512:
// reorg rollback used to touch the Postgres envio_history_* table of every
// entity, including ClickHouse-only ones whose history tables are never
// created, crashing with `relation "public.envio_history_..." does not exist`.

let chOnlyEntityName = "EntityWithTimestamp"

// `@storage(clickhouse: {})` is how a user reroutes one entity to ClickHouse
// alone: Postgres owns neither its entity table nor its history table.
let scenario = Scenario.make(
  ~configYaml=`
name: rollback-clickhouse-only
rollback_on_reorg: true
storage:
  postgres:
    default: true
  clickhouse: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent(string value)"
chains:
  - id: 1337
    rpc:
      url: https://rpc1337.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type SimpleEntity {
  id: ID!
  value: String!
}

type EntityWithTimestamp @storage(clickhouse: {}) {
  id: ID!
  timestamp: Timestamp!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  context.SimpleEntity.set({ id: "1", value: event.params.value });
  context.EntityWithTimestamp.set({ id: "ch-only", timestamp: new Date(event.block.number) });
});
`,
  ~unsupported=[
    {
      backend: #postgres,
      reason: "the ClickHouse-only entity needs a ClickHouse database to write into",
    },
  ],
)

type simpleEntity = {id: string, value: string}

let setValue = (~block, value): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  blockNumber: block,
  logIndex: 0,
  params: dict{"value": value->(Utils.magic: string => unknown)},
}

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let indexerErrorResolve = ref(None)
let indexerErrorPromise = Promise.make((resolve, _reject) => {
  indexerErrorResolve := Some(resolve)
})

// Surfaces a loop-level failure as this test's failure instead of letting the
// awaited step hang until the suite times out.
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

describe("Rollback with a ClickHouse-only entity", () => {
  scenario->Scenario.it(
    "Skips ClickHouse-only entities on rollback instead of querying their missing history tables",
    ~sources=[{chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    ~onError=errHandler => {
      let resolve =
        indexerErrorResolve.contents->Option.getOrThrow(
          ~message="Indexer error observer was not initialized",
        )
      resolve(errHandler)
    },
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.enterReorgThreshold(~indexer, ~source=sourceMock)

      await sourceMock.expectItemsQueries([
        {
          fromBlock: 101,
          toBlock: Unbounded,
          reply: Respond({
            items: [setValue(~block=101, "value-1"), setValue(~block=102, "value-2")],
            latestFetchedBlockNumber: 102,
          }),
        },
      ])
      await indexer.getBatchWritePromise()->raiseOnIndexerError

      let missingHistoryRelationError = try {
        let _ = await indexer.queryHistory(chOnlyEntityName)
        "the history table exists"
      } catch {
      | exn =>
        exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")
      }
      t.expect(
        (
          missingHistoryRelationError->String.includes(
            `relation "${indexer.pg.pgSchema}.envio_history_${chOnlyEntityName}" does not exist`,
          ),
          await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        ),
        ~message="The ClickHouse-only entity should have no Postgres history table, while the Postgres entity is written",
      ).toEqual((true, [{id: "1", value: "value-2"}]))

      // Should trigger rollback
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 103,
          toBlock: Unbounded,
          reply: Respond({items: [], prevRangeLastBlock: {blockNumber: 102, blockHash: "0x102a"}}),
        },
      ])

      await sourceMock.expectBlockHashLookup({
        blockNumbers: [100, 101],
        reply: [
          // The block 100 is untouched so we can rollback to it; 101 came
          // back on a different hash, so it is part of the reorg.
          {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
          {blockNumber: 101, blockHash: "0x101a", blockTimestamp: 101},
        ],
      })

      await indexer.getRollbackReadyPromise()->raiseOnIndexerError

      // Commit the rollback diff with an empty reprocessing batch. The write
      // prunes post-target history rows, exercising the same per-entity filter.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 101,
          toBlock: Unbounded,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 102,
            latestFetchedBlockHash: "0x102a",
          }),
        },
      ])
      await indexer.getBatchWritePromise()->raiseOnIndexerError

      t.expect(
        await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>),
        ~message="The Postgres entity created after the rollback target should be reverted",
      ).toEqual([])
    },
  )
})
