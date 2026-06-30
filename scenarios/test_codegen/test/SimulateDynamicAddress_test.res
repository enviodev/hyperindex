open Vitest

// NftFactory.SimpleNftCreated's contractRegister adds the emitted
// `contractAddress` as a SimpleNft, and SimpleNft.Transfer is a non-wildcard
// event whose srcAddress must be an indexed address.
let nftFactory = Address.unsafeFromString("0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC") // configured on chain 1337
let newNft = Address.unsafeFromString("0x1111111111111111111111111111111111111111")
let owner = Address.unsafeFromString("0x2222222222222222222222222222222222222222")
let zero = Address.unsafeFromString("0x0000000000000000000000000000000000000000")

let createNft: Envio.evmSimulateItem = {
  ...Indexer.makeSimulateItem(
    OnEvent({
      event: NftFactory(SimpleNftCreated),
      params: {name: "n", symbol: "s", maxSupply: 0n, contractAddress: newNft},
    }),
  ),
  srcAddress: nftFactory,
}

let transferNft: Envio.evmSimulateItem = {
  ...Indexer.makeSimulateItem(
    OnEvent({
      event: SimpleNft(Transfer),
      params: {from: zero, to: owner, tokenId: 7n},
    }),
  ),
  srcAddress: newNft,
}

let expectedToken: Indexer.Entities.Token.t = {
  id: `${newNft->Address.toString}-7`,
  tokenId: 7n,
  collection_id: newNft->Address.toString,
  owner_id: owner->Address.toString,
}

// Validation reads the live indexing-address state, so an address registered in
// an earlier process() call is accepted by a later one.
Async.it("accepts a srcAddress registered by an earlier process() call", async t => {
  let indexer = Indexer.createTestIndexer()
  let _ = await indexer.process({
    chains: {\"1337": {startBlock: 1, endBlock: 100, simulate: [createNft]}},
  })
  let _ = await indexer.process({
    chains: {\"1337": {startBlock: 101, endBlock: 200, simulate: [transferNft]}},
  })

  let tokens = await indexer.\"Token".getAll()
  t.expect(tokens).toEqual([expectedToken])
})

// Known limitation: the pre-flight check runs before the batch, so an address a
// factory item registers in the *same* process() call isn't visible yet and the
// later item is rejected. (Validating against in-batch registrations would mean
// running the batch first.)
Async.it("rejects a srcAddress registered earlier in the same process() call", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process({
      chains: {\"1337": {startBlock: 1, endBlock: 100, simulate: [createNft, transferNft]}},
    })
    None
  } catch {
  | JsExn(err) => err->JsExn.message
  }

  t.expect(error).toEqual(
    Some(
      `simulate: SimpleNft.Transfer resolved to address ${newNft->Address.toString}, which isn't indexed on chain 1337. Provide a "srcAddress" configured or registered for SimpleNft on this chain, or use a wildcard event.`,
    ),
  )
})
