open Vitest

// https://github.com/enviodev/hyperindex/issues/990

@module("viem")
external encodeAbiParameters: (JSON.t, JSON.t) => string = "encodeAbiParameters"

let contractAddress = "0x1111111111111111111111111111111111111111"
// DSNote's anonymous LogNote puts the called function's selector in topic0,
// so `file(bytes32,uint256)` notes all share this topic0.
let fileTopic0 = "0x29ae811400000000000000000000000000000000000000000000000000000000"
let otherTopic0 = "0xa9059cbb00000000000000000000000000000000000000000000000000000000"
let guy = "0x00000000000000000000000000000000000000aa"
let foo = "0x00000000000000000000000000000000000000000000000000000000000000bb"
let bar = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
let padded = address => "0x000000000000000000000000" ++ address->String.slice(~start=2)
let blockHash = number => "0x" ++ number->Int.toString(~radix=16)->String.padStart(64, "b")

let configYaml = (~topic0) =>
  `
name: event-topic0
contracts:
  - name: Noted
    events:
      - event: LogNote(address indexed guy, bytes32 indexed foo, bytes32 indexed bar, uint256 wad, bytes fax)
        name: File
        topic0: "${topic0}"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Noted
        address: "${contractAddress}"
`

let parsed: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=configYaml(~topic0=fileTopic0),
  ~schema=`
type Account {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Noted", event: "File" }, async () => {});
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
    ~contracts=AddressStore.contractsOf(
      ~onEventRegistrations=onEventRegistrations(),
      ~contractMapping,
    ),
  )
  let chainConfig = parsed.config.chainMap->ChainMap.values->Array.getUnsafe(0)
  let _ = addressStore->AddressStore.seedRows(
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
  (source, addressStore->AddressStore.makeSet(~contractName="Noted"))
}

let fetch = (source: Source.t, ~addressSet) =>
  source.getItemsOrThrow(
    ~includeAllBlocks=false,
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
    ~logger=Logging.createChild(~params={"test": "event topic0"}),
  )

let noteData = encodeAbiParameters(
  %raw(`[{"type":"uint256"},{"type":"bytes"}]`),
  %raw(`[0n,"0x1234"]`),
)

let noteLog = (~logIndex, ~topic0) =>
  JSON.parseOrThrow(
    `{"block_number":10,"log_index":${logIndex->Int.toString},"transaction_index":0,"address":"${contractAddress}","data":"${noteData}","topic0":"${topic0}","topic1":"${guy->padded}","topic2":"${foo}","topic3":"${bar}"}`,
  )

let page: MockHyperSyncServer.page = {
  blocks: [JSON.parseOrThrow(`{"number":10,"timestamp":1700000000,"hash":"${blockHash(10)}"}`)],
  transactions: [JSON.parseOrThrow(`{"block_number":10,"transaction_index":0}`)],
  logs: [noteLog(~logIndex=0, ~topic0=fileTopic0), noteLog(~logIndex=1, ~topic0=otherTopic0)],
}

type noteParams = {guy: string, foo: string, bar: string, wad: bigint, fax: string}

let decoded = (item: Internal.item) =>
  switch item {
  | Internal.Event(event) => {
      let payload = event.payload->Evm.toPayload
      (
        event.logIndex,
        payload.eventName,
        payload.params->(Utils.magic: Internal.eventParams => noteParams),
      )
    }
  | Internal.Block(_) => JsError.throwWithMessage("Expected an event item")
  }

describe("An event with a configured topic0", () => {
  Async.it("is fetched and decoded by that topic0", async t => {
    let (queries, items) = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let (source, addressSet) = makeSource(~url=server->MockHyperSyncServer.url)
        server->MockHyperSyncServer.pushResponse(page)
        let page = await source->fetch(~addressSet)
        (server->MockHyperSyncServer.takeQueries, page.parsedQueueItems)
      },
    )

    t.expect((
      queries->Array.map(
        query => query->JSON.Decode.object->Option.getOrThrow->Dict.get("logs")->Option.getOrThrow,
      ),
      items->Array.map(decoded),
    )).toEqual((
      [
        JSON.parseOrThrow(
          `[
          {
            "address": ["${contractAddress}"],
            "topics": [["${fileTopic0}"], [], [], []]
          }
        ]`,
        ),
      ],
      [(0, "File", {guy, foo, bar, wad: 0n, fax: "0x1234"})],
    ))
  })

  it("rejects a topic0 that isn't 32 bytes", t =>
    t->toThrowErrorEqual(
      () => InternalTestIndexer.fromUserApi(~configYaml=configYaml(~topic0="0x29ae8114")),
      `Failed parsing abi types for events in global contract Noted: Invalid topic0 "0x29ae8114" for event File. Expected 0x followed by 64 hex characters.`,
    )
  )
})
