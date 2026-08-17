open Vitest

// Materialized writes go through the handler context, so entity history
// snapshots the whole row per checkpoint. That is what makes a reorg take a
// write back with no rollback code of its own: a `_sum` column returns to the
// value it held at the rollback target, an overwritten column returns to what
// the previous event wrote, and a row whose only contribution is rolled back is
// deleted outright.
//
// This is the rung that needs the real loop. Everything about materialization
// that doesn't — several tables per event, per-chain keying, `cross_chain` —
// is covered by `simulate` in `packages/envio-tests`.
type account = {
  id: string,
  balance: bigint,
  @as("chainId") chainId: int,
}
type lastSeen = {
  id: string,
  block: int,
  @as("chainId") chainId: int,
}

let configYaml = `
name: materialized-rollback
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: ERC20
        address: "0x0000000000000000000000000000000000000001"
tables:
  accounts:
    with:
      balance_changes:
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Transfer
          select:
            account: params.from
            delta:
              _negate: params.value
        - from: evm.events
          where:
            contractName: ERC20
            eventName: Transfer
          select:
            account: params.to
            delta: params.value
    from: balance_changes
    select:
      id: account
      balance:
        _sum: delta
  last_seen:
    from: evm.events
    where:
      eventName: Transfer
    select:
      id: params.to
      block: block.number
`

// The compiled plans read the event by path, so a mock item can hand the real
// materializer handler a plain event object with the params under test.
let makeTransferItem = (
  ~block,
  ~from,
  ~to,
  ~value,
  ~handler: Internal.handler,
): MockIndexer.Source.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: args => {
    let event = {
      "contractName": "ERC20",
      "eventName": "Transfer",
      "chainId": 1,
      "params": {"from": from, "to": to, "value": value},
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

describe("Materialized reducer rollback", () => {
  Async.it("Restores the balance a reorged contribution had added", async t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml)
    let handler = materializerHandler(config)
    let alice = "0x1111111111111111111111111111111111111111"
    let bob = "0x2222222222222222222222222222222222222222"

    let source = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1,
    )
    await MockIndexer.Indexer.run(
      ~config,
      ~chains=[
        {chain: #1, sourceConfig: Config.CustomSources([source.source]), maxReorgDepth: 200},
      ],
      async indexerMock => {
        await Utils.delay(0)
        await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=source)

        // Block 101 moves 5 from alice to bob and is never reorged.
        source.resolveGetItemsOrThrow(
          [makeTransferItem(~block=101, ~from=alice, ~to=bob, ~value=5n, ~handler)],
          ~latestFetchedBlockNumber=101,
          ~latestFetchedBlockHash="0x0101",
        )
        await indexerMock.getBatchWritePromise()

        // Block 102 moves 2 more, and is the change the reorg takes back.
        source.resolveGetItemsOrThrow(
          [makeTransferItem(~block=102, ~from=alice, ~to=bob, ~value=2n, ~handler)],
          ~latestFetchedBlockNumber=102,
          ~latestFetchedBlockHash="0x0102",
        )
        await indexerMock.getBatchWritePromise()

        // Block 102 comes back with a different hash.
        source.resolveGetItemsOrThrow(
          [],
          ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x0102aa"},
        )
        await Utils.delay(0)
        await Utils.delay(0)
        // Both blocks the depth search asks for come back unchanged, so the
        // rollback target is 101 and only block 102's write is undone.
        source.resolveGetBlockHashes([
          {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
          {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
        ])
        await indexerMock.getRollbackReadyPromise()

        // The rollback diff is written with the next batch, so drive one more.
        source.resolveGetItemsOrThrow(
          [],
          ~latestFetchedBlockNumber=102,
          ~latestFetchedBlockHash="0x0102",
        )
        await indexerMock.getBatchWritePromise()
        await indexerMock.waitUntilIdle()

        let accounts: array<account> = await indexerMock.queryRaw(
          config.entitiesByTableName->Dict.getUnsafe("accounts"),
        )
        let seen: array<lastSeen> = await indexerMock.queryRaw(
          config.entitiesByTableName->Dict.getUnsafe("last_seen"),
        )

        t.expect((accounts->Array.toSorted((a, b) => String.compare(a.id, b.id)), seen)).toEqual((
          [{id: alice, balance: -5n, chainId: 1}, {id: bob, balance: 5n, chainId: 1}],
          // The overwritten column goes back to what block 101 wrote, not to null.
          [{id: bob, block: 101, chainId: 1}],
        ))
      },
    )
  })

  Async.it("Deletes a row whose only contribution is reorged away", async t => {
    let {config} = InternalTestIndexer.fromUserApi(~configYaml)
    let handler = materializerHandler(config)
    let alice = "0x1111111111111111111111111111111111111111"
    let carol = "0x3333333333333333333333333333333333333333"

    let source = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1,
    )
    await MockIndexer.Indexer.run(
      ~config,
      ~chains=[
        {chain: #1, sourceConfig: Config.CustomSources([source.source]), maxReorgDepth: 200},
      ],
      async indexerMock => {
        await Utils.delay(0)
        await MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=source)

        source.resolveGetItemsOrThrow(
          [makeTransferItem(~block=102, ~from=alice, ~to=carol, ~value=9n, ~handler)],
          ~latestFetchedBlockNumber=102,
          ~latestFetchedBlockHash="0x0102",
        )
        await indexerMock.getBatchWritePromise()

        source.resolveGetItemsOrThrow(
          [],
          ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x0102aa"},
        )
        await Utils.delay(0)
        await Utils.delay(0)
        source.resolveGetBlockHashes([
          {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
          {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
        ])
        await indexerMock.getRollbackReadyPromise()

        source.resolveGetItemsOrThrow(
          [],
          ~latestFetchedBlockNumber=102,
          ~latestFetchedBlockHash="0x0102",
        )
        await indexerMock.getBatchWritePromise()
        await indexerMock.waitUntilIdle()

        let accounts: array<account> = await indexerMock.queryRaw(
          config.entitiesByTableName->Dict.getUnsafe("accounts"),
        )
        let seen: array<lastSeen> = await indexerMock.queryRaw(
          config.entitiesByTableName->Dict.getUnsafe("last_seen"),
        )

        t.expect((accounts, seen)).toEqual(([], []))
      },
    )
  })
})
