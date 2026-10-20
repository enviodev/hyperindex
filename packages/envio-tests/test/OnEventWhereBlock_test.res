open Vitest

// `indexer.onEvent` `where.block.number._gte`, from a user's config.yaml and
// handler source to where each source starts fetching and the rows the indexer
// writes. Chains 1 and 2 fetch over HyperSync and chains 3 and 4 over RPC, all
// from the same served logs; a per-chain callback tells chains 1 and 3 from 2
// and 4.

let hyperSyncPort = 18615
let rpcPort = 18616
let height = 40

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

let logs = [
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
]

let served = ServedEvmChain.serveDuringSuite(~hyperSyncPort, ~rpcPort, ~height, ~logs)

let chainYaml = (~id, ~source) =>
  `
  - id: ${id->Int.toString}
    start_block: 1
    end_block: ${height->Int.toString}${source}
    contracts:
      - name: Ledger
        address: "${ledger}"
      - name: Late
        address: "${late}"
        start_block: 30
      - name: Soon
        address: "${soon}"
        start_block: 5`

let hyperSyncChain = id =>
  chainYaml(
    ~id,
    ~source=`
    hypersync_config:
      url: ${ServedEvmChain.url(hyperSyncPort)}`,
  )
let rpcChain = id =>
  chainYaml(
    ~id,
    ~source=`
    rpc:
      url: ${ServedEvmChain.url(rpcPort)}
      for: sync`,
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
chains:${hyperSyncChain(1)}${hyperSyncChain(2)}${rpcChain(3)}${rpcChain(4)}
`

let schema = `
type Routed {
  id: ID!
  chainId: Int!
  event: String!
}
`

let handlersPrelude = `
import { indexer } from "envio";

type Routable = { chainId: number; block: { number: number } };
const routed = (event: Routable, name: string) => ({
  id: \`\${event.chainId}-\${event.block.number}-\${name}\`,
  chainId: event.chainId,
  event: name,
});

// The \`where\` start block replaces the config.yaml one, even below it.
indexer.onEvent(
  { contract: "Late", event: "Early", where: { block: { number: { _gte: 15 } } } },
  async ({ event, context }) => context.Routed.set(routed(event, "Early")),
);
`

// Every chain stops at its end block before realtime, so the supervised pass
// would have no barrier to hold.
let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml,
  ~schema,
  ~handlers=handlersPrelude ++ `
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

type routed = {id: string, chainId: int, event: string}

let byId = (rows: array<routed>) => rows->Array.toSorted((a, b) => String.compare(a.id, b.id))

let isOdd = chainId => mod(chainId, 2) === 1

let expectedRows =
  [1, 2, 3, 4]
  ->Array.flatMap(chainId =>
    [
      (static, [10, 12]),
      (perChain, isOdd(chainId) ? [20, 24, 25] : [25]),
      (open_, [2]),
      (always, [3]),
      (early, [15, 31]),
      (lifted, [20]),
    ]->Array.flatMap(((event, blocks)) =>
      blocks->Array.map(
        blockNumber => {
          id: `${chainId->Int.toString}-${blockNumber->Int.toString}-${event.name}`,
          chainId,
          event: event.name,
        },
      )
    )
  )
  ->byId

// The block each source first asked for an event from.
let firstBlocks = (queries: array<ServedEvmChain.query>, ~events) =>
  events->Array.map(event => (
    event.name,
    queries
    ->Array.filter(query =>
      query.filters->Array.some(
        filter =>
          filter.topics
          ->Array.get(0)
          ->Option.mapOr(false, topic0 => topic0->Array.includes(event.sighash)),
      )
    )
    ->Array.map(query => query.fromBlock)
    ->Array.reduce(None, (first, fromBlock) => Some(
      first->Option.mapOr(fromBlock, first => Pervasives.min(first, fromBlock)),
    )),
  ))

describe("onEvent where block", () => {
  let endBlock = ServedEvmChain.endBlock()

  scenario->Scenario.it(
    "indexes each event only from its own start block, over HyperSync and RPC alike",
    ~servedChains=[1, 2, 3, 4],
    ~onExit=endBlock.onExit,
    async (~t, ~indexer, ~source as _) => {
      await endBlock.reachEndBlock()
      t.expect((await indexer.query("Routed"))->byId).toEqual(expectedRows)
    },
  )

  // The only event of a run is fetched from its start block, with no range
  // below it asked for only to be thrown away — here below the contract's
  // config.yaml start block. Above, events share their queries, and each one's
  // start block is enforced on what comes back.
  let aloneEndBlock = ServedEvmChain.endBlock()
  Scenario.make(
    ~supervised=false,
    ~configYaml,
    ~schema,
    ~handlers=handlersPrelude,
  )->Scenario.it(
    "starts fetching a lone event at its start block",
    ~servedChains=[1, 2, 3, 4],
    ~onExit=aloneEndBlock.onExit,
    async (~t, ~indexer, ~source as _) => {
      served()->ServedEvmChain.reset
      await aloneEndBlock.reachEndBlock()
      t.expect((
        (await indexer.query("Routed"))->byId,
        served()->ServedEvmChain.takeHyperSyncQueries->firstBlocks(~events=[early]),
        served()->ServedEvmChain.takeRpcQueries->firstBlocks(~events=[early]),
      )).toEqual((
        expectedRows->Array.filter(row => row.event === "Early"),
        [("Early", Some(15))],
        [("Early", Some(15))],
      ))
    },
  )
})
