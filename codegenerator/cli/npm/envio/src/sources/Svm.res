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
      `EE109: The RPC url "${rpc}" is incorrect format. The RPC url needs to start with either http:// or https://`,
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
    getHeightOrThrow: () => {
      Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId)
      GetFinalizedSlot.route->Rest.fetch((), ~client)
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
