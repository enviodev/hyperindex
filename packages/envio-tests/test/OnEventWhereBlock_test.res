open Vitest

// `indexer.onEvent` `where.block.number._gte`, from a user's config.yaml and
// handler source to where each source starts fetching and the rows the indexer
// writes. Chains 1 and 2 fetch over HyperSync and chains 3 and 4 over RPC, all
// from the same served logs; a per-chain callback tells chains 1 and 3 from 2
// and 4.

let ledger = "0x1111111111111111111111111111111111111111"
// Its config.yaml start_block is above the `where` one.
let late = "0x2222222222222222222222222222222222222222"
// Its config.yaml start_block is below the `where` one.
let soon = "0x3333333333333333333333333333333333333333"
let zero = "0x0000000000000000000000000000000000000000"
let outsider = "0x000000000000000000000000000000000000dEaD"

type event = {name: string, sighash: string, address: string}

let static = {
  name: "Static",
  sighash: "0xcf6d5253269e13032ad5e3cc518913c37ed71f3d5d2b8334e176c2ea0a96af52",
  address: ledger,
}
let perChain = {
  name: "PerChain",
  sighash: "0x9dff82e5101127e74c9e48cec1c76c0d18e1b2af135b069d30c2f1a16131a48a",
  address: ledger,
}
let open_ = {
  name: "Open",
  sighash: "0xece7583a70a505ef0e36d4dec768f5ae597713e09c26011022599ee01abdabfc",
  address: ledger,
}
let always = {
  name: "Always",
  sighash: "0xd8062f9b8d90ae36b59249acf691b04dd2967ab16c5dfb881bd2f6aba14b02ff",
  address: ledger,
}
let early = {
  name: "Early",
  sighash: "0xd91467e777ae3b608b5096ea5d6b7e69078a182cc787b0fcd44df70c4ebc60c2",
  address: late,
}
let lifted = {
  name: "Lifted",
  sighash: "0x0293e04328bfa0d1c198a6a93bbf46f21a382540b8a4f33aefbef702d1aaccee",
  address: soon,
}

let log = (event, ~blockNumber, ~from=zero): ServedEvmChain.log => {
  blockNumber,
  logIndex: 0,
  address: event.address,
  topics: [event.sighash, from->ServedEvmChain.addressTopic],
}

let served = ServedEvmChain.serveDuringSuite(
  ~hyperSyncPort=18615,
  ~rpcPort=18616,
  ~height=40,
  ~logs=[
    static->log(~blockNumber=5),
    static->log(~blockNumber=10),
    static->log(~blockNumber=12),
    static->log(~blockNumber=13, ~from=outsider),
    perChain->log(~blockNumber=19),
    perChain->log(~blockNumber=20),
    perChain->log(~blockNumber=24),
    perChain->log(~blockNumber=25),
    open_->log(~blockNumber=2),
    always->log(~blockNumber=3),
    early->log(~blockNumber=14),
    early->log(~blockNumber=15),
    early->log(~blockNumber=31),
    lifted->log(~blockNumber=10),
    lifted->log(~blockNumber=20),
  ],
)

let configYaml = `
name: on-event-where-block
rollback_on_reorg: false
contracts:
  - name: Ledger
    events:
      - event: Static(address indexed from)
      - event: PerChain(address indexed from)
      - event: Open(address indexed from)
      - event: Always(address indexed from)
  - name: Late
    events:
      - event: Early(address indexed from)
  - name: Soon
    events:
      - event: Lifted(address indexed from)
chains:${served->ServedEvmChain.chainsYaml(
    ~hyperSync=[1, 2],
    ~rpc=[3, 4],
    ~contracts=`
      - name: Ledger
        address: "${ledger}"
      - name: Late
        address: "${late}"
        start_block: 30
      - name: Soon
        address: "${soon}"
        start_block: 5`,
  )}
`

let earlyHandler = `
// The \`where\` start block replaces the config.yaml one, even below it.
indexer.onEvent(
  { contract: "Late", event: "Early", where: { block: { number: { _gte: 15 } } } },
  async ({ event, context }) => context.Routed.set(routed(event, "Early")),
);
`

