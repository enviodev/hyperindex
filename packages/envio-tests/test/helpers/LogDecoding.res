// The fixed address every crafted log is emitted from; register it for a
// contract via `~ownedBy` to route logs to that contract's non-wildcard
// registrations.
let mockAddress = "0x000000000000000000000000000000000000abcd"

// A selection naming registrations by index, which is all a source reads
// off it.
let selectionOf = (registrationIndexes: array<int>): FetchState.selection => {
  dependsOnAddresses: true,
  onEventRegistrations: registrationIndexes->Array.map(index =>
    {"index": index}->(Utils.magic: {"index": int} => Internal.onEventRegistration)
  ),
  onBlockRegistrations: [],
  onTransactionRegistrations: [],
}

// Decodes logs through the production path: feed crafted logs to a mock
// eth_getLogs endpoint, let the RPC source keep the ones some registration
// matches, and build them from a chain buffer the way a batch does. Returns
// one item per matching registration, carrying its id and flat decoded params.
let decodeLogs = async (
  ~eventRegistrations: array<ChainRegistrations.Evm.input>,
  ~logs: array<(array<string>, string)>,
  // Contract that owns `mockAddress`, if any. Without one the emitter is
  // unregistered and only wildcard registrations route.
  ~ownedBy: option<string>=?,
): array<TestChainBuffer.evmLog> => {
  // logIndex must be unique per log within the block — the buffer keys a log
  // by (blockNumber, logIndex).
  let logJsons =
    logs->Array.mapWithIndex(((topics, data), i) => JSON.Object(
      Dict.fromArray([
        ("address", JSON.String(mockAddress)),
        ("topics", JSON.Array(topics->Array.map(t => JSON.String(t)))),
        ("data", JSON.String(data)),
        ("blockNumber", JSON.String("0x1")),
        (
          "transactionHash",
          JSON.String("0xabababababababababababababababababababababababababababababababab"),
        ),
        ("transactionIndex", JSON.String("0x0")),
        (
          "blockHash",
          JSON.String("0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"),
        ),
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
      let addressStore = TestAddresses.storeOf(
        ~contracts=contractNames->Array.map((name): AddressStore.contract => {
          name,
          startBlock: None,
          dependsOnAddresses: true,
        }),
        ~addresses=switch ownedBy {
        | None => []
        | Some(contractName) => [
            {
              address: mockAddress->Address.unsafeFromString,
              contractName,
              registrationBlock: -1,
            },
          ]
        },
      )
      let addressSet = switch ownedBy {
      | None => addressStore->AddressStore.emptySet
      | Some(contractName) => addressStore->AddressStore.makeSet(~contractName)
      }
      let source = TestSources.rpc(
        ~url=mock.url,
        ~chainBuffer=TestChainBuffer.forInputs(~evmRegistrations=eventRegistrations, ~addressStore),
      )
      let outcome = await source.getItems(
        ~fromBlock=0,
        ~toBlock=Some(0),
        ~addressSet,
        ~reorgableFrom=None,
        // Far below the head, where a page's blocks aren't checked one by one.
        ~knownHeight=1_000,
        ~partitionId="0",
        ~selection=selectionOf(eventRegistrations->Array.map(reg => reg.index)),
        ~retry=0,
      )
      switch outcome.result {
      | Ok({page}) =>
        await page->TestChainBuffer.evmLogsOf(~registrations=eventRegistrations, ~addressStore)
      | Error(failure) => JsError.throwWithMessage(failure->Source.failureMessage)
      }
    },
  )
}
