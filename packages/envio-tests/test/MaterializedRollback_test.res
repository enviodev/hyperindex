open Vitest

// Materialized writes go through the handler context, so entity history
// snapshots the whole row per checkpoint. That is what makes a reorg take a
// write back with no rollback code of its own: a `_sum` column returns to the
// value it held at the rollback target, an overwritten column returns to what
// the previous event wrote, and a row whose only contribution is rolled back is
// deleted outright.
//
// The mock source dispatches through the payload rather than through
// registration, so the materializer's handler is fetched here — the same way
// `MaterializedWrites_test` does.
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

let scenario = Scenario.make(
  ~configYaml=`
name: materialized-rollback
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
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
`,
)

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"

let materializerHandler = (config: Config.t) =>
  switch Materialization.buildHandlers(config)->Array.find(({contractName, eventName}) =>
    contractName === "ERC20" && eventName === "Transfer"
  ) {
  | Some({handler}) => handler
  | None => JsError.throwWithMessage("No materialization handler was built for ERC20.Transfer")
  }

// The compiled plans read the event by path, so a mock item can hand the real
// materializer handler a plain event object with the params under test.
let transferItem = (~block, ~from, ~to, ~value, ~handler: Internal.handler): MockSource.itemMock => {
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
      context: args.context,
    })
  },
}

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let rowsOf = (indexer: IndexerRunner.t, config: Config.t, table) =>
  indexer.queryRaw(config.entitiesByTableName->Dict.getUnsafe(table))

// Answers whatever the reorg resolution asks for: block hashes for the depth
// search (blocks past `validUpTo` come back re-orged), and empty responses for
// the re-fetch queries the rollback schedules.
let driveRollback = async (~source: MockSource.t, ~validUpTo) => {
  for _ in 0 to 300 {
    if source.getBlockHashesCalls->Array.length > 0 {
      let requested = source.getBlockHashesCalls->Array.copy
      source.resolveGetBlockHashes(
        requested
        ->Array.flat
        ->Array.map((blockNumber): BlockStore.inputBlock => {
          blockNumber,
          blockHash: blockNumber <= validUpTo
            ? `0x${blockNumber->Int.toString}`
            : `0x${blockNumber->Int.toString}a`,
          blockTimestamp: blockNumber,
        }),
      )
      source.getBlockHashesCalls->Utils.Array.clearInPlace
    }
    if source.getItemsOrThrowCalls->Array.length > 0 {
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=301)
    }
    await Utils.delay(0)
  }
}

describe("Materialized reducer rollback", () => {
  scenario->Scenario.it(
    "restores the balance a reorged contribution had added",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let config = scenario.config
      let handler = materializerHandler(config)
      let source = source(1)

      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Stops short of the head, so the next range is inside the threshold.
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.getBatchWritePromise()

      // Block 200 moves 5 from alice to bob and survives the reorg; block 300
      // moves 2 more and is the change it takes back.
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          transferItem(~block=200, ~from=alice, ~to=bob, ~value=5n, ~handler),
          transferItem(~block=300, ~from=alice, ~to=bob, ~value=2n, ~handler),
        ],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()

      let before: array<account> = await rowsOf(indexer, config, "accounts")
      t.expect(
        before->Array.toSorted((a, b) => String.compare(a.id, b.id)),
        ~message="both contributions are committed before the reorg",
      ).toEqual([
        {id: alice, balance: -7n, chainId: 1},
        {id: bob, balance: 7n, chainId: 1},
      ])

      source.resolveGetHeightOrThrow(301)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=301,
        ~prevRangeLastBlock={blockNumber: 300, blockHash: "0x300a"},
      )

      // Only blocks up to 200 still hold, so block 300's contribution is undone
      // and the sum goes back to what block 200 left.
      await driveRollback(~source, ~validUpTo=200)
      await indexer.waitUntilIdle()

      let accounts: array<account> = await rowsOf(indexer, config, "accounts")
      let seen: array<lastSeen> = await rowsOf(indexer, config, "last_seen")

      t.expect({
        "accounts": accounts->Array.toSorted((a, b) => String.compare(a.id, b.id)),
        "lastSeen": seen,
      }).toEqual({
        "accounts": [
          {id: alice, balance: -5n, chainId: 1},
          {id: bob, balance: 5n, chainId: 1},
        ],
        // The overwritten column goes back to what block 200 wrote, not to null.
        "lastSeen": [{id: bob, block: 200, chainId: 1}],
      })
    },
  )
})
