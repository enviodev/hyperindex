open RescriptMocha

describe("Indexer.indexer", () => {
  it("has correct metadata", () => {
    Assert.deepEqual(Indexer.indexer.name, "test_codegen")
    Assert.deepEqual(Indexer.indexer.description, Some("Gravatar for Ethereum"))
    Assert.deepEqual(Indexer.indexer.chainIds, [#1, #100, #137, #1337])
  })

  it("has correct chain configurations", () => {
    Assert.deepEqual(
      Indexer.indexer.chains.c1337,
      {id: #1337, startBlock: 1, endBlock: None, name: "1337", isLive: false},
    )
    Assert.deepEqual(
      Indexer.indexer.chains.c1,
      {id: #1, startBlock: 1, endBlock: None, name: "ethereumMainnet", isLive: false},
    )
    Assert.deepEqual(
      Indexer.indexer.chains.c100,
      {id: #100, startBlock: 1, endBlock: None, name: "gnosis", isLive: false},
    )
    Assert.deepEqual(
      Indexer.indexer.chains.c137,
      {id: #137, startBlock: 1, endBlock: None, name: "polygon", isLive: false},
    )
  })

  it("chains by name are not enumerable, but should be accessible by name", () => {
    Assert.equal(Indexer.indexer.chains.c1, Indexer.indexer.chains.ethereumMainnet)
    Assert.equal(Indexer.indexer.chains.c100, Indexer.indexer.chains.gnosis)
    Assert.equal(Indexer.indexer.chains.c137, Indexer.indexer.chains.polygon)
  })

  it("getChainById returns correct chain", () => {
    Assert.equal(Indexer.getChainById(Indexer.indexer, #1337), Indexer.indexer.chains.c1337)
  })
})
