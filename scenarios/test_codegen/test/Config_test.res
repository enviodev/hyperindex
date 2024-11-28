open RescriptMocha

describe("getGeneratedByChainId Test", () => {
  it("getGeneratedByChainId should return the correct config", () => {
    let configYaml = ConfigYAML.getGeneratedByChainId(1)
    Assert.deepEqual(
      configYaml,
      {
        syncSource: HyperSync({endpointUrl: "https://1.hypersync.xyz"}),
        startBlock: 1,
        confirmedBlockThreshold: 200,
        contracts: Js.Dict.empty(),
      },
    )
  })
})
