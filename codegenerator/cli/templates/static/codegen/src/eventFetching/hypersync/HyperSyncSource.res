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

let getSelectionConfig = (selection: FetchState.selection, ~contracts: array<Config.contract>) => {
  let nonOptionalBlockFieldNames = Utils.Set.make()
  let nonOptionalTransactionFieldNames = Utils.Set.make()
  let capitalizedBlockFields = Utils.Set.make()
  let capitalizedTransactionFields = Utils.Set.make()
  let wildcardTopicSelections = []

  let contractTopicSelections = []

  contracts->Array.forEach(contract => {
    let normalTopicSelections = []

    contract.events->Array.forEach(event => {
      let module(Event) = event
      let {isWildcard, topicSelections} =
        Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions

      if (
        FetchState.checkIsInSelection(
          ~selection,
          ~contractName=contract.name,
          ~eventId=Event.id,
          ~isWildcard,
        )
      ) {
        nonOptionalBlockFieldNames->Utils.Set.addMany(
          Event.blockSchema->Utils.Schema.getNonOptionalFieldNames,
        )
        nonOptionalTransactionFieldNames->Utils.Set.addMany(
          Event.transactionSchema->Utils.Schema.getNonOptionalFieldNames,
        )
        capitalizedBlockFields->Utils.Set.addMany(
          Event.blockSchema->Utils.Schema.getCapitalizedFieldNames,
        )
        capitalizedTransactionFields->Utils.Set.addMany(
          Event.transactionSchema->Utils.Schema.getCapitalizedFieldNames,
        )
        if isWildcard {
          wildcardTopicSelections->Js.Array2.pushMany(topicSelections)->ignore
        } else {
          normalTopicSelections->Js.Array2.pushMany(topicSelections)->ignore
        }
      }
    })

    switch normalTopicSelections {
    | [] => ()
    | _ =>
      contractTopicSelections->Array.push({
        "contractName": contract.name,
        "topicSelections": normalTopicSelections,
      })
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
    contractTopicSelections->Belt.Array.keepMap((data): option<LogSelection.t> => {
      let contractName = data["contractName"]
      let topicSelections = data["topicSelections"]
      switch contractAddressMapping->ContractAddressingMap.getAddressesFromContractName(
        ~contractName,
      ) {
      | [] => None
      | addresses => Some(LogSelection.make(~addresses, ~topicSelections))
      }
    })
  }

  let getLogSelectionOrThrow = switch selection.isWildcard {
  | true =>
    let logSelections = [LogSelection.make(~addresses=[], ~topicSelections=wildcardTopicSelections)]
    (~contractAddressMapping as _) => {
      logSelections
    }
  | false => getNormalLogSelectionOrThrow
  }

  {
    getLogSelectionOrThrow,
    fieldSelection,
    nonOptionalBlockFieldNames: nonOptionalBlockFieldNames->Utils.Set.toArray,
    nonOptionalTransactionFieldNames: nonOptionalTransactionFieldNames->Utils.Set.toArray,
  }
}

let memoGetSelectionConfig = (~contracts) => {
  let cache = Utils.WeakMap.make()
  selection =>
    switch cache->Utils.WeakMap.get(selection) {
    | Some(c) => c
    | None => {
        let c = selection->getSelectionConfig(~contracts)
        let _ = cache->Utils.WeakMap.set(selection, c)
        c
      }
    }
}

type options = {
  contracts: array<Config.contract>,
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  allEventSignatures: array<string>,
  shouldUseHypersyncClientDecoder: bool,
  eventRouter: EventRouter.t<module(Types.InternalEvent)>,
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

  let getSelectionConfig = memoGetSelectionConfig(~contracts)

  let client = HyperSyncClient.make(
    ~url=endpointUrl,
    ~bearerToken=Env.envioApiToken,
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
    ~eventMod: module(Types.InternalEvent),
  ): Internal.eventItem => {
    let module(Event) = eventMod
    let {block, log, transaction} = item
    let chainId = chain->ChainMap.Chain.toChainId

    {
      eventName: Event.name,
      contractName: Event.contractName,
      loader: Event.handlerRegister->Types.HandlerTypes.Register.getLoader,
      handler: Event.handlerRegister->Types.HandlerTypes.Register.getHandler,
      contractRegister: Event.handlerRegister->Types.HandlerTypes.Register.getContractRegister,
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
      }->Internal.fromGenericEvent,
    }
  }

  let contractNameAbiMapping = Js.Dict.empty()
  contracts->Belt.Array.forEach(contract => {
    contractNameAbiMapping->Js.Dict.set(contract.name, contract.abi)
  })

  let fetchBlockRange = async (
    ~fromBlock,
    ~toBlock,
    ~contractAddressMapping,
    ~currentBlockHeight as _,
    ~partitionId as _,
    ~selection,
    ~logger,
  ) => {
    let mkLogAndRaise = ErrorHandling.mkLogAndRaise(~logger, ...)
    try {
      let totalTimeRef = Hrtime.makeTimer()

      let selectionConfig = selection->getSelectionConfig

      let logSelections = try selectionConfig.getLogSelectionOrThrow(
        ~contractAddressMapping,
      ) catch {
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
          let maybeEventMod =
            eventRouter->EventRouter.get(
              ~tag=EventRouter.getEvmEventId(
                ~sighash=topic0->EvmTypes.Hex.toString,
                ~topicCount=log.topics->Array.length,
              ),
              ~contractAddressMapping,
              ~contractAddress=log.address,
            )
          let maybeDecodedEvent = parsedEvents->Js.Array2.unsafe_get(index)

          switch (maybeEventMod, maybeDecodedEvent) {
          | (Some(eventMod), Value(decoded)) =>
            let module(Event) = eventMod
            parsedQueueItems
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
            ~tag=EventRouter.getEvmEventId(
              ~sighash=topic0->EvmTypes.Hex.toString,
              ~topicCount=log.topics->Array.length,
            ),
            ~contractAddressMapping,
            ~contractAddress=log.address,
          ) {
          | Some(eventMod) =>
            let module(Event) = eventMod

            switch contractNameAbiMapping->Viem.parseLogOrThrow(
              ~contractName=Event.contractName,
              ~topics=log.topics,
              ~data=log.data,
            ) {
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
              parsedQueueItems
              ->Js.Array2.push(makeEventBatchQueueItem(item, ~params=decodedEvent.args, ~eventMod))
              ->ignore
            }
          | None => () //Ignore events that aren't registered
          }
        })
      }

      let parsingTimeElapsed =
        parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

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
      }->Ok
    } catch {
    | exn => exn->ErrorHandling.make(~logger, ~msg="Failed to fetch block Range")->Error
    }
  }

  let getBlockHashes = (~blockNumbers, ~logger) =>
    HyperSync.queryBlockDataMulti(
      ~serverUrl=endpointUrl,
      ~blockNumbers,
      ~logger,
    )->Promise.thenResolve(HyperSync.mapExn)

  {
    name,
    chain,
    getBlockHashes,
    pollingInterval: 100,
    getHeightOrThrow: () => HyperSyncJsonApi.heightRoute->Rest.fetch(endpointUrl, ()),
    fetchBlockRange,
  }
}
