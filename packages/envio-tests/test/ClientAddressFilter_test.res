open Vitest

// Detection of address-param filters in a `where` callback
// (`addressFilterParamGroups` in `LogSelection.parseWhereOrThrow`) and their
// survival onto the registration. Applying them — the srcAddress gate, the
// param DNF, and the `effectiveStartBlock` cutoff — is the address store's job
// and is covered by the Rust routing tests.

let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let parseEvm = (~eventFilters: option<JSON.t>, ~chainId=1->ChainId.fromInt) =>
  LogSelection.parseWhereOrThrow(
    ~where=eventFilters,
    ~sighash=transferSighash,
    ~params=["from", "to"],
    ~contractName="ERC20",
    ~chainId,
    ~onEventBlockFilterSchema=Evm.make(~logger=Logging.getLogger()).onEventBlockFilterSchema,
  )

describe("parseWhereOrThrow — address-param detection", () => {
  it("collects the address-filtered param (single group)", t => {
    let {filterByAddresses, addressFilterParamGroups} = parseEvm(
      ~eventFilters=Some(%raw(`({chain}) => ({params: {to: chain.ERC20.addresses}})`)),
    )
    t.expect((filterByAddresses, addressFilterParamGroups)).toEqual((true, [["to"]]))
  })

  it("collects OR of groups and ignores constant params", t => {
    // Mirrors the WildcardWithAddress handler: each group pairs the registry
    // addresses with a constant; only the registry-sourced param is collected.
    let {addressFilterParamGroups} = parseEvm(
      ~eventFilters=Some(
        %raw(`({chain}) => {
          const a = chain.ERC20.addresses;
          return {params: [
            {from: "0x0000000000000000000000000000000000000000", to: a},
            {from: a, to: "0x0000000000000000000000000000000000000000"},
          ]};
        }`),
      ),
    )
    t.expect(addressFilterParamGroups).toEqual([["to"], ["from"]])
  })

  it("has no address-param groups for a static filter", t => {
    let {filterByAddresses, addressFilterParamGroups} = parseEvm(
      ~eventFilters=Some(%raw(`{params: {from: "0x0000000000000000000000000000000000000000"}}`)),
    )
    t.expect((filterByAddresses, addressFilterParamGroups)).toEqual((false, []))
  })

  it("throws when the addresses are transformed instead of passed directly", t => {
    t->toThrowErrorEqual(() =>
      parseEvm(
        ~eventFilters=Some(%raw(`({chain}) => ({params: {to: [...chain.ERC20.addresses]}})`)),
      )->ignore
    , 
      "Invalid where configuration for \"ERC20\": chain.ERC20.addresses must be passed directly as an indexed-param filter value (e.g. { params: { to: chain.ERC20.addresses } }). It cannot be spread, mapped, indexed, or otherwise transformed.",
    )
  })

  it("throws when addresses are read but not used as a param filter", t => {
    t->toThrowErrorEqual(() =>
      parseEvm(
        ~eventFilters=Some(%raw(`({chain}) => { const _a = chain.ERC20.addresses; return true }`)),
      )->ignore
    , 
      "Invalid where configuration for ERC20. The callback reads `chain.ERC20.addresses` but doesn't use it as an indexed-param filter value. Use it directly, e.g. { params: { to: chain.ERC20.addresses } }.",
    )
  })
})

describe("the registration carries its address-param groups", () => {
  let transferParams: array<EventConfigBuilder.paramMeta> = [
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]

  let build = (~eventFilters: JSON.t, ~isWildcard) =>
    EventConfigBuilder.buildEvmOnEventRegistration(
      ~eventConfig=EventConfigBuilder.buildEvmEventConfig(
        ~contractName="ERC20",
        ~eventName="Transfer",
        ~sighash=transferSighash,
        ~params=transferParams,
      ),
      ~isWildcard,
      ~handler=None,
      ~contractRegister=None,
      ~where=Some(eventFilters),
      ~chainId=1->ChainId.fromInt,
      ~onEventBlockFilterSchema=Evm.make(~logger=Logging.getLogger()).onEventBlockFilterSchema,
    )

  it("carries the DNF for filtered events and nothing for the rest", t => {
    let orOfGroups = build(
      ~isWildcard=true,
      ~eventFilters=%raw(`({chain}) => {
        const a = chain.ERC20.addresses;
        return {params: [
          {from: "0x0000000000000000000000000000000000000000", to: a},
          {from: a, to: "0x0000000000000000000000000000000000000000"},
        ]};
      }`),
    )
    let andWithinGroup = build(
      ~isWildcard=true,
      ~eventFilters=%raw(`({chain}) => {
        const a = chain.ERC20.addresses;
        return {params: {from: a, to: a}};
      }`),
    )
    let staticFilter = build(
      ~isWildcard=true,
      ~eventFilters=%raw(`{params: {from: "0x0000000000000000000000000000000000000000"}}`),
    )
    let blockFilter = build(~isWildcard=false, ~eventFilters=%raw(`{block: {number: {_gte: 10}}}`))

    t.expect({
      "orOfGroups": orOfGroups.addressFilterParamGroups,
      "andWithinGroup": andWithinGroup.addressFilterParamGroups,
      "staticFilter": staticFilter.addressFilterParamGroups,
      "blockFilter": blockFilter.addressFilterParamGroups,
      // The DNF is what makes a wildcard event address-dependent, so its
      // partition still has to carry the contract's addresses.
      "orOfGroupsDependsOnAddresses": orOfGroups.dependsOnAddresses,
      "staticFilterDependsOnAddresses": staticFilter.dependsOnAddresses,
    }).toEqual({
      "orOfGroups": Some([["to"], ["from"]]),
      "andWithinGroup": Some([["from", "to"]]),
      "staticFilter": Some([]),
      "blockFilter": Some([]),
      "orOfGroupsDependsOnAddresses": true,
      "staticFilterDependsOnAddresses": false,
    })
  })
})
