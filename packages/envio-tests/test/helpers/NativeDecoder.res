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
): array<EvmRpcClient.rpcEventItem> => {
  // logIndex must be unique per log within the block — the client dedups a
  // page's items by (blockNumber, logIndex).
  let logJsons =
    logs->Array.mapWithIndex(((topics, data), i) => JSON.Object(
      Dict.fromArray([
        ("address", JSON.String(mockAddress)),
        ("topics", JSON.Array(topics->Array.map(t => JSON.String(t)))),
        ("data", JSON.String(data)),
        ("blockNumber", JSON.String("0x1")),
        ("transactionHash", JSON.String("0xabc")),
        ("transactionIndex", JSON.String("0x0")),
        ("blockHash", JSON.String("0xb01")),
        ("logIndex", JSON.String(`0x${i->Int.toString(~radix=16)}`)),
        ("removed", JSON.Boolean(false)),
      ]),
    ))
  await MockRpcServer.withScenario(
    ~name="native decoder logs",
    ~calls=[
      MockRpcServer.expectCall(~method="eth_getLogs", ~reply=RpcResult(JSON.Array(logJsons))),
    ],
    async mock => {
      // One entry per contract, not per registration: two events on one
      // contract are still one contract, and the store keys its ids on that.
      let contractNames =
        ContractMapping.make(
          ~names=eventRegistrations->Array.map(reg => reg.contractName),
        )->ContractMapping.names
      let addressStore = AddressStore.make(
        ~ecosystem=Ecosystem.Evm,
        ~shouldChecksum=false,
        ~contracts=contractNames->Array.map((name): AddressStore.contract => {
          name,
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
      let {items} = await client.getNextPage(
        {
          fromBlock: 0,
          toBlockCeiling: 0,
          partitionId: "0",
          registrationIndexes: eventRegistrations->Array.map(reg => reg.index),
          clientFilteredContracts: None,
        },
        addressSet,
      )
      items
    },
  )
}
