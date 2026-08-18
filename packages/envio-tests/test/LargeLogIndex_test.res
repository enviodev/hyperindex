open Vitest

// Some RPC providers return synthetic logs with a `logIndex` near the unsigned
// 32-bit limit (eg `0xfffffffc`). The Ethereum execution API defines logIndex as
// an unbounded hex quantity, so these are valid logs that must survive the whole
// pipeline. See https://github.com/ponder-sh/ponder/pull/2373 for the same class
// of bug in another indexer.
//
// ReScript's `int` is nominally 32-bit signed, so 0xfffffffc can't be written as
// a literal even though `Internal.eventItem.logIndex` carries it fine as a JS
// number at runtime.
let largeLogIndex: int = %raw(`4294967292`)

let chainId = 1->ChainId.fromInt
let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
let transactionHash = "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"
let contractAddress = "0x00000000000000000000000000000000000000AA"
let normalizedContractAddress = contractAddress->String.toLowerCase
let address = normalizedContractAddress->Address.unsafeFromString

let registration = {
  ...EventRegistration.evmOnEventRegistration(~id=sighash, ~blockFieldNames=[Number]),
  index: 0,
}

let addressStore = () =>
  TestAddresses.makeStore(
    ~onEventRegistrations=[(registration :> Internal.onEventRegistration)],
    ~addresses=[
      {address, contractName: registration.eventConfig.contractName, registrationBlock: -1},
    ],
    ~shouldChecksum=false,
  )

let syncConfig = EvmChain.getSyncConfig({
  initialBlockInterval: 1,
  accelerationAdditive: 0,
  intervalCeiling: 1,
  backoffMillis: 1,
  queryTimeoutMillis: 1_000,
})

let invoke = (source: Source.t) =>
  source.getItemsOrThrow(
    ~fromBlock=100,
    ~toBlock=Some(100),
    ~addressSet=addressStore()->AddressStore.makeSet(
      ~contractName=registration.eventConfig.contractName,
    ),
    ~knownHeight=100,
    ~partitionId="large-log-index-partition",
    ~selection={
      dependsOnAddresses: true,
      onEventRegistrations: [(registration :> Internal.onEventRegistration)],
    },
    ~itemsTarget=Some(5_000),
    ~retry=0,
    ~logger=Logging.createChild(~params={"test": "large logIndex pin"}),
  )

let block100 = JSON.parseOrThrow(
  `{"number":"0x64","timestamp":"0x64","hash":"0x0000000000000000000000000000000000000000000000000000000000000b64","parentHash":"0x0000000000000000000000000000000000000000000000000000000000000b63","gasUsed":"0x5208"}`,
)

let log = (~logIndex) =>
  JSON.parseOrThrow(
    `{"address":"${contractAddress}","topics":["${sighash}"],"data":"0x","blockNumber":"0x64","transactionHash":"${transactionHash}","transactionIndex":"0x1","blockHash":"0x0000000000000000000000000000000000000000000000000000000000000b64","logIndex":"${logIndex}","removed":false}`,
  )

describe("Large logIndex", () => {
  Async.it("pins the RPC source carrying a near-u32-max logIndex through unchanged", async t => {
    let page = await MockRpcServer.withScenario(
      ~name="large logIndex page",
      ~calls=[
        MockRpcServer.expectCall(
          ~label="logs",
          ~method="eth_getLogs",
          ~params=JSON.parseOrThrow(
            `[{"fromBlock":"0x64","toBlock":"0x64","topics":[["${sighash}"]],"address":["${normalizedContractAddress}"]}]`,
          ),
          ~reply=RpcResult(JSON.Array([log(~logIndex="0xfffffffc")])),
        ),
        MockRpcServer.expectCall(
          ~label="latest and event block",
          ~method="eth_getBlockByNumber",
          ~params=JSON.parseOrThrow(`["0x64",false]`),
          ~reply=RpcResult(block100),
        ),
      ],
      async mock => {
        let source = RpcSource.make({
          url: mock.url,
          chainId,
          onEventRegistrations: [registration],
          sourceFor: Sync,
          syncConfig,
          lowercaseAddresses: true,
          addressStore: addressStore(),
        })
        switch await RpcSourcePins.capture(() => source->invoke) {
        | Ok(page) => page
        | Error(_) => JsError.throwWithMessage("Expected the pinned RPC page to succeed")
        }
      },
    )

    t.expect(
      page.events->Array.map(event => {
        "blockNumber": event.blockNumber,
        "logIndex": event.logIndex,
        "srcAddress": event.srcAddress,
      }),
    ).toEqual([
      {
        "blockNumber": 100,
        "logIndex": largeLogIndex,
        "srcAddress": normalizedContractAddress,
      },
    ])
  })

  it("pins the raw_events event_id packing for a near-u32-max logIndex", t => {
    // `event_id` packs blockNumber into the high bits and logIndex into the low
    // 16, so any logIndex >= 65536 overflows into the block number and two
    // distinct events collide on the same id.
    t.expect({
      "packed": EventUtils.packEventIndex(
        ~blockNumber=100,
        ~logIndex=largeLogIndex,
      )->BigInt.toString,
      "collidesWithAnotherEvent": EventUtils.packEventIndex(
        ~blockNumber=100,
        ~logIndex=largeLogIndex,
      ) === EventUtils.packEventIndex(~blockNumber=65535, ~logIndex=65532),
    }).toEqual({
      "packed": "4294967292",
      "collidesWithAnotherEvent": true,
    })
  })
})

let rawEventsScenario = Scenario.make(
  ~configYaml=`
name: large-log-index
raw_events: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
  ~unsupported=[
    {backend: #memory, reason: "asserts the raw_events table's Postgres column range"},
  ],
)

let largeLogIndexRow: InternalTable.RawEvents.t = {
  chain_id: 1337->ChainId.fromInt,
  event_id: EventUtils.packEventIndex(~blockNumber=100, ~logIndex=largeLogIndex),
  contract_name: "Gravatar",
  event_name: "TestEvent",
  block_number: 100,
  log_index: largeLogIndex,
  transaction_fields: %raw(`{}`),
  src_address: normalizedContractAddress->Utils.magic,
  block_hash: "0x0000000000000000000000000000000000000000000000000000000000000b64",
  block_timestamp: 1620720000,
  block_fields: %raw(`{}`),
  params: %raw(`"null"`),
}

describe("Large logIndex - raw_events storage", () => {
  rawEventsScenario->Scenario.it(
    "pins persisting a raw event with a near-u32-max logIndex",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source as _) => {
      let {sql, pgSchema} = indexer->IndexerRunner.pgOrThrow

      let outcome = try {
        await sql->PgStorage.setOrThrow(
          ~items=[largeLogIndexRow],
          ~table=InternalTable.RawEvents.table,
          ~itemSchema=InternalTable.RawEvents.schema,
          ~pgSchema,
          ~setQueryCache=PgStorage.makeSetQueryCache(),
        )
        Ok()
      } catch {
      | exn => Error((exn->(Utils.magic: exn => {"message": string}))["message"])
      }

      // `raw_events.log_index` is INTEGER, so Postgres rejects the row with
      // "integer out of range" and the batch write kills the indexer.
      t.expect(outcome).toEqual(Error(`Failed to insert items into table "raw_events"`))
    },
  )
})
