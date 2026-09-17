open Vitest

// `envio start --chain` hands the runtime the public config with the selected
// chains under `isolatedChains`. The config narrows to them without touching the
// contract mapping, whose ids have to keep matching the ones the migration
// stored, and the selection stays out of the fingerprint `envio_info` holds.

let perChainSchema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let crossChainSchema = `
type Counter {
  id: ID!
  count: BigInt!
}
type GlobalCounter @crossChain {
  id: ID!
  count: BigInt!
}
`

let configYaml = `
name: isolated-config
disable_default_cross_chain: true
contracts:
  - name: Counters
    events:
      - event: Bumped(uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
  - id: 137
    start_block: 0
    contracts:
      - name: Counters
        address: "0x2222222222222222222222222222222222222222"
`

let publicJson = (~schema, ~isolatedChains=?) => {
  let json = Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow
  switch (json, isolatedChains) {
  | (Object(obj), Some(chainIds)) => obj->Dict.set("isolatedChains", JSON.Encode.array(chainIds))
  | _ => ()
  }
  json
}

let chainIds = (config: Config.t) => config.chainMap->ChainMap.keys->Array.map(ChainId.toString)

describe("Isolated config", () => {
  it("Narrows to the selected chains and keeps the contract mapping whole", t => {
    let whole = Config.fromPublic(publicJson(~schema=perChainSchema))
    let isolated = Config.fromPublic(
      publicJson(~schema=perChainSchema, ~isolatedChains=[JSON.Encode.int(137)]),
    )
    t.expect((
      (whole.isolated, whole->chainIds),
      (
        isolated.isolated,
        isolated->chainIds,
        isolated.defaultChain->Option.map(chain => chain.id->ChainId.toString),
        isolated.contractMapping->ContractMapping.isEqual(whole.contractMapping),
      ),
    )).toEqual(((false, ["1", "137"]), (true, ["137"], Some("137"), true)))
  })

  // Naming every chain is still an isolated run: it needs the database the
  // migration built rather than initializing one of its own.
  it("Is isolated even when the selection names every chain", t => {
    let config = Config.fromPublic(
      publicJson(
        ~schema=perChainSchema,
        ~isolatedChains=[JSON.Encode.int(1), JSON.Encode.int(137)],
      ),
    )
    t.expect((config.isolated, config->chainIds)).toEqual((true, ["1", "137"]))
  })

  it("Leaves the selection out of the stored fingerprint", t => {
    t.expect(
      publicJson(~schema=perChainSchema, ~isolatedChains=[JSON.Encode.int(137)])
      ->Config.stripSensitiveData
      ->JSON.stringify,
    ).toEqual(publicJson(~schema=perChainSchema)->Config.stripSensitiveData->JSON.stringify)
  })

  it("Rejects a chain the config doesn't declare", t => {
    t->toThrowErrorEqual(
      () =>
        Config.fromPublic(
          publicJson(~schema=perChainSchema, ~isolatedChains=[JSON.Encode.int(42)]),
        ),
      "No chain with id 42 found in config.yaml",
    )
  })

  // The user-facing rejection is the CLI's; this is the same rule as an
  // invariant for a payload that skipped it.
  it("Rejects a schema that shares entities across chains", t => {
    t->toThrowErrorEqual(
      () =>
        Config.fromPublic(
          publicJson(~schema=crossChainSchema, ~isolatedChains=[JSON.Encode.int(1)]),
        ),
      "Only a schema whose entities are all per-chain can be split across processes. Shared across chains: GlobalCounter.",
    )
  })
})
