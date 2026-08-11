open Vitest

// Contract names are capitalized everywhere downstream — the runtime keys each
// chain's contracts by the capitalized name, and codegen emits modules and
// `contract:` literals from it. Config parsing requires the capital so the two
// sides can't disagree; before it did, `name: myToken` compiled and then threw
// "not configured on any chain" at startup.
let configYaml = name => `
name: capitalized-contract
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

let parseError = name =>
  try {
    let _ = InternalTestIndexer.fromUserApi(~configYaml=configYaml(name))
    None
  } catch {
  | JsExn(exn) => exn->JsExn.message
  }

describe("Contract name capitalization", () => {
  it("rejects an uncapitalized name, naming the rename", t => {
    t.expect(parseError("myToken")).toEqual(
      Some(
        `Config parse error: The config has contract names that don't start with a capital letter: "myToken". You write these names in handlers and they name the generated types, so rename them to "MyToken".`,
      ),
    )
  })

  it("accepts the capitalized spelling", t => {
    t.expect(parseError("MyToken")).toEqual(None)
  })
})
