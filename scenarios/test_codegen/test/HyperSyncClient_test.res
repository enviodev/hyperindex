open Vitest

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run HyperSyncClient tests",
  )

let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"->Address.unsafeFromString

let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let transferParams: array<Internal.paramMeta> = [
  {name: "from", abiType: "address", indexed: true},
  {name: "to", abiType: "address", indexed: true},
  {name: "value", abiType: "uint256", indexed: false},
]

let transferEventRegistration: HyperSyncClient.Registration.input = {
  index: 42,
  sighash: transferSighash,
  topicCount: 3,
  eventName: "Transfer",
  contractName: "ERC20",
  isWildcard: false,
  dependsOnAddresses: true,
  params: transferParams,
  topicSelections: [
    {
      topic0: [transferSighash],
      topic1: Some([]),
      topic2: Some([]),
      topic3: Some([]),
    },
  ],
  blockFields: ["Number", "Hash", "Timestamp"],
  transactionFields: ["Hash", "From", "To"],
}



let makeClient = (~eventRegistrations) =>
  HyperSyncClient.make(
    ~url="https://eth.hypersync.xyz",
    ~apiToken=testApiToken,
    ~httpReqTimeoutMillis=Env.hyperSyncClientTimeoutMillis,
    ~eventRegistrations,
    ~enableChecksumAddresses=false,
  )

let fromBlock = 23_500_000
let toBlock = 23_500_004

let runQuery = async (~client: HyperSyncClient.t, ~registrationIndexes=[42]) => {
  let (res, _txStore, _blockStore) = await client.getEventItems(
    ~query={
      fromBlock,
      toBlock: Some(toBlock),
      maxNumLogs: 10_000,
      registrationIndexes,
      addressesByContractName: Dict.fromArray([
        (
          "ERC20",
          [usdcAddress->Address.toString->String.toLowerCase->Address.unsafeFromString],
        ),
      ]),
    },
  )
  res
}

describe("HyperSync client getEventItems (live)", () => {
  Async.itWithOptions("returns decoded event items for a real block range", {retry: 3}, async t => {
    let client = makeClient(~eventRegistrations=[transferEventRegistration])
    let res = await runQuery(~client)

    let summary = {
      "hasItems": res.items->Array.length > 0,
      "everyItemRouted": res.items->Array.every(item => item.onEventRegistrationIndex == 42),
      "everySrcAddressIsUsdc": res.items->Array.every(item =>
        item.srcAddress->Address.toString->String.toLowerCase ==
          usdcAddress->Address.toString->String.toLowerCase
      ),
      "everyBlockInRange": res.items->Array.every(item => {
        let n = item.blockNumber
        n >= fromBlock && n <= toBlock
      }),
      "everyParamsDecoded": res.items->Array.every(item => {
        let obj = item.params->(Utils.magic: Internal.eventParams => {..})
        obj["from"]->typeof == #string &&
        obj["to"]->typeof == #string &&
        obj["value"]->typeof == #bigint
      }),
      "nextBlockPastRequest": res.nextBlock > fromBlock,
      "archiveHeightAheadOfNext": res.archiveHeight->Option.getOr(0) >= res.nextBlock,
    }

    t
      .expect(summary)
      .toEqual({
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
    let client = makeClient(~eventRegistrations=[transferEventRegistration])
    let height = await client.getHeight()

    t.expect(height > toBlock).toEqual(true)
  })

  Async.itWithOptions("drops items whose topic0 doesn't match any registered sig", {retry: 3}, async t => {
    // A wildcard registration whose topic0 is the Transfer sighash, so the
    // query fetches Transfer logs, but the decoder is only registered for an
    // unrelated 1-topic signature — every fetched log routes nowhere.
    let unrelatedEventRegistration: HyperSyncClient.Registration.input = {
      index: 0,
      sighash: "0x0000000000000000000000000000000000000000000000000000000000000001",
      topicCount: 1,
      eventName: "Unrelated",
      contractName: "Unrelated",
      isWildcard: true,
      dependsOnAddresses: false,
      params: [],
      topicSelections: [
        {
          topic0: [transferSighash],
          topic1: Some([]),
          topic2: Some([]),
          topic3: Some([]),
        },
      ],
      blockFields: [],
      transactionFields: [],
    }
    let client = makeClient(~eventRegistrations=[unrelatedEventRegistration])
    let res = await runQuery(~client, ~registrationIndexes=[0])

    t.expect(res.items->Array.length).toEqual(0)
  })
})

describe("HyperSync client getHeight with corrupted token", () => {
  // A corrupted token makes the server reply 401, so getHeight throws. The error
  // must keep matching HyperSyncSource.isUnauthorizedError, otherwise
  // getHeightOrThrow's block-forever guard silently stops working.
  Async.itWithOptions(
    "is detected by HyperSyncSource.isUnauthorizedError",
    {retry: 3, timeout: 60000},
    async t => {
      let client = HyperSyncClient.make(
        ~url="https://eth.hypersync.xyz",
        ~apiToken="this-is-a-corrupted-token",
        ~httpReqTimeoutMillis=5000,
        ~eventRegistrations=[],
        ~enableChecksumAddresses=false,
      )

      let detected = try {
        let _ = await client.getHeight()
        false
      } catch {
      | JsExn(e) => e->JsExn.message->Option.getOr("")->HyperSyncSource.isUnauthorizedError
      | _ => false
      }

      t.expect(detected).toEqual(true)
    },
  )
})

describe("HyperSync GetLogs.extractMissingParams", () => {
  it("parses the JSON payload Rust emits for MissingFields", t => {
    let jsErr =
      %raw(`(msg) => { const e = new Error(msg); return e; }`)(
        `{"kind":"MissingFields","fields":["block.timestamp","transaction.hash"]}`,
      )
    let exn = jsErr->JsExn.anyToExnInternal

    t
      .expect(HyperSync.GetLogs.extractMissingParams(exn))
      .toEqual(Some(["block.timestamp", "transaction.hash"]))
  })

  it("returns None for unrelated errors", t => {
    let exn = (%raw(`new Error("some unrelated message")`))->JsExn.anyToExnInternal

    t.expect(HyperSync.GetLogs.extractMissingParams(exn)).toEqual(None)
  })

  it("returns None when JSON parses but kind doesn't match", t => {
    let exn =
      (%raw(`(msg) => new Error(msg)`))(`{"kind":"SomethingElse","fields":["x"]}`)->JsExn.anyToExnInternal

    t.expect(HyperSync.GetLogs.extractMissingParams(exn)).toEqual(None)
  })
})
