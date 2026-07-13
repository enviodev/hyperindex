open Source

type selectionConfig = {
  getLogSelectionOrThrow: (
    ~addressesByContractName: dict<array<Address.t>>,
  ) => array<LogSelection.t>,
  fieldSelection: HyperSyncClient.QueryTypes.fieldSelection,
}

let getSelectionConfig = (selection: FetchState.selection) => {
  let capitalizedBlockFields = Utils.Set.make()
  let capitalizedTransactionFields = Utils.Set.make()

  let topicSelectionsByContract = Dict.make()
  let wildcardTopicSelectionsByContract = Dict.make()
  let noAddressesTopicSelections = []
  let contractNames = Utils.Set.make()

  selection.onEventRegistrations
  ->(Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>)
  ->Array.forEach(reg => {
    let eventConfig =
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
    let contractName = eventConfig.contractName
    let {selectedBlockFields, selectedTransactionFields} = eventConfig
    let {dependsOnAddresses, resolvedWhere, isWildcard} = reg
    selectedBlockFields
    ->Utils.Set.toArray
    ->Array.forEach(name =>
      capitalizedBlockFields
      ->Utils.Set.add((name :> string)->Utils.String.capitalize)
      ->ignore
    )
    selectedTransactionFields
    ->Utils.Set.toArray
    ->Array.forEach(name => {
      // transactionIndex is read off the log (the store key), so it never needs
      // to be requested as a transaction column — and requesting it alone would
      // pull the whole transaction table for nothing.
      let fieldName = (name :> string)
      if fieldName != "transactionIndex" {
        capitalizedTransactionFields->Utils.Set.add(fieldName->Utils.String.capitalize)->ignore
      }
    })

    if dependsOnAddresses {
      let _ = contractNames->Utils.Set.add(contractName)

      (
        isWildcard ? wildcardTopicSelectionsByContract : topicSelectionsByContract
      )->Utils.Dict.pushMany(contractName, resolvedWhere.topicSelections)
    } else {
      noAddressesTopicSelections
      ->Array.pushMany(
        resolvedWhere.topicSelections->LogSelection.materializeTopicSelections(~addresses=[]),
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
        switch topicSelectionsByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
        | None => ()
        | Some(topicSelections) =>
          logSelections->Array.push(
            LogSelection.make(
              ~addresses,
              ~topicSelections=topicSelections->LogSelection.materializeTopicSelections(~addresses),
            ),
          )
        }
        // Wildcard events that filter an indexed param by registered addresses:
        // the addresses fold into the topics, so the query itself stays
        // address-unbound.
        switch wildcardTopicSelectionsByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
        | None => ()
        | Some(topicSelections) =>
          logSelections->Array.push(
            LogSelection.make(
              ~addresses=[],
              ~topicSelections=topicSelections->LogSelection.materializeTopicSelections(~addresses),
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

let memoGetSelectionConfig = () => Utils.WeakMap.memoize(getSelectionConfig)

// Surfaced by HyperSyncClient.getHeight (Rust) when HyperSync rejects the API
// token. The corrupted-token test feeds the real server error through this
// check so it can't silently drift away from what getHeightOrThrow guards on.
let isUnauthorizedError = (message: string) => message->String.includes("401 Unauthorized")

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  allEventParams: array<HyperSyncClient.Decoder.eventParamsInput>,
  eventRouter: EventRouter.t<Internal.evmOnEventRegistration>,
  apiToken: option<string>,
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
    clientTimeoutMillis,
    lowercaseAddresses,
    serializationFormat,
    enableQueryCaching,
    logLevel,
  }: options,
): t => {
  let name = "HyperSync"

  let getSelectionConfig = memoGetSelectionConfig()

  let apiToken = switch apiToken {
  | Some(token) => token
  | None =>
    JsError.throwWithMessage(`An Envio API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens`)
  }

  let client = switch HyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken,
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
    ~onEventRegistration: Internal.evmOnEventRegistration,
  ): Internal.item => {
    let {transactionIndex, logIndex, srcAddress} = item
    let chainId = chain->ChainMap.Chain.toChainId

    Internal.Event({
      onEventRegistration: (onEventRegistration :> Internal.onEventRegistration),
      chain,
      blockNumber: item.blockNumber,
      logIndex,
      transactionIndex,
      // `block` and `transaction` are omitted; they're materialised from the
      // per-chain stores onto the payload at batch prep.
      payload: {
        contractName: onEventRegistration.eventConfig.contractName,
        eventName: onEventRegistration.eventConfig.name,
        chainId,
        params,
        srcAddress,
        logIndex,
      }->Evm.fromPayload,
    })
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~contractNameByAddress,
    ~knownHeight,
    ~partitionId as _,
    ~selection,
    ~itemsTarget,
    ~retry,
    ~logger,
  ) => {
    let totalTimeRef = Performance.now()

    let selectionConfig = selection->getSelectionConfig

    let logSelections = try selectionConfig.getLogSelectionOrThrow(~addressesByContractName) catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed getting log selection for the query")
    }

    let startFetchingBatchTimeRef = Performance.now()

    //fetch batch
    let pageUnsafe = try await HyperSync.GetLogs.query(
      ~client,
      ~fromBlock,
      ~toBlock,
      ~logSelections,
      ~fieldSelection=selectionConfig.fieldSelection,
      ~maxNumLogs=itemsTarget,
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
    | Source.RateLimited(_) as exn => throw(exn)
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

    let pageFetchTime = startFetchingBatchTimeRef->Performance.secondsSince
    let requestStats = [{Source.method: "getLogs", seconds: pageFetchTime}]

    //set height and next from block
    let knownHeight = pageUnsafe.archiveHeight

    //The heighest (biggest) blocknumber that was accounted for in
    //Our query. Not necessarily the blocknumber of the last log returned
    //In the query
    let heighestBlockQueried = pageUnsafe.nextBlock - 1

    let parsingTimeRef = Performance.now()

    //Parse page items into queue items
    let parsedQueueItems = []

    // Block headers are returned once per number; items reference them by blockNumber.
    let blocksByNumber = Utils.Map.make()
    pageUnsafe.blocks->Array.forEach(block => {
      blocksByNumber->Utils.Map.set(block.number, block)->ignore
    })
    let getBlock = blockNumber => blocksByNumber->Utils.Map.unsafeGet(blockNumber)

    let handleDecodeFailure = (
      ~onEventRegistration: Internal.evmOnEventRegistration,
      ~logIndex,
      ~blockNumber,
      ~chainId,
      ~exn,
    ) => {
      if !onEventRegistration.isWildcard {
        //Wildcard events can be parsed as undefined if the number of topics
        //don't match the event with the given topic0
        //Non wildcard events should be expected to be parsed
        let msg = `Event ${onEventRegistration.eventConfig.name} was unexpectedly parsed as undefined`
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

    pageUnsafe.items->Array.forEach(item => {
      let chainId = chain->ChainMap.Chain.toChainId
      let maybeEventConfig =
        eventRouter->EventRouter.get(
          ~tag=EventRouter.getEvmEventId(
            ~sighash=item.topic0->EvmTypes.Hex.toString,
            ~topicCount=item.topicCount,
          ),
          ~contractNameByAddress,
          ~contractAddress=item.srcAddress,
        )

      switch maybeEventConfig {
      | None => () //ignore events that aren't registered
      | Some(onEventRegistration) =>
        switch item.params
        ->Nullable.toOption
        ->Option.flatMap(Dict.get(_, onEventRegistration.eventConfig.contractName)) {
        | Some(params) =>
          parsedQueueItems
          ->Array.push(makeEventBatchQueueItem(item, ~params, ~onEventRegistration))
          ->ignore
        | None =>
          handleDecodeFailure(
            ~onEventRegistration,
            ~logIndex=item.logIndex,
            ~blockNumber=item.blockNumber,
            ~chainId,
            ~exn=UndefinedValue,
          )
        }
      }
    })

    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince

    // Best-effort timestamp for the queried-range head: prefer the rollbackGuard
    // (set at the head for unconfirmed blocks), otherwise the last item if it
    // happens to be in the range's last block. 0 is a tolerated placeholder
    // when neither is available (FetchState already uses 0 in several spots).
    let latestFetchedBlockTimestamp = switch pageUnsafe.rollbackGuard {
    | Some({timestamp}) => timestamp
    | None =>
      switch pageUnsafe.items->Array.get(pageUnsafe.items->Array.length - 1) {
      | Some(item) if item.blockNumber == heighestBlockQueried =>
        getBlock(item.blockNumber).timestamp
      | _ => 0
      }
    }

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    let stats = {
      totalTimeElapsed,
      parsingTimeElapsed,
      pageFetchTime,
    }

    {
      latestFetchedBlockTimestamp,
      parsedQueueItems,
      transactionStore: Some(pageUnsafe.transactionStore),
      // The page store also carries the rollbackGuard's blocks (head block and
      // parent of the range's first block), inserted on the Rust side.
      blockStore: pageUnsafe.blockStore,
      latestFetchedBlockNumber: heighestBlockQueried,
      stats,
      knownHeight,
      fromBlockQueried: fromBlock,
      requestStats,
    }
  }

  let getBlockHashes = async (~blockNumbers, ~logger as _) => {
    let (result, requestStats) = try {
      let (blockStore, requestStats) = await client.getBlockHashes(~blockNumbers)
      (Ok(blockStore), requestStats)
    } catch {
    | exn => {
        let failure = exn->Source.unpackNativeRequestFailure
        (Error(exn->HyperSync.mapRateLimitedExn), failure.requestStats)
      }
    }
    {Source.result, requestStats}
  }

  {
    name,
    sourceFor: Sync,
    chain,
    pollingInterval: 100,
    poweredByHyperSync: true,
    getBlockHashes,
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = try {
        await client.getHeight()
      } catch {
      | JsExn(e) =>
        switch e->JsExn.message {
        | Some(message) if message->isUnauthorizedError =>
          Logging.error(`Your ENVIO_API_TOKEN was rejected by HyperSync (401 Unauthorized). The indexer will not be able to fetch events. Update the token and try again using 'envio start' or 'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens`)
          // Retrying an unauthorized request can never succeed, so block forever
          let _ = await Promise.make((_, _) => ())
          0
        | _ => throw(JsExn(e))
        }
      }
      let seconds = timerRef->Performance.secondsSince
      {height, requestStats: [{method: "getHeight", seconds}]}
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
