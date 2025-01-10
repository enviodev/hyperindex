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
        contracts: Js.Dict.fromArray([
          (
            "Noop",
            {
              ConfigYAML.name: "Noop",
              abi: %raw(`[{
                anonymous: false,
                inputs: [],
                name: "EmptyEvent",
                type: "event"
              }]`),
              addresses: ["0x0B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"],
              events: ["EmptyEvent"],
            },
          ),
        ]),
      },
    )
  })
})
