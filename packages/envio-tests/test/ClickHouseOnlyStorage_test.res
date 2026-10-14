open Vitest

// ClickHouse as the only storage: no Postgres anywhere, so every read a handler
// makes, every resume and every rollback has to be answered from ClickHouse.
// A case about what a handler reads restarts the indexer first, so what it sees
// comes from storage rather than from what the previous run held in memory.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-only
rollback_on_reorg: true
raw_events: true
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
  deleteUnsafe: string => unit,
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

      // What the handler read back, and its update landing on top of it.
      t.expect((seen.contents, (await resumed.query("Account"))->byId)).toEqual((
        Some((
          Some({id: "a", owner: "alice", balance: 10n}),
          [{id: "b", owner: "bob", balance: 5n}],
        )),
        [{id: "a", owner: "alice", balance: 11n}, {id: "b", owner: "bob", balance: 5n}],
      ))
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
      let rolledBack = (await indexer.query("Account"))->byId
      let resumed = await indexer.restart()

      // The pre-fork state, and the same state read back after a restart.
      t.expect((rolledBack, (await resumed.query("Account"))->byId)).toEqual((
        [{id: "a", owner: "alice", balance: 1n}],
        [{id: "a", owner: "alice", balance: 1n}],
      ))
    },
  )

  scenario->Scenario.it(
    "forgets what a later batch deleted or changed",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(20)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          setAccounts(
            ~block=5,
            [{id: "a", owner: "alice", balance: 10n}, {id: "b", owner: "bob", balance: 5n}],
          ),
        ],
        ~latestFetchedBlockNumber=5,
      )
      await indexer.getBatchWritePromise()
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 8,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.account.deleteUnsafe("b")
              context.account.set({id: "a", owner: "carol", balance: 10n})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()
      let resumed = await indexer.restart()

      let seen = ref(None)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 15,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              let b = await context.account.get("b")
              let alices = await context.account.getWhere({"owner": {"_eq": "alice"}})
              let carols = await context.account.getWhere({"owner": {"_eq": "carol"}})
              if !context.isPreload {
                seen := Some((b, alices, carols))
              }
            },
          },
        ],
        ~latestFetchedBlockNumber=20,
      )
      await resumed.getBatchWritePromise()

      t.expect(seen.contents).toEqual(Some((None, [], [{id: "a", owner: "carol", balance: 10n}])))
    },
  )

  scenario->Scenario.it(
    "keeps one raw event per processed log",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          setAccounts(~block=5, [{id: "a", owner: "alice", balance: 1n}]),
          {...setAccounts(~block=6, [{id: "b", owner: "bob", balance: 2n}]), logIndex: 3},
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      let rows = await TestClickHouse.query(
        `SELECT block_number, log_index FROM \`${TestClickHouse.currentDatabase()}\`.\`raw_events\` ORDER BY block_number FORMAT TabSeparated`,
      )
      t.expect(rows->String.trim).toBe("5\t0\n6\t3")
    },
  )
})

type effectContext = {
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
}

let lookupCalls = ref(0)

// An input a file of tab-separated lines has to escape, for the reset's dump.
let lookupInput = "tab\there, line\nbreak, back\\slash"

let lookup = Envio.createEffect(
  {
    name: "clickHouseOnlyLookup",
    input: S.string,
    output: S.json(~validate=false),
    rateLimit: Disable,
    cache: true,
  },
  async ({input}) => {
    lookupCalls := lookupCalls.contents + 1
    JSON.Encode.object(dict{"echo": JSON.Encode.string(input)})
  },
)

let callLookup = (~block): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => effectContext)
    let _ = await context.effect(lookup, lookupInput)
  },
}

// An output its schema has to serialize before it is a document: a bigint is
// no JSON value until it is its digits.
let balance = Envio.createEffect(
  {
    name: "clickHouseOnlyBalance",
    input: S.string,
    output: S.bigint,
    rateLimit: Disable,
    cache: true,
  },
  async _ => 123n,
)

describe("ClickHouse as the only storage of the effect cache", () => {
  scenario->Scenario.it(
    "stores an output as its schema serializes it",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => effectContext)
              let _ = await context.effect(balance, "a")
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      let stored = await TestClickHouse.query(
        `SELECT output FROM \`${TestClickHouse.currentDatabase()}\`.\`envio_effect_clickHouseOnlyBalance\` FINAL FORMAT TabSeparated`,
      )
      t.expect(stored->String.trim).toBe(`"123"`)
    },
  )

  scenario->Scenario.it(
    "answers a cached effect after a restart",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      lookupCalls := 0
      let source = source(1)
      source.resolveGetHeightOrThrow(10)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([callLookup(~block=5)], ~latestFetchedBlockNumber=10)
      await indexer.getBatchWritePromise()
      let resumed = await indexer.restart()

      source.resolveGetHeightOrThrow(20)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([callLookup(~block=15)], ~latestFetchedBlockNumber=20)
      await resumed.getBatchWritePromise()

      t.expect(lookupCalls.contents).toBe(1)
    },
  )

  scenario->Scenario.it("keeps the cache through a reset", ~sources=[{chain: 1, methods}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    lookupCalls := 0
    let source = source(1)
    source.resolveGetHeightOrThrow(10)
    await MockSource.waitItemsQuery(source)
    source.resolveGetItemsOrThrow([callLookup(~block=5)], ~latestFetchedBlockNumber=10)
    await indexer.getBatchWritePromise()

    await indexer.dumpEffectCache()
    source.setAutoHeight(10)
    let restarted = await indexer.restart(~reset=true, ())
    source.resolveGetItemsOrThrow(
      [callLookup(~block=5)],
      ~filter=MockSource.coveringBlock(5),
      ~latestFetchedBlockNumber=10,
    )
    await restarted.getBatchWritePromise()

    t.expect(lookupCalls.contents).toBe(1)
  })
})

