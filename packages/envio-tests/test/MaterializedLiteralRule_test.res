open Vitest

// A comparison knows the type it expects, so the value side takes the shorter
// spelling where it can't be mistaken for a path: a name in a closed vocabulary
// like `eventName`, and an address anywhere an address is expected.
let plansFor = where => {
  let config = InternalTestIndexer.fromUserApi(
    ~configYaml=`
name: literal-rule
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
  totals:
    from: evm.events
    where:
${where}
    select:
      id: params.to
`,
  ).config
  config.materializations->Array.map(({contractName, eventName, filter}) => (
    `${contractName}.${eventName}`,
    filter->Option.isSome,
  ))
}

describe("the literal rule in a comparison", () => {
  it("reads `_literal` and a bare name as the same discriminator", t =>
    t.expect(
      plansFor(`      eventName:
        _eq:
          _literal: Transfer`),
    ).toEqual(plansFor(`      eventName: Transfer`))
  )

  it("narrows to one event either way", t =>
    t.expect(plansFor(`      eventName: Transfer`)).toEqual([("ERC20.Transfer", false)])
  )

  it("reads a bare address as a value, leaving a runtime filter", t =>
    t.expect(
      plansFor(`      eventName: Transfer
      srcAddress:
        _eq: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"`),
    ).toEqual([("ERC20.Transfer", true)])
  )

  it("reads a value with no operator as the equality the shorthand means", t =>
    t.expect(
      plansFor(`      eventName: Transfer
      srcAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"`),
    ).toEqual(
      plansFor(`      eventName: Transfer
      srcAddress:
        _eq: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"`),
    )
  )

  it("still reads a bare string as a path when one resolves", t =>
    t.expect(
      plansFor(`      eventName: Transfer
      params:
        from:
          _neq: params.to`),
    ).toEqual([("ERC20.Transfer", true)])
  )
})
