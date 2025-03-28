open Source
open Belt

module Helpers = {
  let rec queryLogsPageWithBackoff = async (
    ~backoffMsOnFailure=200,
    ~callDepth=0,
    ~maxCallDepth=15,
    query: unit => promise<HyperSync.queryResponse<HyperSync.logsQueryPage>>,
    logger: Pino.t,
  ) =>
    switch await query() {
    | Error(e) =>
      let msg = e->HyperSync.queryErrorToMsq
      if callDepth < maxCallDepth {
        logger->Logging.childWarn({
          "err": msg,
          "msg": `Issue while running fetching of events from Hypersync endpoint. Will wait ${backoffMsOnFailure->Belt.Int.toString}ms and try again.`,
          "type": "EXPONENTIAL_BACKOFF",
        })
        await Time.resolvePromiseAfterDelay(~delayMilliseconds=backoffMsOnFailure)
        await queryLogsPageWithBackoff(
          ~callDepth=callDepth + 1,
          ~backoffMsOnFailure=2 * backoffMsOnFailure,
          query,
          logger,
        )
      } else {
        logger->Logging.childError({
          "err": msg,
          "msg": `Issue while running fetching batch of events from Hypersync endpoint. Attempted query a maximum of ${maxCallDepth->string_of_int} times. Will NOT retry.`,
          "type": "EXPONENTIAL_BACKOFF_MAX_DEPTH",
        })
        Js.Exn.raiseError(msg)
      }
    | Ok(v) => v
    }

  exception ErrorMessage(string)
}

type selectionConfig = {
  getLogSelectionOrThrow: (
    ~contractAddressMapping: ContractAddressingMap.mapping,
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
  let wildcardTopicSelections = []

  let normalTopicSelectionsByContract = Js.Dict.empty()

  selection.eventConfigs
  ->(Utils.magic: array<Internal.eventConfig> => array<Internal.evmEventConfig>)
  ->Array.forEach(({
    isWildcard,
    contractName,
    getTopicSelectionsOrThrow,
    blockSchema,
    transactionSchema,
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
    let topicSelections = getTopicSelectionsOrThrow({
      chainId: chain->ChainMap.Chain.toChainId,
      addresses: [],
    })
    if isWildcard {
      wildcardTopicSelections->Js.Array2.pushMany(topicSelections)->ignore
    } else {
      switch normalTopicSelectionsByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
      | Some(arr) => arr->Js.Array2.pushMany(topicSelections)->ignore
      | None => normalTopicSelectionsByContract->Js.Dict.set(contractName, topicSelections)
      }
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

  let getNormalLogSelectionOrThrow = (~contractAddressMapping): array<LogSelection.t> => {
    normalTopicSelectionsByContract
    ->Js.Dict.keys
    ->Belt.Array.keepMap(contractName => {
      switch contractAddressMapping->ContractAddressingMap.getAddressesFromContractName(
        ~contractName,
      ) {
      | [] => None
      | addresses =>
        Some(
          LogSelection.make(
            ~addresses,
            ~topicSelections=normalTopicSelectionsByContract->Js.Dict.unsafeGet(contractName),
          ),
        )
      }
    })
  }

  let getLogSelectionOrThrow = switch selection.needsAddresses {
  | false =>
    let logSelections = [LogSelection.make(~addresses=[], ~topicSelections=wildcardTopicSelections)]
    (~contractAddressMapping as _) => {
      logSelections
    }
  | true => getNormalLogSelectionOrThrow
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
    ~contractAddressMapping,
    ~currentBlockHeight as _,
    ~partitionId as _,
    ~selection,
    ~logger,
  ) => {
    let mkLogAndRaise = ErrorHandling.mkLogAndRaise(~logger, ...)
    let totalTimeRef = Hrtime.makeTimer()

    let selectionConfig = selection->getSelectionConfig

    let logSelections = try selectionConfig.getLogSelectionOrThrow(~contractAddressMapping) catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed getting log selection for the query")
    }

    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    //fetch batch
    let pageUnsafe = await Helpers.queryLogsPageWithBackoff(() =>
      HyperSync.queryLogsPage(
        ~client,
        ~fromBlock,
        ~toBlock,
        ~logSelections,
        ~fieldSelection=selectionConfig.fieldSelection,
        ~nonOptionalBlockFieldNames=selectionConfig.nonOptionalBlockFieldNames,
        ~nonOptionalTransactionFieldNames=selectionConfig.nonOptionalTransactionFieldNames,
        ~logger=Logging.createChild(
          ~params={
            "type": "Hypersync Query",
            "fromBlock": fromBlock,
            "serverUrl": endpointUrl,
          },
        ),
      )
    , logger)

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
            Helpers.ErrorMessage(HyperSync.queryErrorToMsq(e))->mkLogAndRaise(
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
            ~contractAddressMapping,
            ~contractAddress=log.address,
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
          ~contractAddressMapping,
          ~contractAddress=log.address,
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

    let lastBlockScannedData = await lastBlockQueriedPromise

    let reorgGuard: ReorgDetection.reorgGuard = {
      lastBlockScannedData: lastBlockScannedData->ReorgDetection.generalizeBlockDataWithTimestamp,
      firstBlockParentNumberAndHash: pageUnsafe.rollbackGuard->Option.map(v => {
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
      latestFetchedBlockTimestamp: lastBlockScannedData.blockTimestamp,
      parsedQueueItems,
      latestFetchedBlockNumber: lastBlockScannedData.blockNumber,
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
