open Vitest

// ClickHouse as the only storage: no Postgres anywhere, so every read a handler
// makes, every resume and every rollback has to be answered from ClickHouse.
// Each case restarts the indexer before it reads, so what a handler sees comes
// from storage rather than from what the previous run still held in memory.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-only
rollback_on_reorg: true
storage:
  postgres: false
  clickhouse: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Account {
  id: ID!
  owner: String! @index
  balance: BigInt!
}
`,
)

type account = {id: string, owner: string, balance: bigint}
type accountOps = {
  get: string => promise<option<account>>,
  getWhere: {"owner": {"_eq": string}} => promise<array<account>>,
  set: account => unit,
}
type context = {isPreload: bool, @as("Account") account: accountOps}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => context)

let setAccounts = (~block, accounts): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->asContext
    accounts->Array.forEach(context.account.set)
  },
}

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let byId = (accounts: array<account>) =>
  accounts->Array.toSorted((a, b) => String.compare(a.id, b.id))

describe("ClickHouse as the only storage", () => {
  scenario->Scenario.it(
    "answers a handler's get and getWhere after a restart",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          setAccounts(
            ~block=5,
            [{id: "a", owner: "alice", balance: 10n}, {id: "b", owner: "bob", balance: 5n}],
          ),
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      let resumed = await indexer.restart()

      let seen = ref(None)
      source.resolveGetHeightOrThrow(20)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 15,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              let a = await context.account.get("a")
              let bobs = await context.account.getWhere({"owner": {"_eq": "bob"}})
              if !context.isPreload {
                seen := Some((a, bobs))
              }
              switch a {
              | Some(a) => context.account.set({...a, balance: a.balance + 1n})
              | None => ()
              }
            },
          },
        ],
        ~latestFetchedBlockNumber=20,
      )
      await resumed.getBatchWritePromise()

      t.expect(
        seen.contents,
        ~message="the handler read both accounts back from ClickHouse",
      ).toEqual(
        Some((
          Some({id: "a", owner: "alice", balance: 10n}),
          [{id: "b", owner: "bob", balance: 5n}],
        )),
      )
      t.expect(
        (await resumed.query("Account"))->byId,
        ~message="the handler's update landed on top of what it read",
      ).toEqual([{id: "a", owner: "alice", balance: 11n}, {id: "b", owner: "bob", balance: 5n}])
    },
  )

  scenario->Scenario.it(
    "rolls a reorg back and resumes from what survived it",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [setAccounts(~block=50, [{id: "a", owner: "alice", balance: 1n}])],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          setAccounts(
            ~block=200,
            [{id: "a", owner: "alice", balance: 2n}, {id: "c", owner: "carol", balance: 3n}],
          ),
        ],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()

      // Block 300 comes back with a different hash and only blocks up to 100
      // still hold, so the block-200 writes are rolled back: `a` to what block 50
      // wrote, and `c`, which didn't exist then, away.
      await Scenario.reorgAbove(~indexer, ~source, ~head=300, ~validUpTo=100)

      t.expect(
        (await indexer.query("Account"))->byId,
        ~message="the rollback restored the pre-fork state",
      ).toEqual([{id: "a", owner: "alice", balance: 1n}])

      let resumed = await indexer.restart()
      t.expect(
        (await resumed.query("Account"))->byId,
        ~message="a restart after the rollback reads the same state back",
      ).toEqual([{id: "a", owner: "alice", balance: 1n}])
    },
  )
})
