open Vitest

// Same entity id on two chains. Under `disable_default_cross_chain` it must
// resolve to two independent rows; the @crossChain one stays single.
type counter = {
  id: string,
  count: bigint,
  @as("chainId") chainId: int,
}
type globalCounter = {
  id: string,
  count: bigint,
}

// What a handler sees: the chain is already fixed by the handler's own chain,
// so the chain-id column never reaches the entity object.
type handlerCounter = {id: string, count: bigint}

type counterOps = {
  get: string => promise<option<handlerCounter>>,
  getWhere: {"count": {"_gte": bigint}} => promise<array<handlerCounter>>,
  set: {"id": string, "count": bigint} => unit,
  deleteUnsafe: string => unit,
}
type handlerContext = {
  @as("Counter") counter: counterOps,
  @as("GlobalCounter") globalCounter: counterOps,
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
}

let makeConfigYaml = (~rollback="", ~storage="") =>
  `
name: per-chain
disable_default_cross_chain: true${rollback}
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc1.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 137
    rpc:
      url: https://rpc137.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
${storage}`

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
type GlobalCounter @crossChain {
  id: ID!
  count: BigInt!
}
`

let scenario = Scenario.make(~schema, ~configYaml=makeConfigYaml())

// The two chains need a reorg threshold to roll back within, so this variant
// sets one — `max_reorg_depth` is per chain, so it goes in the chain blocks.
let rollbackScenario = Scenario.make(
  ~schema,
  ~configYaml=makeConfigYaml(~rollback="\nrollback_on_reorg: true")->String.replaceAll(
    "    start_block: 1\n",
    "    start_block: 1\n    max_reorg_depth: 200\n",
  ),
)

// The entity object and the getWhere filter key the chain by `chainId` while
// the column is `chain_id`.
let snakeCaseScenario = Scenario.make(
  ~schema,
  ~configYaml=makeConfigYaml(
    ~storage=`storage:
  postgres:
    column_name_format: snake_case