let scenario = Scenario.make(
  ~configYaml,
  ~schema=ServedEvmChain.routedSchema,
  ~handlers=ServedEvmChain.routedHandlers ++
  earlyHandler ++ `
indexer.onEvent(
  {
    contract: "Ledger",
    event: "Static",
    where: {
      params: { from: "0x0000000000000000000000000000000000000000" },
      block: { number: { _gte: 10 } },
    },
  },
  async ({ event, context }) => context.Routed.set(routed(event, "Static")),
);

indexer.onEvent(
  {
    contract: "Ledger",
    event: "PerChain",
    where: ({ chain }) => ({ block: { number: { _gte: chain.id % 2 === 1 ? 20 : 25 } } }),
  },
  async ({ event, context }) => context.Routed.set(routed(event, "PerChain")),
);

// Neither names a start block, so both start where the contract does.
indexer.onEvent(
  { contract: "Ledger", event: "Open", where: { block: { number: {} } } },
  async ({ event, context }) => context.Routed.set(routed(event, "Open")),
);
indexer.onEvent(
  { contract: "Ledger", event: "Always", where: () => true },
  async ({ event, context }) => context.Routed.set(routed(event, "Always")),
);

// The \`where\` start block replaces the config.yaml one above it too.
indexer.onEvent(
  { contract: "Soon", event: "Lifted", where: { block: { number: { _gte: 20 } } } },
  async ({ event, context }) => context.Routed.set(routed(event, "Lifted")),
);
`,
)

// The blocks each chain indexes an event at.
let expectedRows = eventBlocks =>
  [1, 2, 3, 4]
  ->Array.flatMap(chainId =>
    chainId
    ->eventBlocks
    ->Array.flatMap(((event, blocks)) =>
      blocks->Array.map(blockNumber => ServedEvmChain.routed(~chainId, ~blockNumber, event.name))
    )
  )
  ->ServedEvmChain.sorted

let earlyBlocks = (early, [15, 31])

// The block a source first asked for `event` from.
let firstBlock = (queries: array<ServedEvmChain.query>, event) =>
  queries
  ->Array.filter(query =>
    query.filters->Array.some(filter =>
      filter.topics
      ->Array.get(0)
      ->Option.mapOr(false, topic0 => topic0->Array.includes(event.sighash))
    )
  )
  ->Array.reduce(None, (first, query) => Some(
    first->Option.mapOr(query.fromBlock, first => Pervasives.min(first, query.fromBlock)),
  ))

describe("onEvent where block", () => {
  Async.it(
    "indexes each event only from its own start block, over HyperSync and RPC alike",
    async t =>
      await served->ServedEvmChain.run(
        scenario,
        async indexer =>
          t.expect(await indexer->ServedEvmChain.readRouted).toEqual(
            expectedRows(
              chainId => [
                (static, [10, 12]),
                (perChain, mod(chainId, 2) === 1 ? [20, 24, 25] : [25]),
                (open_, [2]),
                (always, [3]),
                (lifted, [20]),
                earlyBlocks,
              ],
            ),
          ),
      ),
  )

  // The only event of a run is fetched from its start block, with no range
  // below it asked for only to be thrown away — here below the contract's
  // config.yaml start block. Above, events share their queries, and each one's
  // start block is enforced on what comes back.
  Async.it("starts fetching a lone event at its start block", async t =>
    await served->ServedEvmChain.run(
      Scenario.make(
        ~configYaml,
        ~schema=ServedEvmChain.routedSchema,
        ~handlers=ServedEvmChain.routedHandlers ++ earlyHandler,
      ),
      async indexer =>
        t.expect((
          await indexer->ServedEvmChain.readRouted,
          served->ServedEvmChain.takeHyperSyncQueries->firstBlock(early),
          served->ServedEvmChain.takeRpcQueries->firstBlock(early),
        )).toEqual((expectedRows(_ => [earlyBlocks]), Some(15), Some(15))),
    )
  )
})
