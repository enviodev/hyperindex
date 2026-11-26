open Vitest

let testApiToken =
  IndexerEnv.read().envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run HyperSyncClient tests",
  )

let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"->Address.unsafeFromString

let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let transferParams: array<Internal.paramMeta> = [
  {name: "from", abiType: "address", indexed: true},
  {name: "to", abiType: "address", indexed: true},
  {name: "value", abiType: "uint256", indexed: false},
]

let transferEventRegistration: ChainRegistrations.Evm.input = {
  index: 42,
  sighash: Some(transferSighash),
  topicCount: 3,
  eventName: "Transfer",
  contractName: "ERC20",
  isWildcard: false,
  dependsOnAddresses: true,
  startBlock: None,
  params: transferParams,
  topicFilters: [
    {
      topic0: Some([transferSighash]),
      topic1: Some([]),
      topic2: Some([]),
      topic3: Some([]),
    },
  ],
  blockFields: ["Number", "Hash", "Timestamp"],
  transactionFields: ["Hash", "From", "To"],
}

// The chain's address index, with USDC registered for ERC20 from block 0 —
// the client builds the query's address filter from a set of it and gates every
// returned log against it.
let addressStore = TestAddresses.storeOf(
  ~contracts=[
    {name: "ERC20", startBlock: None, dependsOnAddresses: true},
    {name: "Unrelated", startBlock: None, dependsOnAddresses: true},
  ],
  ~addresses=[{address: usdcAddress, contractName: "ERC20", registrationBlock: -1}],
)
let usdcSet = addressStore->AddressStore.makeSet(~contractName="ERC20")

let makeSource = (~eventRegistrations, ~apiToken=testApiToken) =>
  TestSources.hyperSync(
    ~url="https://eth.hypersync.xyz",
    ~apiToken=Some(apiToken),
    ~chainBuffer=TestChainBuffer.forInputs(~evmRegistrations=eventRegistrations, ~addressStore),
  )

let fromBlock = 23_500_000
let toBlock = 23_500_004

// The source keeps the logs some registration matches; a buffer decodes them.
let runQuery = async (
  ~source: Source.t,
  ~registrationIndexes=[42],
  ~eventRegistrations=[transferEventRegistration],
) => {
  let {result} = await source.getItems(
    ~fromBlock,
    ~toBlock=Some(toBlock),
    ~addressSet=usdcSet,
    ~reorgableFrom=None,
    ~knownHeight=toBlock,
    ~partitionId="0",
    ~selection=NativeDecoder.selectionOf(registrationIndexes),
    ~retry=0,
  )
  switch result {
  | Ok(itemsPage) =>
    Ok((
      itemsPage,
      await itemsPage.page->TestChainBuffer.evmLogsOf(
        ~registrations=eventRegistrations,
        ~addressStore,
      ),
    ))
  | Error(failure) => Error(failure)
  }
}

let runQueryOrThrow = async (~source, ~registrationIndexes=?, ~eventRegistrations=?) =>
  switch await runQuery(~source, ~registrationIndexes?, ~eventRegistrations?) {
  | Ok(page) => page
  | Error(failure) => JsError.throwWithMessage(failure->Source.failureMessage)
  }

describe("HyperSync client getItems (live)", () => {
  Async.itWithOptions("returns decoded event items for a real block range", {retry: 3}, async t => {
    let source = makeSource(~eventRegistrations=[transferEventRegistration])
    let (itemsPage: Source.itemsPage, eventItems) = await runQueryOrThrow(~source)
    let {latestFetchedBlockNumber, knownHeight} = itemsPage

    let summary = {
      "hasItems": eventItems->Array.length > 0,
      "everyItemRouted": eventItems->Array.every(item => item.onEventRegistrationIndex == 42),
      "everySrcAddressIsUsdc": eventItems->Array.every(
        item =>
          item.srcAddress->Address.toString->String.toLowerCase ==
            usdcAddress->Address.toString->String.toLowerCase,
      ),
      "everyBlockInRange": eventItems->Array.every(
        item => {
          let n = item.blockNumber
          n >= fromBlock && n <= toBlock
        },
      ),
      "everyParamsDecoded": eventItems->Array.every(
        item => {
          let obj = item.params->(Utils.magic: Internal.eventParams => {..})
          obj["from"]->typeof == #string &&
          obj["to"]->typeof == #string &&
          obj["value"]->typeof == #bigint
        },
      ),
      "nextBlockPastRequest": latestFetchedBlockNumber >= fromBlock,
      "archiveHeightAheadOfNext": knownHeight->Option.getOr(0) > latestFetchedBlockNumber,
    }

    t.expect(summary).toEqual({
      "hasItems": true,
      "everyItemRouted": true,
      "everySrcAddressIsUsdc": true,
      "everyBlockInRange": true,
      "everyParamsDecoded": true,
      "nextBlockPastRequest": true,
      "archiveHeightAheadOfNext": true,
    })
  })

  Async.itWithOptions("getHeight returns a height past the queried range", {retry: 3}, async t => {
    let source = makeSource(~eventRegistrations=[transferEventRegistration])
    let {result} = await source.getHeight()

    t.expect(result->Result.map(height => height > toBlock)).toEqual(Ok(true))
  })

  Async.itWithOptions(
    "drops items whose topic0 doesn't match any registered sig",
    {retry: 3},
    async t => {
      // A wildcard registration whose topic0 is the Transfer sighash, so the
      // query fetches Transfer logs, but the decoder is only registered for an
      // unrelated 1-topic signature — every fetched log routes nowhere.
      let unrelatedEventRegistration: ChainRegistrations.Evm.input = {
        index: 0,
        sighash: Some("0x0000000000000000000000000000000000000000000000000000000000000001"),
        topicCount: 1,
        eventName: "Unrelated",
        contractName: "Unrelated",
        isWildcard: true,
        dependsOnAddresses: false,
        startBlock: None,
        params: [],
        topicFilters: [
          {
            topic0: Some([transferSighash]),
            topic1: Some([]),
            topic2: Some([]),
            topic3: Some([]),
          },
        ],
        blockFields: [],
        transactionFields: [],
      }
      let source = makeSource(~eventRegistrations=[unrelatedEventRegistration])
      let (_, eventItems) = await runQueryOrThrow(
        ~source,
        ~registrationIndexes=[0],
        ~eventRegistrations=[unrelatedEventRegistration],
      )

      t.expect(eventItems->Array.length).toEqual(0)
    },
  )
})

describe("HyperSync client with corrupted token", () => {
  let makeCorruptedTokenSource = () =>
    makeSource(
      ~eventRegistrations=[transferEventRegistration],
      ~apiToken="this-is-a-corrupted-token",
    )

  Async.it("getHeight doesn't validate the token", async t => {
    // The edge deliberately stopped rejecting malformed tokens on /height and
    // the height SSE endpoints, so a token issue can't stall an indexer that
    // only polls the height. If that ever regresses, getHeight reports the 401
    // once and then retries it forever.
    let {result} = await makeCorruptedTokenSource().getHeight()

    t.expect(result->Result.map(height => height > 0)).toEqual(Ok(true))
  })

  Async.it("query error carries the 401 the unauthorized warning looks for", async t => {
    // The query endpoint still replies 401. The source recognises a rejected
    // token by that text, so pin it on the real server's answer.
    let detected = switch await runQuery(~source=makeCorruptedTokenSource()) {
    | Error(Backoff({cause})) => cause->String.includes("401 Unauthorized")
    | _ => false
    }

    t.expect(detected).toEqual(true)
  })
})
