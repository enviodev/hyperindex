open RescriptMocha

describe("Indexer.indexer", () => {
  it("has correct metadata", () => {
    Assert.deepEqual(Indexer.indexer.name, "test_codegen")
    Assert.deepEqual(Indexer.indexer.description, Some("Gravatar for Ethereum"))
    Assert.deepEqual(Indexer.indexer.chainIds, [#1, #100, #137, #1337])
  })

  it("has correct chain configurations", () => {
    Assert.deepEqual(
      Indexer.indexer.chains.chain1337,
      {
        id: #1337,
        startBlock: 1,
        endBlock: None,
        name: "1337",
        isLive: false,
        \"NftFactory": {
          name: "NftFactory",
          addresses: ["0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Address.unsafeFromString],
          abi: %raw(`[{"type":"event","name":"SimpleNftCreated","inputs":[{"name":"name","type":"string","indexed":false},{"name":"symbol","type":"string","indexed":false},{"name":"maxSupply","type":"uint256","indexed":false},{"name":"contractAddress","type":"address","indexed":false}],"anonymous":false}]`),
        },
        \"EventFiltersTest": {
          name: "EventFiltersTest",
          addresses: [],
          abi: %raw(`[{"type":"event","name":"EmptyFiltersArray","inputs":[{"name":"from","type":"address","indexed":true}],"anonymous":false},{"type":"event","name":"FilterTestEvent","inputs":[{"name":"addr","type":"address","indexed":true}],"anonymous":false},{"type":"event","name":"Transfer","inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"amount","type":"uint256","indexed":false}],"anonymous":false},{"type":"event","name":"WildcardHandlerWithLoader","inputs":[],"anonymous":false},{"type":"event","name":"WildcardWithAddress","inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"amount","type":"uint256","indexed":false}],"anonymous":false},{"type":"event","name":"WithExcessField","inputs":[{"name":"from","type":"address","indexed":true}],"anonymous":false}]`),
        },
        \"SimpleNft": {
          name: "SimpleNft",
          addresses: [],
          abi: %raw(`[{"type":"event","name":"Erc20Transfer","inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"amount","type":"uint256","indexed":false}],"anonymous":false},{"type":"event","name":"Transfer","inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"tokenId","type":"uint256","indexed":true}],"anonymous":false}]`),
        },
        \"TestEvents": {
          name: "TestEvents",
          addresses: [],
          abi: %raw(`[{"type":"event","name":"IndexedAddress","inputs":[{"name":"addr","type":"address","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedArray","inputs":[{"name":"array","type":"uint256[]","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedBool","inputs":[{"name":"isTrue","type":"bool","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedBytes","inputs":[{"name":"dynBytes","type":"bytes","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedFixedArray","inputs":[{"name":"array","type":"uint256[2]","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedFixedBytes","inputs":[{"name":"fixedBytes","type":"bytes32","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedInt","inputs":[{"name":"num","type":"int256","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedNestedArray","inputs":[{"name":"array","type":"uint256[2][2]","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedNestedStruct","inputs":[{"name":"nestedStruct","type":"tuple","indexed":true,"components":[{"type":"uint256"},{"type":"tuple","components":[{"type":"uint256"},{"type":"string"}]}]}],"anonymous":false},{"type":"event","name":"IndexedString","inputs":[{"name":"str","type":"string","indexed":true}],"anonymous":false},{"type":"event","name":"IndexedStruct","inputs":[{"name":"testStruct","type":"tuple","indexed":true,"components":[{"type":"uint256"},{"type":"string"}]}],"anonymous":false},{"type":"event","name":"IndexedStructArray","inputs":[{"name":"array","type":"tuple[2]","indexed":true,"components":[{"type":"uint256"},{"type":"string"}]}],"anonymous":false},{"type":"event","name":"IndexedStructWithArray","inputs":[{"name":"structWithArray","type":"tuple","indexed":true,"components":[{"type":"uint256[]"},{"type":"string[2]"}]}],"anonymous":false},{"type":"event","name":"IndexedUint","inputs":[{"name":"num","type":"uint256","indexed":true}],"anonymous":false}]`),
        },
        \"Gravatar": {
          name: "Gravatar",
          addresses: ["0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Address.unsafeFromString],
          abi: %raw(`[{"type":"event","name":"CustomSelection","inputs":[],"anonymous":false},{"type":"event","name":"EmptyEvent","inputs":[],"anonymous":false},{"type":"event","name":"FactoryEvent","inputs":[{"name":"contract","type":"address","indexed":true},{"name":"testCase","type":"string","indexed":false}],"anonymous":false},{"type":"event","name":"NewGravatar","inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"owner","type":"address","indexed":false},{"name":"displayName","type":"string","indexed":false},{"name":"imageUrl","type":"string","indexed":false}],"anonymous":false},{"type":"event","name":"TestEvent","inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"user","type":"address","indexed":false},{"name":"contactDetails","type":"tuple","indexed":false,"components":[{"type":"string"},{"type":"string"}]}],"anonymous":false},{"type":"event","name":"TestEvent","inputs":[],"anonymous":false},{"type":"event","name":"TestEventThatCopiesBigIntViaLinkedEntities","inputs":[{"name":"param_that_should_be_removed_when_issue_1026_is_fixed","type":"string","indexed":false}],"anonymous":false},{"type":"event","name":"TestEventWithLongNameBeyondThePostgresEnumCharacterLimit","inputs":[{"name":"testField","type":"address","indexed":false}],"anonymous":false},{"type":"event","name":"TestEventWithReservedKeyword","inputs":[{"name":"module","type":"string","indexed":false}],"anonymous":false},{"type":"event","name":"UpdatedGravatar","inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"owner","type":"address","indexed":false},{"name":"displayName","type":"string","indexed":false},{"name":"imageUrl","type":"string","indexed":false}],"anonymous":false}]`),
        },
        \"Noop": {
          name: "Noop",
          addresses: [],
          abi: %raw(`[{"type":"event","name":"EmptyEvent","inputs":[],"anonymous":false}]`),
        },
      },
    )
  })

  it("chains by name are not enumerable, but should be accessible by name", () => {
    Assert.equal(Indexer.indexer.chains.chain1, Indexer.indexer.chains.ethereumMainnet)
    Assert.equal(Indexer.indexer.chains.chain100, Indexer.indexer.chains.gnosis)
    Assert.equal(Indexer.indexer.chains.chain137, Indexer.indexer.chains.polygon)
  })

  it("getChainById returns correct chain", () => {
    Assert.equal(Indexer.getChainById(Indexer.indexer, #1337), Indexer.indexer.chains.chain1337)
  })
})
