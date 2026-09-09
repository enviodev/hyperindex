open Vitest

// https://github.com/enviodev/hyperindex/issues/1187

let sharedAddress = "0x1111111111111111111111111111111111111111"
let vaultOnlyAddress = "0x2222222222222222222222222222222222222222"
let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
let depositSighash = "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
let fromAddress = "0x00000000000000000000000000000000000000aa"
let toAddress = "0x000000000000000000000000000000000000dead"
let padded = address => "0x000000000000000000000000" ++ address->String.slice(~start=2)
let uint256 = value => "0x" ++ value->Int.toString(~radix=16)->String.padStart(64, "0")
let blockHash = number => "0x" ++ number->Int.toString(~radix=16)->String.padStart(64, "b")

let parsed: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: shared-address-routing
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
  - name: Vault
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Deposit(address indexed owner, uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "${sharedAddress}"
      - name: Vault
        address:
          - "${sharedAddress}"
          - "${vaultOnlyAddress}"
`,
  ~schema=`
type Account {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "Vault", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "Vault", event: "Deposit" }, async () => {});
`,
  ~registerHandlers=true,
)

let onEventRegistrations = () => {
  let chainRegistrations: HandlerRegister.chainRegistrations =
    parsed.registrations()->Utils.Dict.dangerouslyGetNonOption("1")->Option.getOrThrow
  chainRegistrations.onEventRegistrations
}

let makeSource = (~url) => {
  let contractMapping = parsed.config.contractMapping
  let addressStore = AddressStore.make(
    ~ecosystem=Ecosystem.Evm,
    ~shouldChecksum=false,
    ~contracts=AddressStore.contractsOf(
      ~onEventRegistrations=onEventRegistrations(),
      ~contractMapping,
    ),
  )
  let chainConfig = parsed.config.chainMap->ChainMap.values->Array.getUnsafe(0)
  let _ =
    addressStore->AddressStore.seedRows(
      chainConfig
      ->ChainState.configStorageRows(~ecosystem=Evm, ~contractMapping)
      ->AddressRows.seedRowsOf,
    )
  let source = EvmHyperSyncSource.make({
    chainId: 1->ChainId.fromInt,
    endpointUrl: url,
    onEventRegistrations: onEventRegistrations()->(
      Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>
    ),
    apiToken: Some(MockHyperSyncServer.apiToken),
    clientTimeoutMillis: 10_000,
    lowercaseAddresses: true,
    serializationFormat: Json,
    enableQueryCaching: false,
    logLevel: #error,
    addressStore,
  })
  let addressSet =
    addressStore
    ->AddressStore.makeSet(~contractName="Token")
    ->AddressSet.merge(addressStore->AddressStore.makeSet(~contractName="Vault"))
  (source, addressSet)
}

let fetch = (source: Source.t, ~addressSet) =>
  source.getItemsOrThrow(
    ~fromBlock=10,
    ~toBlock=Some(10),
    ~addressSet,
    ~knownHeight=100,
    ~partitionId="mock-partition",
    ~selection={
      dependsOnAddresses: true,
      onEventRegistrations: onEventRegistrations(),
    },
    ~itemsTarget=Some(5_000),
    ~retry=0,
    ~logger=Logging.createChild(~params={"test": "shared address routing"}),
  )

let log = (~address, ~logIndex, ~topic0, ~topics=[fromAddress, toAddress]) =>
  JSON.parseOrThrow(
    `{"block_number":10,"log_index":${logIndex->Int.toString},"transaction_index":0,"address":"${address}","data":"${uint256(
        100,
      )}","topic0":"${topic0}"${topics
      ->Array.mapWithIndex((topic, idx) =>
        `,"topic${(idx + 1)->Int.toString}":"${topic->padded}"`
      )
      ->Array.joinUnsafe("")}}`,
  )

let page: MockHyperSyncServer.page = {
  blocks: [
    JSON.parseOrThrow(`{"number":10,"timestamp":1700000000,"hash":"${blockHash(10)}"}`),
  ],
  transactions: [JSON.parseOrThrow(`{"block_number":10,"transaction_index":0}`)],
  logs: [
    log(~address=sharedAddress, ~logIndex=0, ~topic0=transferSighash),
    log(~address=sharedAddress, ~logIndex=1, ~topic0=depositSighash, ~topics=[fromAddress]),
    log(~address=vaultOnlyAddress, ~logIndex=2, ~topic0=transferSighash),
  ],
}

let routed = (item: Internal.item) =>
  switch item {
  | Internal.Event(event) => {
      let payload = event.payload->Evm.toPayload
      (
        event.logIndex,
        payload.contractName,
        payload.eventName,
        payload.srcAddress->Address.toString,
      )
    }
  | Internal.Block(_) => JsError.throwWithMessage("Expected an event item")
  }

describe("An address indexed by two contracts", () => {
  Async.it("asks HyperSync for both contracts' selections", async t => {
    let queries = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse(page)
      let _ = await source->fetch(~addressSet)
      server->MockHyperSyncServer.takeQueries
    })

    t.expect(
      queries
      ->Array.map(query =>
        query
        ->JSON.Decode.object
        ->Option.getOrThrow
        ->Dict.get("logs")
        ->Option.getOrThrow
      ),
    ).toEqual([
      JSON.parseOrThrow(`[
        {
          "address": ["${sharedAddress}"],
          "topics": [["${transferSighash}"], [], [], []]
        },
        {
          "address": ["${sharedAddress}", "${vaultOnlyAddress}"],
          "topics": [["${transferSighash}", "${depositSighash}"], [], [], []]
        }
      ]`),
    ])
  })

  Async.it("routes one log to every contract that declares it", async t => {
    let items = await MockHyperSyncServer.withServer(~height=100, async server => {
      let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
      server->MockHyperSyncServer.pushResponse(page)
      let page = await source->fetch(~addressSet)
      page.parsedQueueItems
    })

    t.expect(items->Array.map(routed)).toEqual([
      (0, "Token", "Transfer", sharedAddress),
      (0, "Vault", "Transfer", sharedAddress),
      (1, "Vault", "Deposit", sharedAddress),
      (2, "Vault", "Transfer", vaultOnlyAddress),
    ])
  })
})
