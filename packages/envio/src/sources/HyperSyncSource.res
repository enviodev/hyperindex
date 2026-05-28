open Source

type selectionConfig = {
  getLogSelectionOrThrow: (
    ~addressesByContractName: dict<array<Address.t>>,
  ) => array<LogSelection.t>,
  fieldSelection: HyperSyncClient.QueryTypes.fieldSelection,
}

let getSelectionConfig = (selection: FetchState.selection, ~chain) => {
  let capitalizedBlockFields = Utils.Set.make()
  let capitalizedTransactionFields = Utils.Set.make()

  let staticTopicSelectionsByContract = Dict.make()
  let dynamicEventFiltersByContract = Dict.make()
  let dynamicWildcardEventFiltersByContract = Dict.make()
  let noAddressesTopicSelections = []
  let contractNames = Utils.Set.make()

  selection.eventConfigs
  ->(Utils.magic: array<Internal.eventConfig> => array<Internal.evmEventConfig>)
  ->Array.forEach(({
    dependsOnAddresses,
    contractName,
    getEventFiltersOrThrow,
    selectedBlockFields,
    selectedTransactionFields,
    isWildcard,
  }) => {
    selectedBlockFields
    ->Utils.Set.toArray
    ->Array.forEach(name =>
      capitalizedBlockFields
      ->Utils.Set.add((name :> string)->Utils.String.capitalize)
      ->ignore
    )
    selectedTransactionFields
    ->Utils.Set.toArray
    ->Array.forEach(name =>
      capitalizedTransactionFields
      ->Utils.Set.add((name :> string)->Utils.String.capitalize)
      ->ignore
    )

    let eventFilters = getEventFiltersOrThrow(chain)
    if dependsOnAddresses {
      let _ = contractNames->Utils.Set.add(contractName)
      switch eventFilters {
      | Static(topicSelections) =>
        staticTopicSelectionsByContract->Utils.Dict.pushMany(contractName, topicSelections)
      | Dynamic(fn) =>
        (
          isWildcard ? dynamicWildcardEventFiltersByContract : dynamicEventFiltersByContract
        )->Utils.Dict.push(contractName, fn)
      }
    } else {
      noAddressesTopicSelections
      ->Array.pushMany(
        switch eventFilters {
        | Static(s) => s
        | Dynamic(fn) => fn([])
        },
      )
      ->ignore
    }
  })

  let fieldSelection: HyperSyncClient.QueryTypes.fieldSelection = {
    log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
    block: capitalizedBlockFields
    ->Utils.Set.toArray
    ->(Utils.magic: array<string> => array<HyperSyncClient.QueryTypes.blockField>),
    transaction: capitalizedTransactionFields
    ->Utils.Set.toArray
    ->(Utils.magic: array<string> => array<HyperSyncClient.QueryTypes.transactionField>),
  }

  let noAddressesLogSelection = LogSelection.make(
    ~addresses=[],
    ~topicSelections=noAddressesTopicSelections,
  )

  let getLogSelectionOrThrow = (~addressesByContractName): array<LogSelection.t> => {
    let logSelections = []
    if noAddressesLogSelection.topicSelections->Utils.Array.isEmpty->not {
      logSelections->Array.push(noAddressesLogSelection)
    }
    contractNames->Utils.Set.forEach(contractName => {
      switch addressesByContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
      | None
      | Some([]) => ()
      | Some(addresses) =>
        switch staticTopicSelectionsByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
        | None => ()
        | Some(topicSelections) =>
          logSelections->Array.push(LogSelection.make(~addresses, ~topicSelections))
        }
        switch dynamicEventFiltersByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
        | None => ()
        | Some(fns) =>
          logSelections->Array.push(
            LogSelection.make(~addresses, ~topicSelections=fns->Array.flatMap(fn => fn(addresses))),
          )
        }
        switch dynamicWildcardEventFiltersByContract->Utils.Dict.dangerouslyGetNonOption(
          contractName,
        ) {
        | None => ()
        | Some(fns) =>
          logSelections->Array.push(
            LogSelection.make(
              ~addresses=[],
              ~topicSelections=fns->Array.flatMap(fn => fn(addresses)),
            ),
          )
        }
      }
    })
    logSelections
  }

  {
    getLogSelectionOrThrow,
    fieldSelection,
  }
}

let memoGetSelectionConfig = (~chain) =>
  Utils.WeakMap.memoize(selection => selection->getSelectionConfig(~chain))

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  allEventParams: array<HyperSyncClient.Decoder.eventParamsInput>,
  eventRouter: EventRouter.t<Internal.evmEventConfig>,
  apiToken: option<string>,
  clientMaxRetries: int,
  clientTimeoutMillis: int,
  lowercaseAddresses: bool,
  serializationFormat: HyperSyncClient.serializationFormat,
  enableQueryCaching: bool,
  logLevel: HyperSyncClient.logLevel,
}

