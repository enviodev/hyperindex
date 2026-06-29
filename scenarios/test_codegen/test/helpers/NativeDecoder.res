// Decodes logs through the production path: feed crafted logs to a mock
// eth_getLogs endpoint and let EvmRpcClient decode them with the shared
// DecoderCore. Returns params per log (keyed by contract name), mirroring the
// shape the old standalone decoder's decodeLogs returned.
let decodeLogs = async (
  ~eventParams: array<HyperSyncClient.Decoder.eventParamsInput>,
  ~logs: array<(array<string>, string)>,
): array<Nullable.t<dict<Internal.eventParams>>> => {
  let logJsons = logs->Array.map(((topics, data)) =>
    JSON.Object(
      Dict.fromArray([
        ("address", JSON.String("0x000000000000000000000000000000000000abcd")),
        ("topics", JSON.Array(topics->Array.map(t => JSON.String(t)))),
        ("data", JSON.String(data)),
        ("blockNumber", JSON.String("0x1")),
        ("transactionHash", JSON.String("0xabc")),
        ("transactionIndex", JSON.String("0x0")),
        ("blockHash", JSON.String("0xb01")),
        ("logIndex", JSON.String("0x0")),
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
  let client = EvmRpcClient.make(~url=mock.url, ~allEventParams=eventParams)
  let items = try await client.getLogs({fromBlock: 0, toBlock: 0, topics: []}) catch {
  | exn =>
    mock.close()
    throw(exn)
  }
  mock.close()
  items->Array.map(item => item.params)
}
