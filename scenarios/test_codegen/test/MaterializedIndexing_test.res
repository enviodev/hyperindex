open Vitest

// Materialized writes against a real Postgres, driven through the real indexer
// loop. What that rung buys over the test indexer: the rows are read back out
// of the database, per-chain keying is the database's own primary key, and a
// reorg goes through entity history rather than an in-memory diff.
type total = {
  id: string,
  amount: bigint,
  @as("chainId") chainId: int,
}
type sharedTotal = {
  id: string,
  amount: bigint,
}
type lastSeen = {
  id: string,
  block: int,
  @as("chainId") chainId: int,
}

let chainsYaml = chainIds =>
  chainIds
  ->Array.map(id => `  - id: ${id}
    start_block: 1
    contracts:
      - name: ERC20
        address: "0x0000000000000000000000000000000000000001"`)
  ->Array.joinUnsafe("\n")

let configYaml = (~chainIds=["1"], tables) => `
name: materialized-indexing
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
${chainIds->chainsYaml}
tables:
${tables}`

// The compiled plans read the event by path, so a mock item hands the real
// materializer handler a plain event object with the params under test.
let transfer = (~block, ~to, ~value, ~handler: Internal.handler): MockIndexer.Source.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: args => {
    let event =
      {
        "contractName": "ERC20",
        "eventName": "Transfer",
        "chainId": 1,
        "params": {"from": "0x0000000000000000000000000000000000000009", "to": to, "value": value},
        "block": {"number": block},
      }->(Utils.magic: {..} => Internal.event)
    handler({
      event,
      context: args.context->(Utils.magic: MockIndexer.handlerContext => Internal.handlerContext),
    })
  },
}

let materializerHandler = (config: Config.t) =>
  switch Materialization.buildHandlers(config)->Array.find(({contractName, eventName}) =>
    contractName === "ERC20" && eventName === "Transfer"
  ) {
  | Some({handler}) => handler
  | None => JsError.throwWithMessage("No materialization handler was built for ERC20.Transfer")
  }

let rowsOf = (indexerMock: MockIndexer.Indexer.t, config: Config.t, table) =>
  indexerMock.queryRaw(config.entitiesByTableName->Dict.getUnsafe(table))

// One event feeds every table whose `where` admits it. The plans run in config
// order on one handler, so both rows have to land from a single event.
describe("Two tables written by one event", () => {
  Async.it("Writes both, from one event", async t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml(`  totals:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
      amount:
        _sum: params.value
  last_seen:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
      block: block.number`),
    )
    let handler = materializerHandler(config)
    let alice = "0x1111111111111111111111111111111111111111"

    let source = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chainId=#1)
    let indexerMock = await MockIndexer.Indexer.make(
      ~config,
      ~chains=[{chain: #1, sourceConfig: Config.CustomSources([source.source])}],
      ~shouldRollbackOnReorg=false,
    )
    await Utils.delay(0)
    source.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    source.resolveGetItemsOrThrow(
      [
        transfer(~block=10, ~to=alice, ~value=4n, ~handler),
        transfer(~block=11, ~to=alice, ~value=6n, ~handler),
      ],
      ~latestFetchedBlockNumber=300,
    )
    await indexerMock.getBatchWritePromise()
    await indexerMock.waitUntilIdle()

    let totals: array<total> = await rowsOf(indexerMock, config, "totals")
    let seen: array<lastSeen> = await rowsOf(indexerMock, config, "last_seen")
    await indexerMock.stop()

    t.expect((totals, seen)).toEqual((
      // Accumulated across both events, and the plain column holds the later one.
      [{id: alice, amount: 10n, chainId: 1}],
      [{id: alice, block: 11, chainId: 1}],
    ))
  })
})

// The reason `tables` demands `disable_default_cross_chain`: without per-chain
// rows, two chains' balances for one address land on one row.
describe("Materialized tables across chains", () => {
  Async.it("Keys a table per chain, and shares one row with cross_chain", async t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml(
        ~chainIds=["1", "137"],
        `  totals:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
      amount:
        _sum: params.value
  shared_totals:
    cross_chain: true
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
      amount:
        _sum: params.value`,
      ),
    )
    let handler = materializerHandler(config)
    let alice = "0x1111111111111111111111111111111111111111"

    let source1 = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chainId=#1)
    let source137 = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chainId=#137)
    let indexerMock = await MockIndexer.Indexer.make(
      ~config,
      ~chains=[
        {chain: #1, sourceConfig: Config.CustomSources([source1.source])},
        {chain: #137, sourceConfig: Config.CustomSources([source137.source])},
      ],
      ~shouldRollbackOnReorg=false,
    )
    await Utils.delay(0)
    source1.resolveGetHeightOrThrow(300)
    source137.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    source1.resolveGetItemsOrThrow(
      [transfer(~block=10, ~to=alice, ~value=3n, ~handler)],
      ~latestFetchedBlockNumber=300,
    )
    source137.resolveGetItemsOrThrow(
      [transfer(~block=10, ~to=alice, ~value=40n, ~handler)],
      ~latestFetchedBlockNumber=300,
    )
    await indexerMock.getBatchWritePromise()
    await indexerMock.waitUntilIdle()

    let totals: array<total> = await rowsOf(indexerMock, config, "totals")
    let shared: array<sharedTotal> = await rowsOf(indexerMock, config, "shared_totals")
    await indexerMock.stop()

    t.expect((
      totals->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
      shared,
    )).toEqual((
      [{id: alice, amount: 3n, chainId: 1}, {id: alice, amount: 40n, chainId: 137}],
      // One row, so both chains' contributions add up in it.
      [{id: alice, amount: 43n}],
    ))
  })
})

// A `_sum` rolls back by restoring the row; a plain column has no arithmetic to
// undo, so what has to be restored is the value the previous event wrote.
describe("Rollback of an overwritten column", () => {
  Async.it("Restores the value the reorged event replaced", async t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml(`  last_seen:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
      block: block.number`),
    )
    let handler = materializerHandler(config)
    let alice = "0x1111111111111111111111111111111111111111"

    let source = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~config,
      ~chains=[{chain: #1, sourceConfig: Config.CustomSources([source.source]), maxReorgDepth: 200}],
    )
    await Utils.delay(0)
    await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=source)

    source.resolveGetItemsOrThrow(
      [transfer(~block=101, ~to=alice, ~value=1n, ~handler)],
      ~latestFetchedBlockNumber=101,
      ~latestFetchedBlockHash="0x101",
    )
    await indexerMock.getBatchWritePromise()

    source.resolveGetItemsOrThrow(
      [transfer(~block=102, ~to=alice, ~value=1n, ~handler)],
      ~latestFetchedBlockNumber=102,
      ~latestFetchedBlockHash="0x102",
    )
    await indexerMock.getBatchWritePromise()

    source.resolveGetItemsOrThrow(
      [],
      ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102-reorged"},
    )
    await Utils.delay(0)
    await Utils.delay(0)
    source.resolveGetBlockHashes([{blockNumber: 101, blockHash: "0x101", blockTimestamp: 101}])
    await indexerMock.getRollbackReadyPromise()

    source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102, ~latestFetchedBlockHash="0x102")
    await indexerMock.getBatchWritePromise()
    await indexerMock.waitUntilIdle()

    let seen: array<lastSeen> = await rowsOf(indexerMock, config, "last_seen")
    await indexerMock.stop()

    t.expect(seen).toEqual([{id: alice, block: 101, chainId: 1}])
  })
})
