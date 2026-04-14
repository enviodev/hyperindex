@get external getNumber: Internal.eventBlock => int = "height"
@get external getTimestamp: Internal.eventBlock => int = "time"
@get external getId: Internal.eventBlock => string = "hash"

let cleanUpRawEventFieldsInPlace: Js.Json.t => unit = %raw(`fields => {
    delete fields.hash
    delete fields.height
    delete fields.time
  }`)

let ecosystem: Ecosystem.t = {
  name: Svm,
  blockFields: ["slot"],
  transactionFields: [],
  blockNumberName: "height",
  blockTimestampName: "time",
  blockHashName: "hash",
  getNumber,
  getTimestamp,
  getId,
  cleanUpRawEventFieldsInPlace,
  onBlockMethodName: "onSlot",
  // SVM filter shape: `{slot: {_gte?, _lte?, _every?}}`.
  extractOnBlockNumberFilter: filter =>
    filter->(Utils.magic: unknown => {"slot": option<unknown>})->(r => r["slot"]),
}

module GetFinalizedSlot = {
  let route = Rpc.makeRpcRoute(
    "getSlot",
    S.tuple(s => {
      s.tag(0, {"commitment": "finalized"})
      ()
    }),
    S.int,
  )
}

let makeRPCSource = (~chain, ~rpc: string): Source.t => {
  let client = Rest.client(rpc)
  let chainId = chain->ChainMap.Chain.toChainId

  let urlHost = switch Utils.Url.getHostFromUrl(rpc) {
  | None =>
    Js.Exn.raiseError(
      `The RPC url for chain ${chainId->Belt.Int.toString} is in incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  {
    name,
    sourceFor: Sync,
    chain,
    poweredByHyperSync: false,
    pollingInterval: 10_000,
    getBlockHashes: (~blockNumbers as _, ~logger as _) =>
      Js.Exn.raiseError("Svm does not support getting block hashes"),
    getHeightOrThrow: async () => {
      let timerRef = Hrtime.makeTimer()
      let height = await GetFinalizedSlot.route->Rest.fetch((), ~client)
      let seconds = timerRef->Hrtime.timeSince->Hrtime.toSecondsFloat
      Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId, ~method="getSlot")
      Prometheus.SourceRequestCount.addSeconds(
        ~sourceName=name,
        ~chainId,
        ~method="getSlot",
        ~seconds,
      )
      height
    },
    getItemsOrThrow: (
      ~fromBlock as _,
      ~toBlock as _,
      ~addressesByContractName as _,
      ~indexingContracts as _,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection as _,
      ~retry as _,
      ~logger as _,
    ) => Js.Exn.raiseError("Svm does not support getting items"),
  }
}
