// The fixed address every crafted log is emitted from; register it for a
// contract via `~ownedBy` to route logs to that contract's non-wildcard
// registrations.
let mockAddress = "0x000000000000000000000000000000000000abcd"

// Decodes logs through the production path: feed crafted logs to a mock
// eth_getLogs endpoint and let EvmRpcClient route+decode them with the shared
// DecoderCore. Returns only the routed items, each carrying its registration
// id and flat decoded params.
let decodeLogs = async (
  ~eventRegistrations: array<HyperSyncClient.Registration.input>,
  ~logs: array<(array<string>, string)>,
  // Contract that owns `mockAddress`, if any. Without one the emitter is
  // unregistered and only wildcard registrations route.
  ~ownedBy: option<string>=?,
): array<EvmRpcClient.eventItem> => {
  // logIndex must be unique per log within the block — the client dedups a
  // page's items by (blockNumber, logIndex).
  let logJsons =
    logs->Array.mapWithIndex(((topics, data), i) => JSON.Object(
      Dict.fromArray([
        ("address", JSON.String(mockAddress)),
        ("topics", JSON.Array(topics->Array.map(t => JSON.String(t)))),
        ("data", JSON.String(data)),
        ("blockNumber", JSON.String("0x1")),
        (
          "transactionHash",
          JSON.String("0x0000000000000000000000000000000000000000000000000000000000000abc"),
        ),
        ("transactionIndex", JSON.String("0x0")),
        (
          "blockHash",
          JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b01"),
        ),
        ("logIndex", JSON.String(`0x${i->Int.toString(~radix=16)}`)),
        ("removed", JSON.Boolean(false)),
      ]),
    ))
  // The page always fetches its `toBlock` block for the reorg-guard hash.
  let toBlockJson = JSON.Object(
    Dict.fromArray([
      ("number", JSON.String("0x0")),
      ("timestamp", JSON.String("0x1")),
      ("hash", JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b00")),
      (
        "parentHash",
        JSON.String("0x0000000000000000000000000000000000000000000000000000000000000aff"),
      ),
    ]),
  )
  await MockRpcServer.withScenario(
    ~name="native decoder logs",
    ~calls=[
      MockRpcServer.expectCall(~method="eth_getLogs", ~reply=RpcResult(JSON.Array(logJsons))),
      MockRpcServer.expectCall(~method="eth_getBlockByNumber", ~reply=RpcResult(toBlockJson)),
    ],
    async mock => {
      let addressStore = AddressStore.make(
        ~ecosystem=Ecosystem.Evm,
        ~shouldChecksum=false,
        ~contracts=eventRegistrations->Array.map((reg): AddressStore.contract => {
          name: reg.contractName,
          startBlock: None,
          dependsOnAddresses: true,
        }),
      )
      let addressSet = switch ownedBy {
      | None => addressStore->AddressStore.emptySet
      | Some(contractName) =>
        let _ = addressStore->AddressStore.seedBatch([
          {
            address: mockAddress->Address.unsafeFromString,
            contractName,
            registrationBlock: -1,
          },
        ])
        addressStore->AddressStore.makeSet(~contractName)
      }
      let client = EvmRpcClient.make(
        ~url=mock.url,
        ~checksumAddresses=false,
        ~syncConfig=EvmChain.getSyncConfig({}),
        ~eventRegistrations,
        ~addressStore,
      )
      let (page, _, _) = await client.getNextPage(
        {
          fromBlock: 0,
          toBlockCeiling: 0,
          partitionId: "0",
          registrationIndexes: eventRegistrations->Array.map(reg => reg.index),
          clientFilteredContracts: None,
        },
        addressSet,
      )
      page.items
    },
  )
}
