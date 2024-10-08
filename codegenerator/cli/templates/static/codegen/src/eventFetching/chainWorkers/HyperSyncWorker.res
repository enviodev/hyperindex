open ChainWorker
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

/**
Holds the value of the next page fetch happening concurrently to current page processing
*/
type nextPageFetchRes = {
  contractInterfaceManager: ContractInterfaceManager.t,
  page: HyperSync.logsQueryPage,
  pageFetchTime: int,
}

let makeGetNextPage = (
  ~endpointUrl,
  ~contracts: array<Config.contract>,
  ~queryLogsPage,
  ~pollForHeightGtOrEq,
  ~blockSchema,
  ~transactionSchema,
) => {
  let nonOptionalBlockFieldNames = blockSchema->Utils.Schema.getNonOptionalFieldNames
  let blockFieldSelection =
    blockSchema
    ->Utils.Schema.getCapitalizedFieldNames
    ->(Utils.magic: array<string> => array<HyperSyncClient.QueryTypes.blockField>)

  let nonOptionalTransactionFieldNames = transactionSchema->Utils.Schema.getNonOptionalFieldNames
  let transactionFieldSelection =
    transactionSchema
    ->Utils.Schema.getCapitalizedFieldNames
    ->(Utils.magic: array<string> => array<HyperSyncClient.QueryTypes.transactionField>)

  let fieldSelection: HyperSyncClient.QueryTypes.fieldSelection = {
    log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
    block: blockFieldSelection,
    transaction: transactionFieldSelection,
  }

  let waitForNextBlockBeforeQuery = async (
    ~fromBlock,
    ~currentBlockHeight,
    ~logger,
    ~setCurrentBlockHeight,
  ) => {
    if fromBlock > currentBlockHeight {
      logger->Logging.childTrace("Worker is caught up, awaiting new blocks")

      //If the block we want to query from is greater than the current height,
      //poll for until the archive height is greater than the from block and set
      //current height to the new height
      let currentBlockHeight = await pollForHeightGtOrEq(
        ~serverUrl=endpointUrl,
        ~blockNumber=fromBlock,
        ~logger,
      )

      setCurrentBlockHeight(currentBlockHeight)
    }
  }

  let contractPreregistrationEventOptions = contracts->Belt.Array.keepMap(contract => {
    let eventsOptions = contract.events->Belt.Array.keepMap(event => {
      let module(Event) = event
      let eventOptions = Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions

      if eventOptions.shouldPreRegisterDynamicContracts {
        Some(eventOptions)
      } else {
        None
      }
    })

    switch eventsOptions {
    | [] => None
    | _ => (contract.name, eventsOptions)->Some
    }
  })

  let getContractPreRegistrationLogSelection = (~contractAddressMapping): array<LogSelection.t> => {
    contractPreregistrationEventOptions->Array.map(((contractName, eventsOptions)) => {
      let addresses =
        contractAddressMapping->ContractAddressingMap.getAddressesFromContractName(~contractName)
      let topicSelections = eventsOptions->Belt.Array.flatMap(({isWildcard, topicSelections}) => {
        switch (isWildcard, addresses) {
        | (false, []) => [] //If it's not wildcard and there are no addresses. Skip the topic selections for this event
        | _ => topicSelections
        }
      })
      LogSelection.makeOrThrow(~addresses, ~topicSelections)
    })
  }

  let wildcardLogSelection = contracts->Belt.Array.flatMap(contract => {
    contract.events->Belt.Array.keepMap(event => {
      let module(Event) = event
      let {isWildcard, topicSelections} =
        Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions
      isWildcard ? Some(LogSelection.makeOrThrow(~addresses=[], ~topicSelections)) : None
    })
  })

  let getLogSelectionOrThrow = (~contractAddressMapping, ~shouldApplyWildcards): array<
    LogSelection.t,
  > => {
    let nonWildcardLogSelection = contracts->Belt.Array.keepMap((contract): option<
      LogSelection.t,
    > => {
      switch contractAddressMapping->ContractAddressingMap.getAddressesFromContractName(
        ~contractName=contract.name,
      ) {
      | [] => None
      | addresses =>
        switch contract.events->Belt.Array.flatMap(event => {
          let module(Event) = event
          let {isWildcard, topicSelections} =
            Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions

          isWildcard ? [] : topicSelections
        }) {
        | [] => None
        | topicSelections => Some(LogSelection.makeOrThrow(~addresses, ~topicSelections))
        }
      }
    })

    shouldApplyWildcards
      ? nonWildcardLogSelection->Array.concat(wildcardLogSelection)
      : nonWildcardLogSelection
  }

  async (
    ~fromBlock,
    ~toBlock,
    ~currentBlockHeight,
    ~logger,
    ~setCurrentBlockHeight,
    ~contractAddressMapping,
    ~shouldApplyWildcards,
    ~isPreRegisteringDynamicContracts,
  ) => {
    //Wait for a valid range to query
    //This should never have to wait since we check that the from block is below the toBlock
    //this in the GlobalState reducer
    await waitForNextBlockBeforeQuery(
      ~fromBlock,
      ~currentBlockHeight,
      ~setCurrentBlockHeight,
      ~logger,
    )

    //Instantiate each time to add new registered contract addresses
    let contractInterfaceManager = ContractInterfaceManager.make(
      ~contracts,
      ~contractAddressMapping,
    )

    let logSelections = try {
      if isPreRegisteringDynamicContracts {
        Js.log("pre-registering dynamic contracts hs query")
        getContractPreRegistrationLogSelection(~contractAddressMapping)
      } else {
        getLogSelectionOrThrow(~contractAddressMapping, ~shouldApplyWildcards)
      }
    } catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger,
        ~msg="Failed getting log selection in contract interface manager",
      )
    }

    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    //fetch batch
    let pageUnsafe = await Helpers.queryLogsPageWithBackoff(
      () =>
        queryLogsPage(
          ~serverUrl=endpointUrl,
          ~fromBlock,
          ~toBlock,
          ~logSelections,
          ~fieldSelection,
          ~nonOptionalBlockFieldNames,
          ~nonOptionalTransactionFieldNames,
        ),
      logger,
    )

    let pageFetchTime =
      startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    {page: pageUnsafe, contractInterfaceManager, pageFetchTime}
  }
}

