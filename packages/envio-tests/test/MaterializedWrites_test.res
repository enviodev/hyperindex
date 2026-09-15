open Vitest

// What a table's compiled plan writes, read back out of storage. A table isn't
// an entity, so nothing addresses it from user code and the rows come back
// through the run's own `queryRaw` keyed by the table's config.
//
// The mock source installs one synthetic registration and dispatches through
// the payload, so the materializer's handler is fetched here rather than
// reached through registration — which is why `MaterializedOrdering_test`
// still covers the registration side with `simulate`.
type account = {
  id: string,
  balance: bigint,
  @as("chainId") chainId: int,
}
type receipt = {
  id: string,
  kind: string,
  @as("chainId") chainId: int,
}

let scenario = Scenario.make(
  ~configYaml=`
name: materialized-writes
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: ERC20
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
tables:
  accounts:
    with:
      balance_changes:
        - from: evm.events
          where:
            eventName: Transfer
          select:
            account: params.from
            delta:
              _negate: params.value
        - from: evm.events
          where:
            eventName: Transfer
          select:
            account: params.to
            delta: params.value
    from: balance_changes
    select:
      id: account
      balance:
        _sum: delta
  # Only transfers the configured sender makes, keyed by a joined id. The
  # literal is written lowercase while the decoder checksums, so a row only
  # appears if the compiler normalized it.
  receipts:
    from: evm.events
    where:
      eventName: Transfer
      params:
        from: "0x1111111111111111111111111111111111111111"
    select:
      id:
        _concat:
          separator: "-"
          values:
            - params.to
            - params.value
      kind:
        _literal: sent
`,
)

let alice = "0x1111111111111111111111111111111111111111"
let bob = "0x2222222222222222222222222222222222222222"

let materializerHandler = (config: Config.t) =>
  switch Materialization.buildHandlers(config)->Array.find(({eventName}) =>
    eventName === "Transfer"
  ) {
  | Some({handler}) => handler
  | None => JsError.throwWithMessage("No materialization handler was built for ERC20.Transfer")
  }

let transferItem = (~block, ~from, ~to, ~value, ~handler: Internal.handler): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: args => {
    let event = {
      "contractName": "ERC20",
      "eventName": "Transfer",
      "chainId": 1337,
      "params": {"from": from, "to": to, "value": value},
      "block": {"number": block},
    }->(Utils.magic: {..} => Internal.event)
    handler({
      event,
      context: args.context,
    })
  },
}

let rowsOf = (indexer: IndexerRunner.t, config: Config.t, table) =>
  indexer.queryRaw(config.entitiesByTableName->Dict.getUnsafe(table))

describe("Materialized writes", () => {
  scenario->Scenario.it(
    "sums both sides of a transfer and keeps only the rows its `where` admits",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let config = scenario.config
      let handler = materializerHandler(config)
      let sourceMock = source(1337)
      await Utils.delay(0)
      sourceMock.resolveGetHeightOrThrow(1000)
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock.resolveGetItemsOrThrow(
        [
          transferItem(~block=1, ~from=alice, ~to=bob, ~value=5n, ~handler),
          // Alice sends to herself: the debit and the credit cancel, which
          // only holds because a `_sum` reads its own write back.
          transferItem(~block=2, ~from=alice, ~to=alice, ~value=9n, ~handler),
          // Not from the address the `where` names, so `receipts` skips it.
          transferItem(~block=3, ~from=bob, ~to=alice, ~value=2n, ~handler),
        ],
        ~latestFetchedBlockNumber=3,
        ~resolveAt=#first,
      )
      await indexer.getBatchWritePromise()

      let accounts: array<account> = await rowsOf(indexer, config, "accounts")
      let receipts: array<receipt> = await rowsOf(indexer, config, "receipts")

      t.expect({
        "accounts": accounts->Array.toSorted((a, b) => String.compare(a.id, b.id)),
        "receipts": receipts,
      }).toEqual({
        "accounts": [
          {id: alice, balance: -3n, chainId: 1337},
          {id: bob, balance: 3n, chainId: 1337},
        ],
        "receipts": [
          {id: `${bob}-5`, kind: "sent", chainId: 1337},
          {id: `${alice}-9`, kind: "sent", chainId: 1337},
        ],
      })
    },
  )
})

// A second config: the filters whose failure mode is an empty table rather than
// a wrong number — an address literal in the other casing, and a comparison
// against a value that isn't there.
type row = {
  id: string,
  @as("chainId") chainId: int,
}

let filters = Scenario.make(
  ~configYaml=`
name: materialized-filters
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: ERC20
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
tables:
  # Written lowercase; the decoder checksums. A row only appears if the
  # compiler normalized the literal to the casing the event carries.
  from_uni:
    from: evm.events
    where:
      eventName: Transfer
      params:
        from: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
    select:
      id: params.to
  # A transaction with no recipient is a contract creation.
  creations:
    from: evm.events
    where:
      eventName: Transfer
      transaction:
        to:
          _eq: null
    select:
      id: params.to
  calls:
    from: evm.events
    where:
      eventName: Transfer
      transaction:
        to:
          _neq: null
    select:
      id: params.to
`,
)

let checksummed = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

let filterItem = (~block, ~from, ~to, ~txTo, ~handler: Internal.handler): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: args => {
    let event = {
      "contractName": "ERC20",
      "eventName": "Transfer",
      "chainId": 1337,
      "params": {"from": from, "to": to, "value": 1n},
      "block": {"number": block},
      "transaction": {"to": txTo},
    }->(Utils.magic: {..} => Internal.event)
    handler({
      event,
      context: args.context,
    })
  },
}

describe("Materialized filters", () => {
  filters->Scenario.it(
    "matches an address literal in the other casing, and a value that isn't there",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let config = filters.config
      let handler = materializerHandler(config)
      let sourceMock = source(1337)
      await Utils.delay(0)
      sourceMock.resolveGetHeightOrThrow(1000)
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock.resolveGetItemsOrThrow(
        [
          filterItem(~block=1, ~from=checksummed, ~to=alice, ~txTo=None, ~handler),
          filterItem(~block=2, ~from=bob, ~to=bob, ~txTo=Some(bob), ~handler),
        ],
        ~latestFetchedBlockNumber=2,
        ~resolveAt=#first,
      )
      await indexer.getBatchWritePromise()

      let fromUni: array<row> = await rowsOf(indexer, config, "from_uni")
      let creations: array<row> = await rowsOf(indexer, config, "creations")
      let calls: array<row> = await rowsOf(indexer, config, "calls")

      t.expect({
        "fromUni": fromUni,
        "creations": creations,
        "calls": calls,
      }).toEqual({
        "fromUni": [{id: alice, chainId: 1337}],
        "creations": [{id: alice, chainId: 1337}],
        "calls": [{id: bob, chainId: 1337}],
      })
    },
  )
})
