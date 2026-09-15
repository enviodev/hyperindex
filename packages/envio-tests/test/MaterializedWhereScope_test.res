// What a table's `where` is for, at each of the three scopes it can have.
//
// `contractName`/`eventName` are the only fields settled at compile time: they
// decide which events get a plan at all, and cost nothing to check. Everything
// else — params, chainId, and block/transaction context — compiles to a
// predicate the runtime evaluates per event, and a block/transaction field a
// `where` reads is added to that event's `field_selection` so it is there to
// read.
//
// All three are settled before an event is processed, so they are asserted on
// the compiled plans rather than on rows.
let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: where-scope
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  # No \`where\` at all: a plan for every configured event, so \`select\` may only
  # read what every event has. \`params\` differ between the two, so this counts
  # events per block instead.
  block_activity:
    from: evm.events
    select:
      id: block.number
      events:
        _sum: 1

  # The usual shape: discriminators only, settled at compile time. The Approval
  # event never gets a plan, which is what lets \`params.to\` resolve here.
  transfers:
    from: evm.events
    where:
      contractName: ERC20
      eventName: Transfer
    select:
      id: params.to
      received:
        _sum: params.value

  # Context beyond the event itself. \`block.number\` and \`transaction.gasPrice\`
  # can't narrow the fetch, so both are checked per event — and \`gasPrice\` has
  # to be fetched for that check to be possible at all.
  late_cheap_transfers:
    from: evm.events
    where:
      eventName: Transfer
      block:
        number:
          _gte: 3
      transaction:
        gasPrice:
          _lte: 100
    select:
      id:
        _concat:
          separator: "/"
          values:
            - block.number
            - params.to
      value: params.value
`,
)

open Vitest

// Which events feed a table, and whether anything is left for the runtime.
let plansFor = table =>
  config.materializations
  ->Array.filter(m => m.table === table)
  ->Array.map(({contractName, eventName, filter}) => (
    `${contractName}.${eventName}`,
    filter->Option.isSome,
  ))

let fieldsFor = eventName =>
  switch config.chainMap
  ->ChainMap.values
  ->Array.flatMap(chain => chain.contracts)
  ->Array.flatMap((c: Config.contract) => c.events)
  ->Array.find((e: Internal.eventConfig) => e.name === eventName) {
  | Some(eventConfig) =>
    eventConfig.fieldSelection.transactionFields->Utils.Set.toArray->Array.toSorted(String.compare)
  | None => []
  }

describe("the scope of a table's where", () => {
  it("gives a plan to every event when there is no where", t =>
    t.expect(plansFor("block_activity")).toEqual([
      ("ERC20.Approval", false),
      ("ERC20.Transfer", false),
    ])
  )

  it("settles discriminators at compile time, leaving nothing to check", t =>
    t.expect(plansFor("transfers")).toEqual([("ERC20.Transfer", false)])
  )

  it("leaves context conditions to the runtime", t =>
    t.expect(plansFor("late_cheap_transfers")).toEqual([("ERC20.Transfer", true)])
  )

  // Only Transfer's plans read it, so Approval doesn't pay for the fetch.
  it("fetches a transaction field only for the events whose tables read it", t =>
    t.expect({
      "transfer": fieldsFor("Transfer"),
      "approval": fieldsFor("Approval"),
    }).toEqual({"transfer": ["gasPrice"], "approval": []})
  )
})
