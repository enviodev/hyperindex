open Source

// Pulls the underlying provider error message back out of a caught exn, for
// logging/debugging. Provider JSON-RPC errors surface as `Rpc.JsonRpcError`;
// the paging retry decision (see `parseGetNextPageRetryError` below) surfaces
// as a napi `JsExn` whose message is the JSON payload `EvmRpcClient.getNextPage`
// throws, carrying the classified message (if any) under `errorMessage`.
let getErrorMessage = (exn: exn): option<string> =>
  switch exn {
  | Rpc.JsonRpcError({message}) => Some(message)
  | JsExn(e) =>
    switch e->JsExn.message {
    | Some(msg) =>
      switch msg->JSON.parseOrThrow->JSON.Decode.object {
      | exception _ => None
      | None => None
      | Some(obj) =>
        switch obj->Dict.get("errorMessage") {
        | Some(String(message)) => Some(message)
        | _ => None
        }
      }
    | None => None
    }
  | _ => None
  }

// `EvmRpcClient.getNextPage` throws a napi error whose message is a JSON
// payload describing the retry decision:
// `{"kind":"Retry","attemptedToBlock":int,"errorMessage":string|null,
// "requestStats":[{"method":string,"seconds":float}],"retry":
// {"tag":"WithSuggestedToBlock","toBlock":int} |
// {"tag":"WithBackoff","message":string,"backoffMillis":int}}`.
let parseGetNextPageRetryError = (exn: exn): option<(
  int,
  Source.getItemsRetry,
  array<Source.requestStat>,
)> =>
  switch exn {
  | JsExn(e) =>
    switch e->JsExn.message {
    | Some(msg) =>
      switch msg->JSON.parseOrThrow->JSON.Decode.object {
      | exception _ => None
      | None => None
      | Some(obj) =>
        switch (obj->Dict.get("kind"), obj->Dict.get("attemptedToBlock"), obj->Dict.get("retry")) {
        | (Some(String("Retry")), Some(Number(attemptedToBlock)), Some(Object(retryObj))) =>
          let requestStats = switch obj->Dict.get("requestStats") {
          | Some(Array(stats)) =>
            stats->Array.filterMap(s =>
              switch s->JSON.Decode.object {
              | Some(o) =>
                switch (o->Dict.get("method"), o->Dict.get("seconds")) {
                | (Some(String(method)), Some(Number(seconds))) => Some({Source.method, seconds})
                | _ => None
                }
              | None => None
              }
            )
          | _ => []
          }
          let retry = switch retryObj->Dict.get("tag") {
          | Some(String("WithSuggestedToBlock")) =>
            switch retryObj->Dict.get("toBlock") {
            | Some(Number(toBlock)) =>
              Some(Source.WithSuggestedToBlock({toBlock: toBlock->Float.toInt}))
            | _ => None
            }
          | Some(String("WithBackoff")) =>
            switch (retryObj->Dict.get("message"), retryObj->Dict.get("backoffMillis")) {
            | (Some(String(message)), Some(Number(backoffMillis))) =>
              Some(Source.WithBackoff({message, backoffMillis: backoffMillis->Float.toInt}))
            | _ => None
            }
          | _ => None
          }
          retry->Option.map(retry => (attemptedToBlock->Float.toInt, retry, requestStats))
        | _ => None
        }
      }
    | None => None
    }
  | _ => None
  }

// A store-data fetch that can never satisfy the field selection (a required
// field absent from the provider's response) surfaces from Rust as a
// `{"kind":"FieldSelectionError","blockNumber":int,"message":string}` payload,
// wrapped in the native-failure envelope that carries the request timings.
let parseFieldSelectionError = (failure: Source.nativeRequestFailure): option<(int, string)> =>
  switch failure.message {
  | Some(msg) =>
    switch msg->JSON.parseOrThrow->JSON.Decode.object {
    | exception _ => None
    | None => None
    | Some(obj) =>
      switch (obj->Dict.get("kind"), obj->Dict.get("blockNumber"), obj->Dict.get("message")) {
      | (Some(String("FieldSelectionError")), Some(Number(blockNumber)), Some(String(message))) =>
        Some((blockNumber->Float.toInt, message))
      | _ => None
      }
    }
  | None => None
  }