module Make = (
  T: {
    let contracts: array<Config.contract>
    let chain: ChainMap.Chain.t
    let endpointUrl: string
    let allEventSignatures: array<string>
    let shouldUseHypersyncClientDecoder: bool
    let eventRouter: EventRouter.t<module(Types.InternalEvent)>
    let blockSchema: S.t<Types.Block.t>
    let transactionSchema: S.t<Types.Transaction.t>
  },
): S => {
  let name = "HyperSync"
  let chain = T.chain
  let eventRouter = T.eventRouter

  let hscDecoder: ref<option<HyperSyncClient.Decoder.t>> = ref(None)
  let getHscDecoder = () => {
    switch hscDecoder.contents {
    | Some(decoder) => decoder
    | None =>
      switch HyperSyncClient.Decoder.fromSignatures(T.allEventSignatures) {
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

  let waitForBlockGreaterThanCurrentHeight = (~currentBlockHeight, ~logger) => {
    HyperSync.pollForHeightGtOrEq(
      ~serverUrl=T.endpointUrl,
      ~blockNumber=currentBlockHeight,
      ~logger,
    )
  }

  exception UndefinedValue

  let makeEventBatchQueueItem = (
    item: HyperSync.logsQueryPageItem,
    ~params: Types.internalEventArgs,
    ~eventMod: module(Types.InternalEvent),
  ): Types.eventBatchQueueItem => {
    let module(Event) = eventMod
    let {block, log, transaction} = item
    let chainId = chain->ChainMap.Chain.toChainId
    {
      eventName: Event.name,
      contractName: Event.contractName,
      handlerRegister: Event.handlerRegister,
      paramsRawEventSchema: Event.paramsRawEventSchema,
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
      },
    }
  }

  let getNextPage = makeGetNextPage(
    ~endpointUrl=T.endpointUrl,
    ~contracts=T.contracts,
    ~queryLogsPage=HyperSync.queryLogsPage,
    ~pollForHeightGtOrEq=HyperSync.pollForHeightGtOrEq,
    ~blockSchema=T.blockSchema,
    ~transactionSchema=T.transactionSchema,
  )

  let fetchBlockRange = async (
    ~query: blockRangeFetchArgs,
    ~logger,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
    ~isPreRegisteringDynamicContracts,
  ) => {
    let mkLogAndRaise = ErrorHandling.mkLogAndRaise(~logger, ...)
    try {
      let {
        fetchStateRegisterId,
        partitionId,
        fromBlock,
        contractAddressMapping,
        toBlock,
        ?eventFilters,
      } = query
      let startFetchingBatchTimeRef = Hrtime.makeTimer()
      //fetch batch
      let {page: pageUnsafe, contractInterfaceManager, pageFetchTime} = await getNextPage(
        ~fromBlock,
        ~toBlock,
        ~currentBlockHeight,
        ~contractAddressMapping,
        ~logger,
        ~setCurrentBlockHeight,
        //Only apply wildcards on the first partition and root register
        //to avoid duplicate wildcard queries
        ~shouldApplyWildcards=fetchStateRegisterId == Root && partitionId == 0, //only
        ~isPreRegisteringDynamicContracts,
      )

      //set height and next from block
      let currentBlockHeight = pageUnsafe.archiveHeight

      logger->Logging.childTrace({
        "message": "Retrieved event page from server",
        "fromBlock": fromBlock,
        "toBlock": pageUnsafe.nextBlock - 1,
      })

      //The heighest (biggest) blocknumber that was accounted for in
      //Our query. Not necessarily the blocknumber of the last log returned
      //In the query
      let heighestBlockQueried = pageUnsafe.nextBlock - 1

      let lastBlockQueriedPromise: promise<
        ReorgDetection.blockData,
      > = switch pageUnsafe.rollbackGuard {
      //In the case a rollbackGuard is returned (this only happens at the head for unconfirmed blocks)
      //use these values
      | Some({blockNumber, timestamp, hash}) =>
        {
          ReorgDetection.blockNumber,
          blockTimestamp: timestamp,
          blockHash: hash,
        }->Promise.resolve
      | None =>
        //The optional block and timestamp of the last item returned by the query
        //(Optional in the case that there are no logs returned in the query)
        switch pageUnsafe.items->Belt.Array.get(pageUnsafe.items->Belt.Array.length - 1) {
        | Some({block}) if block->Types.Block.getNumber == heighestBlockQueried =>
          //If the last log item in the current page is equal to the
          //heighest block acounted for in the query. Simply return this
          //value without making an extra query
          {
            ReorgDetection.blockNumber: block->Types.Block.getNumber,
            blockTimestamp: block->Types.Block.getTimestamp,
            blockHash: block->Types.Block.getId,
          }->Promise.resolve
        //If it does not match it means that there were no matching logs in the last
        //block so we should fetch the block data
        | Some(_)
        | None =>
          //If there were no logs at all in the current page query then fetch the
          //timestamp of the heighest block accounted for
          HyperSync.queryBlockData(
            ~serverUrl=T.endpointUrl,
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
      let parsedQueueItemsPreFilter = []

      let handleDecodeFailure = (
        ~eventMod: module(Types.InternalEvent),
        ~decoder,
        ~logIndex,
        ~blockNumber,
        ~chainId,
        ~exn,
      ) => {
        let module(Event) = eventMod
        let {isWildcard} = Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions
        if !isWildcard {
          //Wildcard events can be parsed as undefined if the number of topics
          //don't match the event with the given topic0
          //Non wildcard events should be expected to be parsed
          let msg = `Event ${Event.name} was unexpectedly parsed as undefined`
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
      if T.shouldUseHypersyncClientDecoder {
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
          let maybeEventMod =
            eventRouter->EventRouter.get(
              ~tag=EventRouter.getEvmEventTag(
                ~sighash=topic0,
                ~topicCount=log.topics->Array.length,
              ),
              ~contractAddressMapping,
              ~contractAddress=log.address,
            )
          let maybeDecodedEvent = parsedEvents->Js.Array2.unsafe_get(index)

          switch (maybeEventMod, maybeDecodedEvent) {
          | (Some(eventMod), Value(decoded)) =>
            let module(Event) = eventMod
            parsedQueueItemsPreFilter
            ->Js.Array2.push(
              makeEventBatchQueueItem(
                item,
                ~params=decoded->Event.convertHyperSyncEventArgs,
                ~eventMod,
              ),
            )
            ->ignore
          | (Some(eventMod), Null | Undefined) =>
            handleDecodeFailure(
              ~eventMod,
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
            ~tag=EventRouter.getEvmEventTag(~sighash=topic0, ~topicCount=log.topics->Array.length),
            ~contractAddressMapping,
            ~contractAddress=log.address,
          ) {
          | Some(eventMod) =>
            let module(Event) = eventMod

            switch contractInterfaceManager->ContractInterfaceManager.parseLogViemOrThrow(~log) {
            | exception exn =>
              handleDecodeFailure(
                ~eventMod,
                ~decoder="viem",
                ~logIndex=log.logIndex,
                ~blockNumber=block->Types.Block.getNumber,
                ~chainId,
                ~exn,
              )
            | decodedEvent =>
              parsedQueueItemsPreFilter
              ->Js.Array2.push(makeEventBatchQueueItem(item, ~params=decodedEvent.args, ~eventMod))
              ->ignore
            }
          | None => () //Ignore events that aren't registered
          }
        })
      }

      let parsedQueueItems = switch eventFilters {
      //Most cases there are no filters so this will be passed throug
      | None => parsedQueueItemsPreFilter
      | Some(eventFilters) =>
        //In the case where there are filters, apply them and keep the events that
        //are needed
        parsedQueueItemsPreFilter->Array.keep(FetchState.applyFilters(~eventFilters, ...))
      }

      let parsingTimeElapsed =
        parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      let lastBlockScannedData = await lastBlockQueriedPromise

      let reorgGuard = {
        lastBlockScannedData,
        firstBlockParentNumberAndHash: pageUnsafe.rollbackGuard->Option.map(v => {
          ReorgDetection.blockHash: v.firstParentHash,
          blockNumber: v.firstBlockNumber - 1,
        }),
      }

      let totalTimeElapsed =
        startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      let stats = {
        totalTimeElapsed,
        parsingTimeElapsed,
        pageFetchTime,
        averageParseTimePerLog: parsingTimeElapsed->Belt.Int.toFloat /.
          parsedQueueItems->Array.length->Belt.Int.toFloat,
      }

      {
        latestFetchedBlockTimestamp: lastBlockScannedData.blockTimestamp,
        parsedQueueItems,
        heighestQueriedBlockNumber: lastBlockScannedData.blockNumber,
        stats,
        currentBlockHeight,
        reorgGuard,
        fromBlockQueried: fromBlock,
        fetchStateRegisterId,
        partitionId,
      }->Ok
    } catch {
    | exn => exn->ErrorHandling.make(~logger, ~msg="Failed to fetch block Range")->Error
    }
  }

  let getBlockHashes = (~blockNumbers, ~logger) =>
    HyperSync.queryBlockDataMulti(
      ~serverUrl=T.endpointUrl,
      ~blockNumbers,
      ~logger,
    )->Promise.thenResolve(HyperSync.mapExn)
}