let factoryScenario = Scenario.make(
  ~configYaml=`
name: clickhouse-only-factory
storage:
  postgres: false
  clickhouse: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
      - name: NftFactory
        address: "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c4"
        events:
          - event: "SimpleNftCreated(string name, string symbol, uint256 maxSupply, address contractAddress)"
`,
  ~schema=`
type Gravatar {
  id: ID!
}
`,
  // A registered address only gets a partition of its own when some
  // registration depends on its contract.
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async () => {});
`,
)

type contractOps = {add: Address.t => unit}
type registerContext = {chain: {"Gravatar": contractOps}}

let registered = "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow

describe("ClickHouse as the only storage of dynamic contracts", () => {
  factoryScenario->Scenario.it(
    "fetches a contract registered before a restart",
    ~sources=[{chain: 1, methods}],
    async (~t as _, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(1000)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 10,
            logIndex: 0,
            handler: async _ => (),
            contractRegister: async args =>
              (
                args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
              ).chain["Gravatar"].add(registered),
          },
        ],
        ~latestFetchedBlockNumber=200,
      )
      await indexer.getBatchWritePromise()
      source.drainItemsQueries(~latestFetchedBlockNumber=200)
      await indexer.getBatchWritePromise()

      source.setAutoHeight(1000)
      let _ = await indexer.restart()
      await Scenario.waitUntil(
        () =>
          source.getItemsOrThrowCalls->Array.some(
            call => call.payload->MockSource.CallPayload.addresses->Array.includes(registered),
          ),
        ~message="a query carrying the address registered before the restart",
      )
    },
  )
})

// Two chains writing one id are two entities, told apart by the chain column
// ClickHouse names in its own format.
let perChainScenario = Scenario.make(
  ~configYaml=`
name: clickhouse-only-per-chain
disable_default_cross_chain: true
storage:
  postgres: false
  clickhouse:
    column_name_format: snake_case
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 137
    rpc:
      url: https://rpc137.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000002"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

type counter = {id: string, count: bigint}
type storedCounter = {id: string, count: bigint, chainId: int}
type counterOps = {get: string => promise<option<counter>>, set: counter => unit}
type counterContext = {@as("Counter") counter: counterOps}

let bumpCounter = (~block, ~start): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
    let count = switch await context.counter.get("total") {
    | Some({count}) => count + 1n
    | None => start
    }
    context.counter.set({id: "total", count})
  },
}

describe("ClickHouse as the only storage of per-chain entities", () => {
  perChainScenario->Scenario.it(
    "reads each chain's own entity back after a restart",
    ~sources=[{chain: 1, methods}, {chain: 137, methods}],
    async (~t, ~indexer, ~source) => {
      let (chain1, chain137) = (source(1), source(137))
      chain1.resolveGetHeightOrThrow(10)
      chain137.resolveGetHeightOrThrow(10)
      await MockSource.waitItemsQuery(chain1)
      chain1.resolveGetItemsOrThrow(
        [bumpCounter(~block=5, ~start=42n)],
        ~latestFetchedBlockNumber=10,
      )
      await MockSource.waitItemsQuery(chain137)
      chain137.resolveGetItemsOrThrow(
        [bumpCounter(~block=5, ~start=7n)],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.waitUntilIdle()
      let resumed = await indexer.restart()

      chain1.resolveGetHeightOrThrow(20)
      chain137.resolveGetHeightOrThrow(20)
      await MockSource.waitItemsQuery(chain1)
      chain1.resolveGetItemsOrThrow(
        [bumpCounter(~block=15, ~start=0n)],
        ~latestFetchedBlockNumber=20,
      )
      await MockSource.waitItemsQuery(chain137)
      chain137.resolveGetItemsOrThrow(
        [bumpCounter(~block=15, ~start=0n)],
        ~latestFetchedBlockNumber=20,
      )
      await resumed.waitUntilIdle()

      t.expect(
        (await (resumed.query("Counter"): promise<array<storedCounter>>))->Array.toSorted(
          (a, b) => Int.compare(a.chainId, b.chainId),
        ),
      ).toEqual([{id: "total", count: 43n, chainId: 1}, {id: "total", count: 8n, chainId: 137}])
    },
  )
})
