open Vitest

// NftFactory.SimpleNftCreated's contractRegister adds the emitted
// `contractAddress` as a SimpleNft; SimpleNft.Transfer is a non-wildcard event
// for that dynamically-registered contract (SimpleNft has no configured address).
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

let expectedCollection: Indexer.Entities.NftCollection.t = {
  id: newNft->Address.toString,
  contractAddress: newNft->Address.toString,
  name: "n",
  symbol: "s",
  maxSupply: 0n,
  currentSupply: 0,
}

// SimpleNft has no configured address; it's registered dynamically by
// NftFactory.SimpleNftCreated. A non-wildcard SimpleNft.Transfer for an address
// registered in an earlier process() call routes to the handler unchanged.
Async.it("routes a non-wildcard event for a contract registered in an earlier process() call", async t => {
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

// A contract registered within the same process() call is accepted too: the
// simulate path no longer pre-checks srcAddress against a static snapshot, so the
// non-wildcard event reaches its handler instead of being rejected.
Async.it("accepts a non-wildcard event for a contract registered in the same process() call", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process({
      chains: {\"1337": {startBlock: 1, endBlock: 100, simulate: [createNft, transferNft]}},
    })
    None
  } catch {
  | JsExn(err) => err->JsExn.message
  }

  t.expect(error).toEqual(None)
})

// Regression: an explicit logIndex on the first item must not steal the auto
// item's slot. [explicit 0, auto] resolves to logIndex 0 then 1 (not two zeros),
// so createNft registers newNft before transferNft routes and the token lands.
Async.it("accepts an explicit logIndex followed by an auto-increment item", async t => {
  let indexer = Indexer.createTestIndexer()
  let _ = await indexer.process({
    chains: {
      \"1337": {startBlock: 1, endBlock: 100, simulate: [{...createNft, logIndex: 0}, transferNft]},
    },
  })

  let tokens = await indexer.\"Token".getAll()
  t.expect(tokens).toEqual([expectedToken])
})

// With nothing registering newNft (no factory item, no earlier process() call),
// the address filter drops the non-wildcard Transfer and its handler never runs.
// The run reports the dead simulate input instead of passing silently.
Async.it("reports a non-wildcard simulate item whose srcAddress is never indexed", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process({
      chains: {\"1337": {startBlock: 1, endBlock: 100, simulate: [transferNft]}},
    })
    None
  } catch {
  | JsExn(err) => err->JsExn.message
  }

  t.expect(error).toEqual(
    Some(
      `simulate: 1 item you passed to simulate never reached a handler, so nothing ran for them. Each was filtered out before the handler — usually a non-wildcard srcAddress that isn't indexed for the contract, or a where/block filter that excluded the event. Unrouted items, by index in each chain's simulate array:` ++ "\n  - chain 1337: 0",
    ),
  )
})

// config.yaml stores NftFactory's address checksummed; a simulate srcAddress in a
// different casing (here lowercase) must still route the non-wildcard
// SimpleNftCreated event. Before normalization the raw string compare dropped it,
// leaving no way to construct a mixed-case routable address for simulate.
Async.it("routes a simulate event whose srcAddress casing differs from the configured address", async t => {
  let indexer = Indexer.createTestIndexer()
  let _ = await indexer.process({
    chains: {
      \"1337": {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          {
            ...createNft,
            srcAddress: Address.unsafeFromString("0xa2f6e6029638ccb484a2ccb6414499ad3e825cac"),
          },
        ],
      },
    },
  })

  let collections = await indexer.\"NftCollection".getAll()
  t.expect(collections).toEqual([expectedCollection])
})

// An address with an invalid EIP-55 checksum (here all-uppercase hex) is still
// a valid 20-byte address — normalization recomputes its checksum rather than
// requiring the input to already carry the correct one, so it still routes.
Async.it("routes a simulate event whose srcAddress has an invalid checksum casing", async t => {
  let indexer = Indexer.createTestIndexer()
  let _ = await indexer.process({
    chains: {
      \"1337": {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          {
            ...createNft,
            srcAddress: Address.unsafeFromString("0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC"),
          },
        ],
      },
    },
  })

  let collections = await indexer.\"NftCollection".getAll()
  t.expect(collections).toEqual([expectedCollection])
})

// Two items resolving to the same (block, logIndex) is an ambiguous input that
// the dead-input tracker and event ordering both key on — rejected at parse.
Async.it("rejects simulate items that resolve to the same block and logIndex", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process({
      chains: {
        \"1337": {
          startBlock: 1,
          endBlock: 100,
          simulate: [{...createNft, logIndex: 0}, {...transferNft, logIndex: 0}],
        },
      },
    })
    None
  } catch {
  | JsExn(err) => err->JsExn.message
  }

  t.expect(error).toEqual(
    Some(
      `simulate: items at index 0 and 1 on chain 1337 both resolve to block 1, logIndex 0. Give each item a distinct logIndex (or omit logIndex so they auto-increment).`,
    ),
  )
})
