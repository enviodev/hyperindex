// Decodes logs through the production path: feed crafted logs to a mock
// eth_getLogs endpoint and let EvmRpcClient decode them with the shared
// DecoderCore. Returns params per log (keyed by contract name), mirroring the
// shape the old standalone decoder's decodeLogs returned.
let decodeLogs = async (
  ~eventParams: array<HyperSyncClient.Decoder.eventParamsInput>,
  ~logs: array<(array<string>, string)>,
): array<Nullable.t<dict<Internal.eventParams>>> => {
  // logIndex must be unique per log within the block — the client dedups a
  // page's items by (blockNumber, logIndex).
  let logJsons = logs->Array.mapWithIndex(((topics, data), i) =>
    JSON.Object(
      Dict.fromArray([
        ("address", JSON.String("0x000000000000000000000000000000000000abcd")),
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
  await MockRpcServer.withScenario(
    ~name="native decoder logs",
    ~calls=[
      MockRpcServer.expectCall(
        ~method="eth_getLogs",
        ~params=JSON.parseOrThrow(`[{"fromBlock":"0x0","toBlock":"0x0","topics":[]}]`),
        ~reply=RpcResult(JSON.Array(logJsons)),
      ),
    ],
    async mock => {
      let client = EvmRpcClient.make(
        ~url=mock.url,
        ~checksumAddresses=false,
        ~syncConfig=EvmChain.getSyncConfig({}),
        ~allEventParams=eventParams,
      )
      let {items} = await client.getNextPage({
        fromBlock: 0,
        toBlockCeiling: 0,
        logSelections: [{topics: []}],
        partitionId: "0",
      })
      items->Array.map(item => item.params)
    },
  )
}
