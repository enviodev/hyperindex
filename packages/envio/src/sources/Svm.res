let cleanUpRawEventFieldsInPlace: JSON.t => unit = %raw(`fields => {
    delete fields.hash
    delete fields.height
    delete fields.time
  }`)

// Ordered transaction field names, the field codes shared with the Rust store
// (`SvmTxField`). Derived from the typed field list so the two can't drift;
// `Internal.allSvmTransactionFields` is pinned to the Rust ordinal order by a test.
let transactionFields =
  Internal.allSvmTransactionFields->(
    Utils.magic: array<Internal.svmTransactionField> => array<string>
  )

// One instruction's selected transaction fields → store selection bitmask.
// Computed per event at config build and cached on the event config.
let eventTransactionFieldMask = TransactionStore.makeMaskFn(transactionFields)

let make = (~logger: Pino.t): Ecosystem.t => {
  name: Svm,
  blockNumberName: "height",
  blockTimestampName: "time",
  blockHashName: "hash",
  cleanUpRawEventFieldsInPlace,
  onBlockMethodName: "onSlot",
  // SVM filter shape: `{slot: {_gte?, _lte?, _every?}}`.
  // Inner range chunk parsed by `blockRangeSchema` in `Main.res`.
  onBlockFilterSchema: S.object(s => s.field("slot", S.option(S.unknown))),
  // SVM has no event handlers, so there is no `onEvent` `where` value to
  // parse. The schema is a no-op object that always surfaces `None`.
  onEventBlockFilterSchema: S.object(_ => None),
  logger,
  toEvent: eventItem => eventItem.payload->(Utils.magic: Internal.eventPayload => Internal.event),
  toEventLogger: eventItem => {
    let instruction =
      eventItem.payload->(Utils.magic: Internal.eventPayload => Envio.svmInstruction)
    Logging.createChildFrom(
      ~logger,
      ~params={
        "program": eventItem.onEventRegistration.eventConfig.contractName,
        "instruction": eventItem.onEventRegistration.eventConfig.name,
        "chainId": eventItem.chain->ChainMap.Chain.toChainId,
        "slot": eventItem.blockNumber,
        "programId": instruction.programId,
      },
    )
  },
  toRawEvent: _ => JsError.throwWithMessage("Raw events are not supported for SVM"),
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

let makeRPCSource = (~chain, ~rpc: string, ~sourceFor: Source.sourceFor=Sync): Source.t => {
  let client = Rest.client(rpc)
  let chainId = chain->ChainMap.Chain.toChainId

  let urlHost = switch Utils.Url.getHostFromUrl(rpc) {
  | None =>
    JsError.throwWithMessage(
      `The RPC url for chain ${chainId->Int.toString} is in incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  {
    name,
    sourceFor,
    chain,
    poweredByHyperSync: false,
    pollingInterval: 10_000,
    getBlockHashes: (~blockNumbers as _, ~logger as _) =>
      JsError.throwWithMessage("Svm does not support getting block hashes"),
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = await GetFinalizedSlot.route->Rest.fetch((), ~client)
      let seconds = timerRef->Performance.secondsSince
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
      ~contractNameByAddress as _,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection as _,
      ~retry as _,
      ~logger as _,
    ) => JsError.throwWithMessage("Svm does not support getting items"),
  }
}