let make = (
  {
    chain,
    endpointUrl,
    allEventParams,
    eventRouter,
    apiToken,
    clientMaxRetries,
    clientTimeoutMillis,
    lowercaseAddresses,
    serializationFormat,
    enableQueryCaching,
    logLevel,
  }: options,
): t => {
  let name = "HyperSync"

  let getSelectionConfig = memoGetSelectionConfig(~chain)

  let apiToken = switch apiToken {
  | Some(token) => token
  | None =>
    JsError.throwWithMessage(`An API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free API token at: https://envio.dev/app/api-tokens`)
  }

  let client = switch HyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken,
    ~maxNumRetries=clientMaxRetries,
    ~httpReqTimeoutMillis=clientTimeoutMillis,
    ~eventParams=allEventParams,
    ~enableChecksumAddresses=!lowercaseAddresses,
    ~serializationFormat,
    ~enableQueryCaching,
    ~logLevel,
  ) {
  | client => client
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(
      ~msg="Failed to instantiate the hypersync client, please double check your ABI",
    )
  }

  exception UndefinedValue

  let makeEventBatchQueueItem = (
    item: HyperSyncClient.EventItems.item,
    ~params: Internal.eventParams,
    ~eventConfig: Internal.evmEventConfig,
  ): Internal.item => {
    let {block, transaction, logIndex, srcAddress} = item
    let chainId = chain->ChainMap.Chain.toChainId

    Internal.Event({
      eventConfig: (eventConfig :> Internal.eventConfig),
      timestamp: block.timestamp->Belt.Option.getUnsafe,
      chain,
      blockNumber: block.number->Belt.Option.getUnsafe,
      logIndex,
      event: {
        contractName: eventConfig.contractName,
        eventName: eventConfig.name,
        chainId,
        params,
        transaction,
        block: block->(Utils.magic: HyperSyncClient.ResponseTypes.block => Internal.eventBlock),
        srcAddress,
        logIndex,
      }->Internal.fromGenericEvent,
    })
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~indexingAddresses,
    ~knownHeight,
    ~partitionId as _,
    ~selection,
    ~retry,
    ~logger,
  ) => {
    let mkLogAndRaise = ErrorHandling.mkLogAndRaise(~logger, ...)
    let totalTimeRef = Hrtime.makeTimer()

    let selectionConfig = selection->getSelectionConfig

    let logSelections = try selectionConfig.getLogSelectionOrThrow(~addressesByContractName) catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed getting log selection for the query")
    }

    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    //fetch batch
    Prometheus.SourceRequestCount.increment(
      ~sourceName=name,
      ~chainId=chain->ChainMap.Chain.toChainId,
      ~method="getLogs",
    )
    let pageUnsafe = try await HyperSync.GetLogs.query(
      ~client,
      ~fromBlock,
      ~toBlock,
      ~logSelections,
      ~fieldSelection=selectionConfig.fieldSelection,
    ) catch {
    | HyperSync.GetLogs.Error(error) =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: switch error {
            | WrongInstance =>
              let backoffMillis = switch retry {
              | 0 => 100
              | _ => 500 * retry
              }
              WithBackoff({
                message: `Block #${fromBlock->Int.toString} not found in HyperSync. HyperSync has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${backoffMillis->Int.toString}ms.`,
                backoffMillis,
              })
            | UnexpectedMissingParams({missingParams}) =>
              ImpossibleForTheQuery({
                message: `Source returned invalid data with missing required fields: ${missingParams->Array.joinUnsafe(
                    ", ",
                  )}`,
              })
            },
          }),
        ),
      )
    | exn =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn,
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: WithBackoff({
              message: `Unexpected issue while fetching events from HyperSync client. Attempt a retry.`,
              backoffMillis: switch retry {
              | 0 => 500
              | _ => 1000 * retry
              },
            }),
          }),
        ),
      )
    }

    let pageFetchTime = startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toSecondsFloat

    //set height and next from block
    let knownHeight = pageUnsafe.archiveHeight

    //The heighest (biggest) blocknumber that was accounted for in
    //Our query. Not necessarily the blocknumber of the last log returned
    //In the query
    let heighestBlockQueried = pageUnsafe.nextBlock - 1

    let parsingTimeRef = Hrtime.makeTimer()

    //Parse page items into queue items
    let parsedQueueItems = []

    let handleDecodeFailure = (
      ~eventConfig: Internal.evmEventConfig,
      ~logIndex,
      ~blockNumber,
      ~chainId,
      ~exn,
    ) => {
      if !eventConfig.isWildcard {
        //Wildcard events can be parsed as undefined if the number of topics
        //don't match the event with the given topic0
        //Non wildcard events should be expected to be parsed
        let msg = `Event ${eventConfig.name} was unexpectedly parsed as undefined`
        let logger = Logging.createChildFrom(
          ~logger,
          ~params={
            "chainId": chainId,
            "blockNumber": blockNumber,
            "logIndex": logIndex,
            "decoder": "hypersync-client",
          },
        )
        exn->ErrorHandling.mkLogAndRaise(~msg, ~logger)
      }
    }

    pageUnsafe.items->Belt.Array.forEach(item => {
      let chainId = chain->ChainMap.Chain.toChainId
      let maybeEventConfig =
        eventRouter->EventRouter.get(
          ~tag=EventRouter.getEvmEventId(
            ~sighash=item.topic0->EvmTypes.Hex.toString,
            ~topicCount=item.topicCount,
          ),
          ~indexingAddresses,
          ~contractAddress=item.srcAddress,
          ~blockNumber=item.block.number->Belt.Option.getUnsafe,
        )

      switch (maybeEventConfig, item.params) {
      | (Some(eventConfig), Value(decoded)) =>
        parsedQueueItems
        ->Array.push(makeEventBatchQueueItem(item, ~params=decoded, ~eventConfig))
        ->ignore
      | (Some(eventConfig), Null | Undefined) =>
        handleDecodeFailure(
          ~eventConfig,
          ~logIndex=item.logIndex,
          ~blockNumber=item.block.number->Belt.Option.getUnsafe,
          ~chainId,
          ~exn=UndefinedValue,
        )
      | (None, _) => () //ignore events that aren't registered
      }
    })

    let parsingTimeElapsed = parsingTimeRef->Hrtime.timeSince->Hrtime.toSecondsFloat

    // Collect (blockNumber, blockHash) pairs we already have from the response —
    // one per item's block plus, when present, the rollbackGuard's head block
    // and the parent of the range's first block. Duplicates are allowed; reorg
    // detection notices same-block-number-different-hash collisions itself.
    let blockHashes = []
    pageUnsafe.items->Belt.Array.forEach(({block}) => {
      switch (block.number, block.hash) {
      | (Some(blockNumber), Some(blockHash)) =>
        blockHashes->Array.push({ReorgDetection.blockNumber, blockHash})->ignore
      | _ => ()
      }
    })
    switch pageUnsafe.rollbackGuard {
    | None => ()
    | Some({blockNumber, hash, firstBlockNumber, firstParentHash}) => {
        blockHashes->Array.push({ReorgDetection.blockNumber, blockHash: hash})->ignore
        blockHashes
        ->Array.push({
          ReorgDetection.blockNumber: firstBlockNumber - 1,
          blockHash: firstParentHash,
        })
        ->ignore
      }
    }

    // Best-effort timestamp for the queried-range head: prefer the rollbackGuard
    // (set at the head for unconfirmed blocks), otherwise the last item if it
    // happens to be in the range's last block. 0 is a tolerated placeholder
    // when neither is available (FetchState already uses 0 in several spots).
    let latestFetchedBlockTimestamp = switch pageUnsafe.rollbackGuard {
    | Some({timestamp}) => timestamp
    | None =>
      switch pageUnsafe.items->Belt.Array.get(pageUnsafe.items->Belt.Array.length - 1) {
      | Some({block}) if block.number->Belt.Option.getUnsafe == heighestBlockQueried =>
        block.timestamp->Belt.Option.getUnsafe
      | _ => 0
      }
    }

    let totalTimeElapsed = totalTimeRef->Hrtime.timeSince->Hrtime.toSecondsFloat

    let stats = {
      totalTimeElapsed,
      parsingTimeElapsed,
      pageFetchTime,
    }

    {
      latestFetchedBlockTimestamp,
      parsedQueueItems,
      latestFetchedBlockNumber: heighestBlockQueried,
      stats,
      knownHeight,
      blockHashes,
      fromBlockQueried: fromBlock,
    }
  }

  let getBlockHashes = (~blockNumbers, ~logger) =>
    HyperSync.queryBlockDataMulti(
      ~client,
      ~blockNumbers,
      ~sourceName=name,
      ~chainId=chain->ChainMap.Chain.toChainId,
      ~logger,
    )->Promise.thenResolve(HyperSync.mapExn)

  let jsonApiClient = Rest.client(endpointUrl)

  let malformedTokenMessage = `Your token is malformed. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens.`

  {
    name,
    sourceFor: Sync,
    chain,
    pollingInterval: 100,
    poweredByHyperSync: true,
    getBlockHashes,
    getHeightOrThrow: async () => {
      let timerRef = Hrtime.makeTimer()
      let result = switch await HyperSyncJsonApi.heightRoute->Rest.fetch(
        apiToken,
        ~client=jsonApiClient,
      ) {
      | Value(height) => height
      | ErrorMessage(m) if m === malformedTokenMessage =>
        Logging.error(`Your ENVIO_API_TOKEN is malformed. The indexer will not be able to fetch events. Update the token and restart the indexer using 'pnpm envio start'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens`)
        // Don't want to retry if the token is malformed
        // So just block forever
        let _ = await Promise.make((_, _) => ())
        0
      | ErrorMessage(m) => JsError.throwWithMessage(m)
      }
      let seconds = timerRef->Hrtime.timeSince->Hrtime.toSecondsFloat
      Prometheus.SourceRequestCount.increment(
        ~sourceName=name,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~method="getHeight",
      )
      Prometheus.SourceRequestCount.addSeconds(
        ~sourceName=name,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~method="getHeight",
        ~seconds,
      )
      result
    },
    getItemsOrThrow,
    createHeightSubscription: (~onHeight) =>
      HyperSyncHeightStream.subscribe(
        ~hyperSyncUrl=endpointUrl,
        ~apiToken,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~onHeight,
      ),
  }
}