`,
  ),
)

// The history prune is asserted through raw SQL against the history tables.
let pruneScenario = Scenario.make(
  ~schema,
  ~configYaml=makeConfigYaml(),
  ~unsupported=[
    {
      Scenario.backend: #memory,
      reason: "seeds and reads the history tables with raw SQL",
    },
  ],
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow]
let reorgMethods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

// One event per chain, both bumping the id "total".
let bump = (count: bigint): MockSource.itemMock => {
  blockNumber: 5,
  logIndex: 0,
  handler: async args => {
    let context = args.context->asContext
    context.counter.set({"id": "total", "count": count})
    context.globalCounter.set({"id": "total", "count": count})
  },
}

let setEntities = (~block, ~counter: bigint, ~id="total"): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->asContext
    context.counter.set({"id": id, "count": counter})
  },
}

describe("Per-chain entities against Postgres", () => {
  scenario->Scenario.it(
    "Writes one row per chain and a single row for @crossChain",
    ~sources=[{chain: 1, methods}, {chain: 137, methods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)

      source1.resolveGetHeightOrThrow(300)
      source137.resolveGetHeightOrThrow(300)

      source1.resolveGetItemsOrThrow([bump(1n)], ~latestFetchedBlockNumber=300)
      source137.resolveGetItemsOrThrow([bump(10n)], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      let counters: array<counter> = await indexer.query("Counter")
      let globals: array<globalCounter> = await indexer.query("GlobalCounter")

      await indexer.stop()

      t.expect((
        counters->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
        globals,
      )).toEqual((
        [{id: "total", count: 1n, chainId: 1}, {id: "total", count: 10n, chainId: 137}],
        [{id: "total", count: 10n}],
      ))
    },
  )
})

describe("Chain-scoped rollback", () => {
  // A reorg rolls every chain back to a consistent checkpoint, so what has to
  // be per-chain is the restore itself: the same entity id on two chains must
  // be reverted (or left alone) independently.
  rollbackScenario->Scenario.it(
    "Restores each chain's row from its own history",
    ~sources=[{chain: 1, methods: reorgMethods}, {chain: 137, methods: reorgMethods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=source137),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=source1),
      ))

      // Chain 137 writes the shared id first, then chain 1 — so chain 137's row
      // sits below the checkpoint chain 1 will roll back to.
      source137.resolveGetItemsOrThrow(
        [setEntities(~block=101, ~counter=137n)],
        ~latestFetchedBlockNumber=101,
        ~latestFetchedBlockHash="0x0101",
      )
      await indexer.getBatchWritePromise()
      source1.resolveGetItemsOrThrow(
        [setEntities(~block=101, ~counter=1n)],
        ~latestFetchedBlockNumber=101,
        ~latestFetchedBlockHash="0x0101",
      )
      await indexer.getBatchWritePromise()

      // Chain 1 overwrites its row at block 102, which is the change the reorg
      // takes back.
      source1.resolveGetItemsOrThrow(
        [setEntities(~block=102, ~counter=2n)],
        ~latestFetchedBlockNumber=102,
        ~latestFetchedBlockHash="0x0102",
      )
      await indexer.getBatchWritePromise()

      // Block 102 comes back with a different hash.
      source1.resolveGetItemsOrThrow(
        [setEntities(~block=103, ~counter=99n)],
        ~filter=MockSource.coveringBlock(103),
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102a"},
      )

      await Utils.delay(0)
      await Utils.delay(0)
      source1.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
      ])
      await indexer.getRollbackReadyPromise()

      // The rollback diff is written with the next batch, so drive chain 1 once
      // more (with nothing to index) to flush it.
      source1.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
        ~latestFetchedBlockHash="0x0102",
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      let counters: array<counter> = await indexer.query("Counter")

      await indexer.stop()

      t.expect(counters->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId))).toEqual([
        {id: "total", count: 1n, chainId: 1},
        {id: "total", count: 137n, chainId: 137},
      ])
    },
  )
})

describe("Chain-scoped reads and deletes", () => {
  // A handler always runs on one chain, so a per-chain entity's loads and
  // deletes must never reach another chain's row for the same id.
  scenario->Scenario.it(
    "Never sees or removes another chain's row for the same id",
    ~sources=[{chain: 1, methods}, {chain: 137, methods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)

      source1.resolveGetHeightOrThrow(300)
      source137.resolveGetHeightOrThrow(300)

      // Chain 137 claims the id first and must survive everything chain 1 does.
      source137.resolveGetItemsOrThrow(
        [setEntities(~block=5, ~counter=137n)],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()

      let loadedByChain1 = ref(None)
      let getWhereByChain1 = ref([])

      source1.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 6,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              // Chain 137's row for this id exists, but is out of scope here.
              loadedByChain1 := (await context.counter.get("total"))
              context.counter.set({"id": "total", "count": 1n})
            },
          },
        ],
        // Below head, so the chain asks for another range and the next resolve
        // has a call to answer.
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      source1.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 7,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              getWhereByChain1 := (await context.counter.getWhere({"count": {"_gte": 0n}}))
              context.counter.deleteUnsafe("total")
            },
          },
        ],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      let remaining: array<counter> = await indexer.query("Counter")

      await indexer.stop()

      t.expect((loadedByChain1.contents, getWhereByChain1.contents, remaining)).toEqual((
        // get: chain 137's row is invisible to a chain 1 handler.
        None,
        // getWhere: the storage query is narrowed to chain 1, and the loaded
        // entity carries no chain id.
        [{id: "total", count: 1n}],
        // deleteUnsafe: only chain 1's row went.
        [{id: "total", count: 137n, chainId: 137}],
      ))
    },
  )
})

describe("Per-chain history and removal", () => {
  // A delete inside the reorg threshold writes a history row whose chain id is
  // part of the primary key, and a rollback that removes a row has to remove it
  // from the right chain.
  rollbackScenario->Scenario.it(
    "Writes deletes and rollback removals against the right chain",
    ~sources=[{chain: 1, methods: reorgMethods}, {chain: 137, methods: reorgMethods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)
      await Utils.delay(0)

      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=source137),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=source1),
      ))

      // Both chains hold "shared"; only chain 1 deletes it.
      source137.resolveGetItemsOrThrow(
        [setEntities(~block=101, ~counter=137n, ~id="shared")],
        ~latestFetchedBlockNumber=101,
        ~latestFetchedBlockHash="0x0101",
      )
      await indexer.getBatchWritePromise()
      source1.resolveGetItemsOrThrow(
        [setEntities(~block=101, ~counter=1n, ~id="shared")],
        ~latestFetchedBlockNumber=101,
        ~latestFetchedBlockHash="0x0101",
      )
      await indexer.getBatchWritePromise()

      source1.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.counter.deleteUnsafe("shared")
              // Created after the rollback target with no earlier history, so the
              // rollback has to remove it — from chain 1 only.
              context.counter.set({"id": "chain1-only", "count": 5n})
            },
          },
        ],
        ~latestFetchedBlockNumber=102,
        ~latestFetchedBlockHash="0x0102",
      )
      await indexer.getBatchWritePromise()

      let afterDelete: array<counter> = await indexer.query("Counter")

      // Chain 1 reorgs back to block 101, taking both the delete and the new id.
      source1.resolveGetItemsOrThrow(
        [setEntities(~block=103, ~counter=99n, ~id="ignored")],
        ~filter=MockSource.coveringBlock(103),
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102a"},
      )
      await Utils.delay(0)
      await Utils.delay(0)
      source1.resolveGetBlockHashes([
        {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
        {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
      ])
      await indexer.getRollbackReadyPromise()
      source1.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
        ~latestFetchedBlockHash="0x0102",
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      let afterRollback: array<counter> = await indexer.query("Counter")

      await indexer.stop()

      let sorted = rows =>
        rows->Array.toSorted(
          (a, b) =>
            a.chainId === b.chainId
              ? String.compare(a.id, b.id)
              : Int.compare(a.chainId, b.chainId),
        )

      t.expect((afterDelete->sorted, afterRollback->sorted)).toEqual((
        // The delete took chain 1's "shared" only, and chain 137 kept its own.
        [{id: "chain1-only", count: 5n, chainId: 1}, {id: "shared", count: 137n, chainId: 137}],
        // Rollback restored chain 1's "shared" from its own history, removed the
        // id chain 1 had just created, and left chain 137 alone.
        [{id: "shared", count: 1n, chainId: 1}, {id: "shared", count: 137n, chainId: 137}],
      ))
    },
  )
})

describe("Per-chain entities with renamed columns", () => {
  // The entity object and the getWhere filter key the chain by `chainId` while
  // the column is `chain_id`. A read has to cross that boundary correctly, so
  // run the isolation check again against a snake_case schema.
  snakeCaseScenario->Scenario.it(
    "Isolates chains when the column is renamed",
    ~sources=[{chain: 1, methods}, {chain: 137, methods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)

      source1.resolveGetHeightOrThrow(300)
      source137.resolveGetHeightOrThrow(300)

      source137.resolveGetItemsOrThrow(
        [setEntities(~block=5, ~counter=137n)],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()

      let loadedByChain1 = ref(None)
      source1.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 6,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              loadedByChain1 := (await context.counter.get("total"))
              context.counter.set({"id": "total", "count": 1n})
            },
          },
        ],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      // Rows are keyed by the API field name whatever the column is called.
      let rows: array<counter> = await indexer.query("Counter")

      await indexer.stop()

      t.expect((
        loadedByChain1.contents,
        rows->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
      )).toEqual((
        None,
        [{id: "total", count: 1n, chainId: 1}, {id: "total", count: 137n, chainId: 137}],
      ))
    },
  )
})

describe("Effect scope under the disabled default", () => {
  // An effect that states no `crossChain` follows the config. Under
  // `disable_default_cross_chain` that means a cache table per chain, which is
  // only observable once the effect actually caches.
  let unscoped = Envio.createEffect(
    {
      name: "unscopedProbe",
      input: S.string,
      output: S.int,
      rateLimit: Disable,
      cache: true,
    },
    // Readable only because the config resolved this effect to a chain scope.
    async ({context}) => context.chain.id,
  )

  scenario->Scenario.it(
    "Caches an unscoped effect per chain",
    ~sources=[{chain: 1, methods}, {chain: 137, methods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)

      source1.resolveGetHeightOrThrow(300)
      source137.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      let callEffect = (~block): MockSource.itemMock => {
        blockNumber: block,
        logIndex: 0,
        handler: async args => {
          let context = args.context->asContext
          let chainId = await context.effect(unscoped, "same-input")
          context.counter.set({"id": "total", "count": chainId->BigInt.fromInt})
        },
      }

      source137.resolveGetItemsOrThrow([callEffect(~block=5)], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
      source1.resolveGetItemsOrThrow([callEffect(~block=6)], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      let cache1 = await indexer.queryEffectCache(unscoped, ~scope=Chain(1->ChainId.fromInt))
      let cache137 = await indexer.queryEffectCache(unscoped, ~scope=Chain(137->ChainId.fromInt))
      let counters: array<counter> = await indexer.query("Counter")

      await indexer.stop()

      // The same input resolved per chain instead of being served from one
      // shared cache entry.
      t.expect((
        cache1->Array.map(row => row["output"]),
        cache137->Array.map(row => row["output"]),
        counters->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
      )).toEqual((
        [%raw(`1`)],
        [%raw(`137`)],
        [{id: "total", count: 1n, chainId: 1}, {id: "total", count: 137n, chainId: 137}],
      ))
    },
  )
})

describe("Per-chain history prune", () => {
  // The prune keeps, per (id, chain), the latest history row at or below the
  // safe checkpoint — but only when that chain still has a row above it.
  // Grouping by id alone would take one chain's anchor as the other's and
  // delete the row a later rollback needs, which no assertion on the entity
  // tables would reveal. The checkpoints are seeded directly so the safe point
  // can sit between them.
  let entityConfig = pruneScenario.config->IndexerRunner.entityConfigByName("Counter")

  pruneScenario->Scenario.it(
    "Keeps each chain's own anchor",
    ~sources=[{chain: 1, methods}, {chain: 137, methods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)
      source1.resolveGetHeightOrThrow(300)
      source137.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)
      await indexer.stop()

      let globalEntityConfig =
        pruneScenario.config->IndexerRunner.entityConfigByName("GlobalCounter")
      let {sql, pgSchema} = indexer->IndexerRunner.pgOrThrow
      let historyTable = PgStorage.getEntityHistory(~entityConfig).table.tableName
      let globalHistoryTable = PgStorage.getEntityHistory(
        ~entityConfig=globalEntityConfig,
      ).table.tableName

      // Chain 137 straddles the safe checkpoint (10 below, 40 above), chain 1's
      // "shared" sits entirely below it and its "above" entirely above.
      let _ = await sql->Postgres.unsafe(
        `INSERT INTO "${pgSchema}"."${historyTable}"
           ("id", "count", "chainId", "envio_checkpoint_id", "envio_change")
         VALUES ('shared', 1, 137, 10, 'SET'),
                ('shared', 2, 137, 40, 'SET'),
                ('shared', 3, 1, 20, 'SET'),
                ('above', 4, 1, 50, 'SET')`,
      )
      // The same three shapes without a chain column, so the cross-chain form of
      // the query is exercised too.
      let _ = await sql->Postgres.unsafe(
        `INSERT INTO "${pgSchema}"."${globalHistoryTable}"
           ("id", "count", "envio_checkpoint_id", "envio_change")
         VALUES ('straddle', 1, 10, 'SET'),
                ('straddle', 2, 40, 'SET'),
                ('below', 3, 20, 'SET'),
                ('above', 4, 50, 'SET')`,
      )

      let prune = entityConfig =>
        EntityHistory.pruneStaleEntityHistory(
          sql,
          ~pgSchema,
          ~entityName=(entityConfig: Internal.entityConfig).name,
          ~entityIndex=entityConfig.index,
          ~chainIdColumn=entityConfig.table
          ->Table.getChainIdField
          ->Option.map(Table.getPgDbFieldName),
          ~safeCheckpointId=30n,
        )
      await prune(entityConfig)
      await prune(globalEntityConfig)

      let remaining: array<{
        "chainId": int,
        "envio_checkpoint_id": string,
      }> = await sql->Postgres.unsafe(
        `SELECT "chainId", "envio_checkpoint_id"::text FROM "${pgSchema}"."${historyTable}"
           ORDER BY "chainId", "envio_checkpoint_id"`,
      )
      let globalRemaining: array<{
        "id": string,
        "envio_checkpoint_id": string,
      }> = await sql->Postgres.unsafe(
        `SELECT "id", "envio_checkpoint_id"::text FROM "${pgSchema}"."${globalHistoryTable}"
           ORDER BY "id", "envio_checkpoint_id"`,
      )
      let _ = await sql->Postgres.unsafe(`DELETE FROM "${pgSchema}"."${historyTable}"`)
      let _ = await sql->Postgres.unsafe(`DELETE FROM "${pgSchema}"."${globalHistoryTable}"`)

      t.expect((
        remaining->Array.map(row => (row["chainId"], row["envio_checkpoint_id"])),
        globalRemaining->Array.map(row => (row["id"], row["envio_checkpoint_id"])),
      )).toEqual((
        [
          // Nothing of chain 1's "above" is stale yet, and chain 137 keeps its
          // anchor at 10 because it has a later row at 40.
          (1, "50"),
          (137, "10"),
          (137, "40"),
        ],
        [("above", "50"), ("straddle", "10"), ("straddle", "40")],
      ))
    },
  )
})
