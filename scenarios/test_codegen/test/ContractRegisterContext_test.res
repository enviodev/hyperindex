open Vitest

// `Greeter` is configured (with an address) only on chain 1. `fromPublic`
// mirrors every contract onto every chain with empty addresses, so chain 2 is
// stripped of `Greeter` below to model a chain that never mentions the
// contract — exactly the "contract without addresses on this chain" case.
let publicConfigJson: JSON.t = %raw(`{
  "version": "0.0.1-dev",
  "name": "test",
  "storage": { "postgres": true },
  "evm": {
    "chains": {
      "chain1": {
        "id": 1,
        "startBlock": 0,
        "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
        "contracts": {
          "Greeter": { "addresses": ["0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"] }
        }
      },
      "chain2": {
        "id": 2,
        "startBlock": 0,
        "rpcs": [{ "url": "https://other.com", "for": "sync" }]
      }
    },
    "contracts": {
      "Greeter": {
        "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
        "events": [{ "event": "NewGreeting()", "name": "NewGreeting", "sighash": "0x00000000" }]
      }
    },
    "addressFormat": "checksum"
  }
}`)

let chain2 = ChainMap.Chain.makeUnsafe(~chainId=2)
let greeterAddress = Address.unsafeFromString("0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")

let makeConfig = () => {
  let config = Config.fromPublic(publicConfigJson)
  let chainMap =
    config.chainMap
    ->ChainMap.values
    ->Array.map(chain => {
      let chain =
        chain.id == 2
          ? {...chain, contracts: chain.contracts->Array.filter(c => c.name !== "Greeter")}
          : chain
      (ChainMap.Chain.makeUnsafe(~chainId=chain.id), chain)
    })
    ->ChainMap.fromArrayUnsafe
  {...config, chainMap}
}

let makeContext = (~onRegister) => {
  let item = Internal.Event({
    eventConfig: "mock"->(Utils.magic: string => Internal.eventConfig),
    timestamp: 0,
    chain: chain2,
    blockNumber: 0,
    blockHash: "0x0",
    logIndex: 0,
    transactionIndex: 0,
    payload: "mock"->(Utils.magic: string => Internal.eventPayload),
  })
  let params: ContractRegisterContext.contractRegisterParams = {
    item,
    onRegister,
    config: makeConfig(),
    isResolved: false,
  }
  ContractRegisterContext.getContractRegisterContext(params)->(
    Utils.magic: Internal.contractRegisterContext => {
      "chain": {
        "Greeter": {"add": Address.t => unit},
        "Unknown": {"add": Address.t => unit},
      },
    }
  )
}

describe("ContractRegisterContext", () => {
  it("registers a contract that isn't listed on the event's chain", t => {
    let registered = []
    let context = makeContext(
      ~onRegister=(~item as _, ~contractAddress, ~contractName) =>
        registered->Array.push((contractName, contractAddress->Address.toString))->ignore,
    )

    context["chain"]["Greeter"]["add"](greeterAddress)

    t.expect(registered).toEqual([("Greeter", "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")])
  })

  it("still rejects a contract name that exists on no chain", t => {
    let context = makeContext(~onRegister=(~item as _, ~contractAddress as _, ~contractName as _) => ())

    t.expect(() => context["chain"]["Unknown"]["add"](greeterAddress)).toThrowError(
      "Invalid contract name 'Unknown' on context.chain.",
    )
  })
})
