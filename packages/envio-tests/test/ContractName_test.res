open Vitest

// config.yaml may spell a contract's name however it likes. Generated code
// can't: ReScript module names start with a capital and take no leading
// underscore. So the name is normalized once, at parse time, and both sides of
// the config keep referring to it however they wrote it — before, `name:
// myToken` compiled and then threw "not configured on any chain" at startup.
let configYaml = name => `
name: contract-name
disable_default_cross_chain: true
contracts:
  - name: ${name}
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ${name}
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  transfers:
    from: evm.events
    where:
      contractName: ${name}
      eventName: Transfer
    select:
      id: params.to
      total:
        _sum: params.value
`

let namesOf = name => {
  let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
    ~configYaml=configYaml(name),
  )
  let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
  {
    "contract": (chain.contracts->Array.getUnsafe(0)).name,
    "materializedFrom": config.materializations
    ->Array.map((plan: MaterializationPlan.t) => plan.contractName),
  }
}

describe("Contract name normalization", () => {
  [
    ("an already capitalized name", "MyToken"),
    ("an uncapitalized name", "myToken"),
    ("a name behind underscores", "__myToken"),
  ]->Array.forEach(((what, name)) =>
    it(
      `Reaches the handler side as MyToken, given ${what}`,
      t =>
        t.expect(namesOf(name)).toEqual({
          "contract": "MyToken",
          "materializedFrom": ["MyToken"],
        }),
    )
  )
})
