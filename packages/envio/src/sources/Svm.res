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

// Ordered block field names. The index of each is the field code shared with the
// Rust store (`SvmBlockField`) — keep this order in sync.
let blockFields = ["slot", "time", "hash", "height", "parentSlot", "parentHash"]

// `slot` is always included (the item's key); every other block field is
// opt-in via handler `fields.block`. All are materialised from the store.
//
// One instruction's selected block fields → store selection bitmask. Computed per
// event at config build and cached on the event config.
let eventBlockFieldMask = BlockStore.makeMaskFn(blockFields)

let attachAccountActivities = (payload: Internal.eventPayload, tx: Internal.eventTransaction) => {
  let instruction = payload->(Utils.magic: Internal.eventPayload => dict<unknown>)
  let transaction = tx->(Utils.magic: Internal.eventTransaction => dict<unknown>)
  switch (instruction->Dict.get("accounts"), transaction->Dict.get("accountActivities")) {
  | (Some(accounts), Some(activities)) if !(accounts->Array.isArray) =>
    let byAddress = Dict.make()
    (activities->(Utils.magic: unknown => array<Envio.svmAccountActivity>))->Array.forEach(
      activity => byAddress->Dict.set(activity.address->SvmTypes.Pubkey.toString, activity),
    )
    (accounts->(Utils.magic: unknown => dict<Envio.svmInstructionAccount>))
    ->Dict.valuesToArray
    ->Array.forEach(account =>
      switch byAddress->Dict.get(account.address->SvmTypes.Pubkey.toString) {
      | Some(activity) =>
        (account->(Utils.magic: Envio.svmInstructionAccount => dict<unknown>))->Dict.set(
          "activity",
          activity->(Utils.magic: Envio.svmAccountActivity => unknown),
        )
      | None => ()
      }
    )
  | _ => ()
  }
}

let make = (~logger: Pino.t): Ecosystem.t => {
  name: Svm,
  blockNumberName: "height",
  blockTimestampName: "time",
  blockHashName: "hash",
  onBlockMethodName: "onSlot",
  contractNoun: "program",
  eventNoun: "instruction",
  // SVM filter shape: `{slot: {_gte?, _lte?, _every?}}`.
  // Inner range chunk parsed by `blockRangeSchema` in `Main.res`.
  onBlockFilterSchema: S.object(s => s.field("slot", S.option(S.unknown))),
  // SVM has no event handlers, so there is no `onEvent` `where` value to
  // parse. The schema is a no-op object that always surfaces `None`.
  onEventBlockFilterSchema: S.object(_ => None),
  logger,
  toEvent: eventItem => eventItem.payload->(Utils.magic: Internal.eventPayload => Internal.event),
  toEventLogger: eventItem => {
    let eventConfig =
      eventItem.onEventRegistration.eventConfig->(
        Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig
      )
    Logging.createChildFrom(
      ~logger,
      ~params={
        "program": eventConfig.contractName,
        "instruction": eventConfig.name,
        "chainId": eventItem.chainId,
        "slot": eventItem.blockNumber,
        "programId": eventConfig.programId,
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

let makeRPCSource = (~chainId, ~rpc: string, ~sourceFor: Source.sourceFor=Sync): Source.t => {
  let client = Rest.client(rpc)

  let urlHost = switch Utils.Url.getHostFromUrl(rpc) {
  | None =>
    JsError.throwWithMessage(
      `The RPC url for chain ${chainId->ChainId.toString} is in incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  {
    name,
    sourceFor,
    chainId,
    poweredByHyperSync: false,
    pollingInterval: 10_000,
    getBlockHashes: (~blockNumbers as _, ~logger as _) =>
      JsError.throwWithMessage("Svm does not support getting block hashes"),
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = await GetFinalizedSlot.route->Rest.fetch((), ~client)
      let seconds = timerRef->Performance.secondsSince
      {Source.height, requestStats: [{Source.method: "getSlot", seconds}]}
    },
    getItemsOrThrow: (
      ~fromBlock as _,
      ~toBlock as _,
      ~addressSet as _,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection as _,
      ~itemsTarget as _,
      ~retry as _,
      ~logger as _,
    ) => JsError.throwWithMessage("Svm does not support getting items"),
  }
}
