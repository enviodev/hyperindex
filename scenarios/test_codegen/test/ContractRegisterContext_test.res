open Vitest

// `context.chain.ContractName.add()` validates the contract name against every
// configured chain, not just the chain the event fired on. So a contract is
// registerable from a chain that doesn't list it — including a globally-defined
// contract that's assigned to no chain at all (it shouldn't have to be repeated
// under every chain just to be registerable there).

type addApi = {add: Address.t => unit}

@get external chainProxy: Internal.contractRegisterContext => dict<addApi> = "chain"

let greeterAddress = Address.unsafeFromString("0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")

let makeContext = (~config, ~chainId) => {
  let item = Internal.Event({
    eventConfig: "mock"->(Utils.magic: string => Internal.eventConfig),
    timestamp: 0,
    chain: ChainMap.Chain.makeUnsafe(~chainId),
    blockNumber: 0,
    blockHash: "0x0",
    logIndex: 0,
    transactionIndex: 0,
    payload: "mock"->(Utils.magic: string => Internal.eventPayload),
  })
  let registered = []
  let params: ContractRegisterContext.contractRegisterParams = {
    item,
    config,
    isResolved: false,
    onRegister: (~item as _, ~contractAddress, ~contractName) =>
      registered->Array.push((contractName, contractAddress->Address.toString))->ignore,
  }
  (ContractRegisterContext.getContractRegisterContext(params)->chainProxy, registered)
}

describe("ContractRegisterContext", () => {
  // `Greeter` is configured (with an address) only on chain 1. `fromPublic`
  // mirrors every contract onto every chain with empty addresses, so chain 2 is
  // stripped of `Greeter` below to model a chain that never mentions it.
  it("registers a contract that isn't listed on the event's chain", t => {
    let config = Config.fromPublic(%raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "chain1": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": { "Greeter": { "addresses": ["0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"] } }
          },
          "chain2": { "id": 2, "startBlock": 0, "rpcs": [{ "url": "https://other.com", "for": "sync" }] }
        },
        "contracts": {
          "Greeter": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()", "name": "NewGreeting", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`))
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
    let (chain, registered) = makeContext(~config={...config, chainMap}, ~chainId=2)

    chain->Dict.getUnsafe("Greeter")->(api => api.add(greeterAddress))

    t.expect(registered).toEqual([("Greeter", "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")])
  })

  // `Unassigned` is defined globally but referenced under no chain's contracts.
  it("registers a globally-defined contract assigned to no chain", t => {
    let config = Config.fromPublic(%raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "chain1": { "id": 1, "startBlock": 0, "rpcs": [{ "url": "https://eth.com", "for": "sync" }] },
          "chain2": { "id": 2, "startBlock": 0, "rpcs": [{ "url": "https://other.com", "for": "sync" }] }
        },
        "contracts": {
          "Unassigned": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()", "name": "NewGreeting", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`))
    let (chain, registered) = makeContext(~config, ~chainId=2)

    chain->Dict.getUnsafe("Unassigned")->(api => api.add(greeterAddress))

    t.expect(registered).toEqual([("Unassigned", "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")])
  })

  it("still rejects a contract name that exists on no chain", t => {
    let config = Config.fromPublic(%raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": { "chain1": { "id": 1, "startBlock": 0, "rpcs": [{ "url": "https://eth.com", "for": "sync" }] } },
        "addressFormat": "checksum"
      }
    }`))
    let (chain, _) = makeContext(~config, ~chainId=1)

    t.expect(() => chain->Dict.getUnsafe("Unknown")->(api => api.add(greeterAddress))).toThrowError(
      "Invalid contract name 'Unknown' on context.chain.",
    )
  })
})
