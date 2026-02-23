open Vitest

describe("Config.fromPublic", () => {
  it("resolves ABI for lowercase contract name in internal config", t => {
    // Internal config JSON with a lowercase contract name key ("greeter")
    let publicConfigJson: Js.Json.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }]
          }
        },
        "contracts": {
          "greeter": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    // Generated.res would use the capitalized name "Greeter"
    let codegenChains: array<Config.codegenChain> = [
      {
        id: 1,
        contracts: [
          {
            Config.name: "Greeter",
            addresses: ["0x0000000000000000000000000000000000000001"],
            events: [],
            startBlock: None,
          },
        ],
      },
    ]

    // This should not throw - the fix capitalizes the internal config key
    // before lookup, so "greeter" -> "Greeter" matches the codegen name
    let config = Config.fromPublic(publicConfigJson, ~codegenChains)

    let chain = config.chainMap->ChainMap.values->Js.Array2.unsafe_get(0)
    let contracts = chain.contracts
    t.expect(contracts->Array.length, ~message="Should have one contract").toBe(1)
    let contract = contracts->Js.Array2.unsafe_get(0)
    t.expect(
      contract.name,
      ~message="Contract name should be the capitalized version from codegen",
    ).toBe("Greeter")
  })

  it("works with already-capitalized contract name", t => {
    let publicConfigJson: Js.Json.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }]
          }
        },
        "contracts": {
          "Greeter": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    let codegenChains: array<Config.codegenChain> = [
      {
        id: 1,
        contracts: [
          {
            Config.name: "Greeter",
            addresses: ["0x0000000000000000000000000000000000000001"],
            events: [],
            startBlock: None,
          },
        ],
      },
    ]

    let config = Config.fromPublic(publicConfigJson, ~codegenChains)

    let chain = config.chainMap->ChainMap.values->Js.Array2.unsafe_get(0)
    let contracts = chain.contracts
    t.expect(contracts->Array.length, ~message="Should have one contract").toBe(1)
    let contract = contracts->Js.Array2.unsafe_get(0)
    t.expect(
      contract.name,
      ~message="Contract name should remain Greeter",
    ).toBe("Greeter")
  })
})
