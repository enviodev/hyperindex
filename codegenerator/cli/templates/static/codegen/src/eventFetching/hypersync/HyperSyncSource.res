open Source
open Belt

type selectionConfig = {
  getLogSelectionOrThrow: (
    ~addressesByContractName: dict<array<Address.t>>,
  ) => array<LogSelection.t>,
  fieldSelection: HyperSyncClient.QueryTypes.fieldSelection,
  nonOptionalBlockFieldNames: array<string>,
  nonOptionalTransactionFieldNames: array<string>,
}

let getSelectionConfig = (selection: FetchState.selection, ~chain) => {
  let nonOptionalBlockFieldNames = Utils.Set.make()
  let nonOptionalTransactionFieldNames = Utils.Set.make()
  let capitalizedBlockFields = Utils.Set.make()
  let capitalizedTransactionFields = Utils.Set.make()

  let staticTopicSelectionsByContract = Js.Dict.empty()
  let dynamicEventFiltersByContract = Js.Dict.empty()
  let dynamicWildcardEventFiltersByContract = Js.Dict.empty()
  let noAddressesTopicSelections = []
  let contractNames = Utils.Set.make()

  selection.eventConfigs
  ->(Utils.magic: array<Internal.eventConfig> => array<Internal.evmEventConfig>)
  ->Array.forEach(({
    dependsOnAddresses,
    contractName,
    getEventFiltersOrThrow,
    blockSchema,
    transactionSchema,
    isWildcard,
  }) => {
    nonOptionalBlockFieldNames->Utils.Set.addMany(
      blockSchema->Utils.Schema.getNonOptionalFieldNames,
    )
    nonOptionalTransactionFieldNames->Utils.Set.addMany(
      transactionSchema->Utils.Schema.getNonOptionalFieldNames,
    )
    capitalizedBlockFields->Utils.Set.addMany(blockSchema->Utils.Schema.getCapitalizedFieldNames)
    capitalizedTransactionFields->Utils.Set.addMany(
      transactionSchema->Utils.Schema.getCapitalizedFieldNames,
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
      ->Js.Array2.pushMany(
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
            LogSelection.make(
              ~addresses,
              ~topicSelections=fns->Array.flatMapU(fn => fn(addresses)),
            ),
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
              ~topicSelections=fns->Array.flatMapU(fn => fn(addresses)),
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
    nonOptionalBlockFieldNames: nonOptionalBlockFieldNames->Utils.Set.toArray,
    nonOptionalTransactionFieldNames: nonOptionalTransactionFieldNames->Utils.Set.toArray,
  }
}

let memoGetSelectionConfig = (~chain) => {
  let cache = Utils.WeakMap.make()
  selection =>
    switch cache->Utils.WeakMap.get(selection) {
    | Some(c) => c
    | None => {
        let c = selection->getSelectionConfig(~chain)
        let _ = cache->Utils.WeakMap.set(selection, c)
        c
      }
    }
}

type options = {
  contracts: array<Internal.evmContractConfig>,
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  allEventSignatures: array<string>,
  shouldUseHypersyncClientDecoder: bool,
  eventRouter: EventRouter.t<Internal.evmEventConfig>,
}

let make = (
  {
    contracts,
    chain,
    endpointUrl,
    allEventSignatures,
    shouldUseHypersyncClientDecoder,
    eventRouter,
  }: options,
): t => {
  let name = "HyperSync"

  let getSelectionConfig = memoGetSelectionConfig(~chain)

  let apiToken =
    Env.envioApiToken->Belt.Option.getWithDefault("3dc856dd-b0ea-494f-b27e-017b8b6b7e07")

  let client = HyperSyncClient.make(
    ~url=endpointUrl,
    ~apiToken,
    ~maxNumRetries=Env.hyperSyncClientMaxRetries,
    ~httpReqTimeoutMillis=Env.hyperSyncClientTimeoutMillis,
  )

  let hscDecoder: ref<option<HyperSyncClient.Decoder.t>> = ref(None)
  let getHscDecoder = () => {
    switch hscDecoder.contents {
    | Some(decoder) => decoder
    | None =>
      switch HyperSyncClient.Decoder.fromSignatures(allEventSignatures) {
      | exception exn =>
        exn->ErrorHandling.mkLogAndRaise(
          ~msg="Failed to instantiate a decoder from hypersync client, please double check your ABI or try using 'event_decoder: viem' config option",
        )
      | decoder =>
        decoder.enableChecksummedAddresses()
        decoder
      }
    }
  }

  exception UndefinedValue

  let makeEventBatchQueueItem = (
    item: HyperSync.logsQueryPageItem,
    ~params: Internal.eventParams,
    ~eventConfig: Internal.evmEventConfig,
  ): Internal.eventItem => {
    let {block, log, transaction} = item
    let chainId = chain->ChainMap.Chain.toChainId

    {
      eventConfig: (eventConfig :> Internal.eventConfig),
      timestamp: block->Types.Block.getTimestamp,
      chain,
      blockNumber: block->Types.Block.getNumber,
      logIndex: log.logIndex,
      event: {
        chainId,
        params,
        transaction,
        block,
        srcAddress: log.address,
        logIndex: log.logIndex,
      }->Internal.fromGenericEvent,
    }
  }

  let contractNameAbiMapping = Js.Dict.empty()
  contracts->Belt.Array.forEach(contract => {
    contractNameAbiMapping->Js.Dict.set(contract.name, contract.abi)
  })

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~indexingContracts,
    ~currentBlockHeight,
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
    let pageUnsafe = try await HyperSync.GetLogs.query(
      ~client,
      ~fromBlock,
      ~toBlock,
      ~logSelections,
      ~fieldSelection=selectionConfig.fieldSelection,
      ~nonOptionalBlockFieldNames=selectionConfig.nonOptionalBlockFieldNames,
      ~nonOptionalTransactionFieldNames=selectionConfig.nonOptionalTransactionFieldNames,
    ) catch {
    | HyperSync.GetLogs.Error(error) =>
      raise(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: toBlock->Option.getWithDefault(currentBlockHeight),
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
              WithBackoff({
                message: `Received page response with invalid data. Attempt a retry. Missing params: ${missingParams->Js.Array2.joinWith(
                    ",",
                  )}`,
                backoffMillis: switch retry {
                | 0 => 1000
                | _ => 4000 * retry
                },
              })
            },
          }),
        ),
      )
    | exn =>
      raise(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn,
            attemptedToBlock: toBlock->Option.getWithDefault(currentBlockHeight),
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

    let pageFetchTime =
      startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    //set height and next from block
    let currentBlockHeight = pageUnsafe.archiveHeight

    //The heighest (biggest) blocknumber that was accounted for in
    //Our query. Not necessarily the blocknumber of the last log returned
    //In the query
    let heighestBlockQueried = pageUnsafe.nextBlock - 1

    let lastBlockQueriedPromise = switch pageUnsafe.rollbackGuard {
    //In the case a rollbackGuard is returned (this only happens at the head for unconfirmed blocks)
    //use these values
    | Some({blockNumber, timestamp, hash}) =>
      (
        {
          blockNumber,
          blockTimestamp: timestamp,
          blockHash: hash,
        }: ReorgDetection.blockDataWithTimestamp
      )->Promise.resolve
    | None =>
      //The optional block and timestamp of the last item returned by the query
      //(Optional in the case that there are no logs returned in the query)
      switch pageUnsafe.items->Belt.Array.get(pageUnsafe.items->Belt.Array.length - 1) {
      | Some({block}) if block->Types.Block.getNumber == heighestBlockQueried =>
        //If the last log item in the current page is equal to the
        //heighest block acounted for in the query. Simply return this
        //value without making an extra query

        (
          {
            blockNumber: block->Types.Block.getNumber,
            blockTimestamp: block->Types.Block.getTimestamp,
            blockHash: block->Types.Block.getId,
          }: ReorgDetection.blockDataWithTimestamp
        )->Promise.resolve
      //If it does not match it means that there were no matching logs in the last
      //block so we should fetch the block data
      | Some(_)
      | None =>
        //If there were no logs at all in the current page query then fetch the
        //timestamp of the heighest block accounted for
        HyperSync.queryBlockData(
          ~serverUrl=endpointUrl,
          ~apiToken,
          ~blockNumber=heighestBlockQueried,
          ~logger,
        )->Promise.thenResolve(res =>
          switch res {
          | Ok(Some(blockData)) => blockData
          | Ok(None) =>
            mkLogAndRaise(
              Not_found,
              ~msg=`Failure, blockData for block ${heighestBlockQueried->Int.toString} unexpectedly returned None`,
            )
          | Error(e) =>
            HyperSync.queryErrorToMsq(e)
            ->Obj.magic
            ->mkLogAndRaise(
              ~msg=`Failed to query blockData for block ${heighestBlockQueried->Int.toString}`,
            )
          }
        )
      }
    }

    let parsingTimeRef = Hrtime.makeTimer()

    //Parse page items into queue items
    let parsedQueueItems = []

    let handleDecodeFailure = (
      ~eventConfig: Internal.evmEventConfig,
      ~decoder,
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
            "decoder": decoder,
          },
        )
        exn->ErrorHandling.mkLogAndRaise(~msg, ~logger)
      }
    }
    if shouldUseHypersyncClientDecoder {
      //Currently there are still issues with decoder for some cases so
      //this can only be activated with a flag

      //Parse page items into queue items
      let parsedEvents = switch await getHscDecoder().decodeEvents(pageUnsafe.events) {
      | exception exn =>
        exn->mkLogAndRaise(
          ~msg="Failed to parse events using hypersync client, please double check your ABI.",
        )
      | parsedEvents => parsedEvents
      }

      pageUnsafe.items->Belt.Array.forEachWithIndex((index, item) => {
        let {block, log} = item
        let chainId = chain->ChainMap.Chain.toChainId
        let topic0 = log.topics->Js.Array2.unsafe_get(0)
        let maybeEventConfig =
          eventRouter->EventRouter.get(
            ~tag=EventRouter.getEvmEventId(
              ~sighash=topic0->EvmTypes.Hex.toString,
              ~topicCount=log.topics->Array.length,
            ),
            ~indexingContracts,
            ~contractAddress=log.address,
            ~blockNumber=block->Types.Block.getNumber,
          )
        let maybeDecodedEvent = parsedEvents->Js.Array2.unsafe_get(index)

        switch (maybeEventConfig, maybeDecodedEvent) {
        | (Some(eventConfig), Value(decoded)) =>
          parsedQueueItems
          ->Js.Array2.push(
            makeEventBatchQueueItem(
              item,
              ~params=decoded->eventConfig.convertHyperSyncEventArgs,
              ~eventConfig,
            ),
          )
          ->ignore
        | (Some(eventConfig), Null | Undefined) =>
          handleDecodeFailure(
            ~eventConfig,
            ~decoder="hypersync-client",
            ~logIndex=log.logIndex,
            ~blockNumber=block->Types.Block.getNumber,
            ~chainId,
            ~exn=UndefinedValue,
          )
        | (None, _) => () //ignore events that aren't registered
        }
      })
    } else {
      //Parse with viem -> slower than the HyperSyncClient
      pageUnsafe.items->Array.forEach(item => {
        let {block, log} = item
        let chainId = chain->ChainMap.Chain.toChainId
        let topic0 = log.topics->Js.Array2.unsafe_get(0)

        switch eventRouter->EventRouter.get(
          ~tag=EventRouter.getEvmEventId(
            ~sighash=topic0->EvmTypes.Hex.toString,
            ~topicCount=log.topics->Array.length,
          ),
          ~indexingContracts,
          ~contractAddress=log.address,
          ~blockNumber=block->Types.Block.getNumber,
        ) {
        | Some(eventConfig) =>
          switch contractNameAbiMapping->Viem.parseLogOrThrow(
            ~contractName=eventConfig.contractName,
            ~topics=log.topics,
            ~data=log.data,
          ) {
          | exception exn =>
            handleDecodeFailure(
              ~eventConfig,
              ~decoder="viem",
              ~logIndex=log.logIndex,
              ~blockNumber=block->Types.Block.getNumber,
              ~chainId,
              ~exn,
            )
          | decodedEvent =>
            parsedQueueItems
            ->Js.Array2.push(makeEventBatchQueueItem(item, ~params=decodedEvent.args, ~eventConfig))
            ->ignore
          }
        | None => () //Ignore events that aren't registered
        }
      })
    }

    let parsingTimeElapsed = parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let rangeLastBlock = await lastBlockQueriedPromise

    let reorgGuard: ReorgDetection.reorgGuard = {
      rangeLastBlock: rangeLastBlock->ReorgDetection.generalizeBlockDataWithTimestamp,
      prevRangeLastBlock: pageUnsafe.rollbackGuard->Option.map(v => {
        ReorgDetection.blockHash: v.firstParentHash,
        blockNumber: v.firstBlockNumber - 1,
      }),
    }

    let totalTimeElapsed = totalTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let stats = {
      totalTimeElapsed,
      parsingTimeElapsed,
      pageFetchTime,
    }

    {
      latestFetchedBlockTimestamp: rangeLastBlock.blockTimestamp,
      parsedQueueItems,
      latestFetchedBlockNumber: rangeLastBlock.blockNumber,
      stats,
      currentBlockHeight,
      reorgGuard,
      fromBlockQueried: fromBlock,
    }
  }

  let getBlockHashes = (~blockNumbers, ~logger) =>
    HyperSync.queryBlockDataMulti(
      ~serverUrl=endpointUrl,
      ~apiToken,
      ~blockNumbers,
      ~logger,
    )->Promise.thenResolve(HyperSync.mapExn)

  let jsonApiClient = Rest.client(endpointUrl)

  {
    name,
    sourceFor: Sync,
    chain,
    pollingInterval: 100,
    poweredByHyperSync: true,
    getBlockHashes,
    getHeightOrThrow: () =>
      HyperSyncJsonApi.heightRoute->Rest.fetch(apiToken, ~client=jsonApiClient),
    getItemsOrThrow,
  }
}