// Whether an RPC source can populate a transaction field. `hash` and
// `transactionIndex` come off the log itself; the rest map onto
// `eth_getTransactionByHash`/`eth_getTransactionReceipt`. Kept in step with
// the `RpcTransactionField` subenum in `human_config.rs` and the Rust
// `rpc_tx_field_source` classification (`store_fetch.rs`);
// `RpcFieldSelection_test.res` pins the sets together.
let isRpcTransactionField = (name: string) =>
  switch name {
  | "accessList" | "authorizationList" => false
  | _ => Evm.transactionFields->Array.includes(name)
  }

type options = {
  sourceFor: Source.sourceFor,
  syncConfig: Config.sourceSync,
  url: string,
  chainId: ChainId.t,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.evmOnEventRegistration>,
  lowercaseAddresses: bool,
  // The chain's address index; the client reads it while routing.
  addressStore: AddressStore.t,
  ws?: string,
  headers?: dict<string>,
}

let make = (
  {
    sourceFor,
    syncConfig,
    url,
    chainId,
    onEventRegistrations,
    lowercaseAddresses,
    addressStore,
    ?ws,
    ?headers,
  }: options,
): t => {
  let urlHost = switch Utils.Url.getHostFromUrl(url) {
  | None =>
    JsError.throwWithMessage(
      `The RPC url for chain ${chainId->ChainId.toString} is in incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  let rpcClient = EvmRpcClient.make(
    ~url,
    ~eventRegistrations=HyperSyncClient.Registration.fromOnEventRegistrations(onEventRegistrations),
    ~checksumAddresses=!lowercaseAddresses,
    ~syncConfig,
    ~headers?,
    ~addressStore,
  )

  // Timings of requests a failed operation still made (delivered on its error
  // payload) are held here and drained into the next successful response, so
  // per-source totals stay exact across retries.
  let pendingRequestStats: array<Source.requestStat> = []
  let recordRequest = (stats: array<Source.requestStat>) => {
    stats->Array.forEach(stat => pendingRequestStats->Array.push(stat)->ignore)
  }
  let drainRequestStats = (stats: array<Source.requestStat>) => {
    let all = pendingRequestStats->Utils.Array.copy->Array.concat(stats)
    pendingRequestStats->Utils.Array.clearInPlace
    all
  }

  let makeEventBatchQueueItem = (
    item: EvmRpcClient.eventItem,
    ~onEventRegistration: Internal.evmOnEventRegistration,
  ): Internal.item => {
    Internal.Event({
      onEventRegistration: (onEventRegistration :> Internal.onEventRegistration),
      chainId,
      blockNumber: item.blockNumber,
      logIndex: item.logIndex,
      transactionIndex: item.transactionIndex,
      // `block` and `transaction` are omitted; they're materialised from the
      // per-chain stores onto the payload at batch prep.
      payload: {
        contractName: onEventRegistration.eventConfig.contractName,
        eventName: onEventRegistration.eventConfig.name,
        chainId,
        params: item.params,
        srcAddress: item.srcAddress,
        logIndex: item.logIndex,
      }->Evm.fromPayload,
    })
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressSet,
    ~knownHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~itemsTarget as _,
    ~retry,
    ~logger as _,
  ) => {
    let startFetchingBatchTimeRef = Performance.now()

    // Always have a toBlock for an RPC worker
    let toBlock = switch toBlock {
    | Some(toBlock) => Pervasives.min(toBlock, knownHeight)
    | None => knownHeight
    }

    if selection.onEventRegistrations->Utils.Array.isEmpty {
      throw(
        Source.GetItemsError(
          UnsupportedSelection({
            message: "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
          }),
        ),
      )
    }

    let (page, transactionStore, blockStore) = try await rpcClient.getNextPage(
      {
        fromBlock,
        toBlockCeiling: toBlock,
        partitionId,
        registrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
        clientFilteredContracts: selection.clientFilteredContracts,
      },
      addressSet,
    ) catch {
    | exn =>
      switch exn->parseGetNextPageRetryError {
      | Some((attemptedToBlock, retry, requestStats)) =>
        recordRequest(requestStats)
        throw(Source.GetItemsError(FailedGettingItems({exn, attemptedToBlock, retry})))
      | None =>
        let failure = exn->Source.unpackNativeRequestFailure
        recordRequest(failure.requestStats)
        switch failure->parseFieldSelectionError {
        | Some((blockNumber, message)) =>
          throw(
            Source.GetItemsError(
              FailedGettingFieldSelection({
                message,
                exn: failure.cause,
                blockNumber,
                logIndex: 0,
              }),
            ),
          )
        | None =>
          throw(
            Source.GetItemsError(
              FailedGettingItems({
                exn,
                attemptedToBlock: toBlock,
                retry: WithBackoff({
                  message: "Unexpected issue while fetching events from the RPC client. Attempt a retry.",
                  backoffMillis: switch retry {
                  | 0 => 500
                  | _ => 1000 * retry
                  },
                }),
              }),
            ),
          )
        }
      }
    }

    let parsedQueueItems = page.items->Array.map(item => {
      let onEventRegistration = onEventRegistrations->Array.getUnsafe(item.onEventRegistrationIndex)
      makeEventBatchQueueItem(item, ~onEventRegistration)
    })

    let totalTimeElapsed = startFetchingBatchTimeRef->Performance.secondsSince

    {
      latestFetchedBlockNumber: page.toBlock,
      parsedQueueItems,
      transactionStore: Some(transactionStore),
      // The page store carries full rows for the blocks the field selections
      // need, hash observations for every log's block, and the range-endpoint
      // blocks that anchor reorg detection - all inserted on the Rust side.
      blockStore,
      stats: {
        totalTimeElapsed: totalTimeElapsed,
      },
      knownHeight,
      fromBlockQueried: fromBlock,
      requestStats: drainRequestStats(page.requestStats),
      missingStoreData: ?(page.missing->Source.missingStoreDataIsEmpty ? None : Some(page.missing)),
    }
  }

  // Targeted refetch of the rows a response reported missing; fetched rows
  // merge into the response's own page stores, so SourceManager can hand the
  // completed response to processing without refetching the logs.
  let fetchItemsStoreData = async (
    ~missing: Source.missingStoreData,
    ~transactionStore: option<TransactionStore.t>,
    ~blockStore: BlockStore.t,
  ) => {
    let (res, txPage, blockPage) = try await rpcClient.fetchStoreData(missing) catch {
    | exn =>
      let failure = exn->Source.unpackNativeRequestFailure
      switch failure->parseFieldSelectionError {
      | Some((blockNumber, message)) =>
        throw(
          Source.GetItemsError(
            FailedGettingFieldSelection({
              message,
              exn: failure.cause,
              blockNumber,
              logIndex: 0,
            }),
          ),
        )
      | None => throw(exn)
      }
    }
    switch transactionStore {
    | Some(store) => store->TransactionStore.merge(txPage)
    | None => ()
    }
    blockStore->BlockStore.appendPage(blockPage)
    {
      Source.stillMissing: res.missing->Source.missingStoreDataIsEmpty ? None : Some(res.missing),
      requestStats: res.requestStats,
    }
  }

  let getBlockHashes = HyperSync.makeGetBlockHashes(~query=(~blockNumbers) =>
    rpcClient.getBlockHashes(blockNumbers)
  )

  let createHeightSubscription =
    ws->Option.map(wsUrl =>
      (~onHeight) => RpcWebSocketHeightStream.subscribe(~wsUrl, ~chainId, ~onHeight)
    )

  {
    name,
    sourceFor,
    chainId,
    poweredByHyperSync: false,
    pollingInterval: syncConfig.pollingInterval,
    getBlockHashes,
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = try {
        await rpcClient.getHeight()
      } catch {
      | exn =>
        recordRequest([
          {Source.method: "eth_blockNumber", seconds: timerRef->Performance.secondsSince},
        ])
        exn->throw
      }
      {
        height,
        requestStats: drainRequestStats([
          {Source.method: "eth_blockNumber", seconds: timerRef->Performance.secondsSince},
        ]),
      }
    },
    getItemsOrThrow,
    fetchItemsStoreData,
    ?createHeightSubscription,
  }
}
