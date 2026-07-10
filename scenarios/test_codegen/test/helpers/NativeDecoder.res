// The fixed address every crafted log is emitted from; map it in
// `contractNameByAddress` to route logs to a non-wildcard registration.
let mockAddress = "0x000000000000000000000000000000000000abcd"

// Decodes logs through the production path: feed crafted logs to a mock
// eth_getLogs endpoint and let EvmRpcClient route+decode them with the shared
// DecoderCore. Returns only the routed items, each carrying its registration
// id and flat decoded params.
let decodeLogs = async (
  ~eventRegistrations: array<HyperSyncClient.Registration.input>,
  ~logs: array<(array<string>, string)>,
  ~contractNameByAddress=Dict.make(),
): array<EvmRpcClient.rpcEventItem> => {
  // logIndex must be unique per log within the block — the client dedups a
  // page's items by (blockNumber, logIndex).
  let logJsons = logs->Array.mapWithIndex(((topics, data), i) =>
    JSON.Object(
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
    )
  )
  let mock = await MockRpcServer.make(~getResult=method =>
    switch method {
    | "eth_getLogs" => JSON.Array(logJsons)
    | _ => JSON.Null
    }
  )
  let client = EvmRpcClient.make(
    ~url=mock.url,
    ~checksumAddresses=false,
    ~syncConfig=EvmChain.getSyncConfig({}),
    ~eventRegistrations,
  )
  // Invert the routing index back into the address form the client expects.
  let addressesByContractName = Dict.make()
  contractNameByAddress->Dict.forEachWithKey((contractName, address) => {
    addressesByContractName->Utils.Dict.push(
      contractName,
      address->Address.unsafeFromString,
    )
  })
  let {items} = try await client.getNextPage({
    fromBlock: 0,
    toBlockCeiling: 0,
    partitionId: "0",
    registrationIndexes: eventRegistrations->Array.map(reg => reg.index),
    addressesByContractName,
  }) catch {
  | exn =>
    mock.close()
    throw(exn)
  }
  mock.close()
  items
}
