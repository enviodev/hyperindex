open ChainWorker
open Belt

exception EventRoutingFailed

let makeGetRecieptsSelectionOrThrow = (~contracts: array<Types.fuelContractConfig>) => {
  let logDataReceiptTypeSelection: array<Fuel.receiptType> = [LogData]
  let mintReceiptTypeSelection: array<Fuel.receiptType> = [Mint]

  // only transactions with status 1 (success)
  let txStatusSelection = [1]

  let nonWildcardRbsByContract = Js.Dict.empty()
  let contractsWithMint = Utils.Set.make()
  let wildcardMint = ref(false)
  let wildcardRbs = []

  let wildcardMintSelection: HyperFuelClient.QueryTypes.receiptSelection = {
    receiptType: mintReceiptTypeSelection,
    txStatus: txStatusSelection,
  }

  contracts->Array.forEach(contract => {
    let nonWildcardRbs = []
    contract.events->Array.forEach(eventConfig => {
      switch eventConfig {
      | {kind: Mint, isWildcard: true} =>
        if contractsWithMint->Utils.Set.size !== 0 {
          Js.Exn.raiseError(`Wildcard Mint event is not allowed together with non-wildcard Mint events`)
        }
        wildcardMint := true
      | {kind: Mint} => {
          if wildcardMint.contents {
            Js.Exn.raiseError(
              `Failed to register ${eventConfig.name} for contract ${contract.name} because Mint is already registered in wildcard mode`,
            )
          }
          if contractsWithMint->Utils.Set.has(contract.name) {
            Js.Exn.raiseError(`Only one Mint event is allowed per contract`)
          }
          contractsWithMint->Utils.Set.add(contract.name)->ignore
        }
      | {kind: LogData({logId}), isWildcard} => {
          let rb = logId->BigInt.fromStringUnsafe
          if isWildcard === true {
            wildcardRbs->Array.push(rb)->ignore
          } else {
            nonWildcardRbs->Array.push(rb)->ignore
          }
        }
      }
    })
    nonWildcardRbsByContract->Js.Dict.set(contract.name, nonWildcardRbs)
  })

  let maybeWildcardLogSelection = switch wildcardRbs {
  | [] => None
  | wildcardRbs =>
    Some(
      (
        {
          receiptType: logDataReceiptTypeSelection,
          txStatus: txStatusSelection,
          rb: wildcardRbs,
        }: HyperFuelClient.QueryTypes.receiptSelection
      ),
    )
  }

  (~contractAddressMapping, ~shouldApplyWildcards) => {
    let selection: array<HyperFuelClient.QueryTypes.receiptSelection> = []

    //Instantiate each time to add new registered contract addresses
    contracts->Array.forEach(contract => {
      switch contractAddressMapping->ContractAddressingMap.getAddressesFromContractName(
        ~contractName=contract.name,
      ) {
      | [] => ()
      | addresses => {
          if contractsWithMint->Utils.Set.has(contract.name) {
            selection
            ->Js.Array2.push({
              rootContractId: addresses,
              receiptType: mintReceiptTypeSelection,
              txStatus: txStatusSelection,
            })
            ->ignore
          }
          switch nonWildcardRbsByContract->Utils.Dict.dangerouslyGetNonOption(contract.name) {
          | None
          | Some([]) => ()
          | Some(nonWildcardRbs) =>
            selection
            ->Js.Array2.push({
              rootContractId: addresses,
              receiptType: logDataReceiptTypeSelection,
              txStatus: txStatusSelection,
              rb: nonWildcardRbs,
            })
            ->ignore
          }
        }
      }
    })

    if shouldApplyWildcards {
      if wildcardMint.contents {
        selection
        ->Array.push(wildcardMintSelection)
        ->ignore
      }
      switch maybeWildcardLogSelection {
      | None => ()
      | Some(wildcardLogSelection) =>
        selection
        ->Array.push(wildcardLogSelection)
        ->ignore
      }
    }

    selection
  }
}

module Make = (
  T: {
    let chain: ChainMap.Chain.t
    let contracts: array<Types.fuelContractConfig>
    let endpointUrl: string
    let eventModLookup: EventModLookup.t
  },
): S => {
  let name = "HyperFuel"
  let chain = T.chain
  let eventModLookup = T.eventModLookup

  module Helpers = {
    let rec queryLogsPageWithBackoff = async (
      ~backoffMsOnFailure=200,
      ~callDepth=0,
      ~maxCallDepth=15,
      query: unit => promise<HyperFuel.queryResponse<HyperFuel.logsQueryPage>>,
      logger: Pino.t,
    ) =>
      switch await query() {
      | Error(e) =>
        let msg = e->HyperFuel.queryErrorToMsq
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
  }

  /**
  Holds the value of the next page fetch happening concurrently to current page processing
  */
  type nextPageFetchRes = {
    page: HyperFuel.logsQueryPage,
    pageFetchTime: int,
  }

  let waitForBlockGreaterThanCurrentHeight = (~currentBlockHeight, ~logger) => {
    HyperFuel.pollForHeightGtOrEq(
      ~serverUrl=T.endpointUrl,
      ~blockNumber=currentBlockHeight,
      ~logger,
    )
  }

  let waitForNextBlockBeforeQuery = async (
    ~serverUrl,
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
      let currentBlockHeight = await HyperFuel.pollForHeightGtOrEq(
        ~serverUrl,
        ~blockNumber=fromBlock,
        ~logger,
      )

      setCurrentBlockHeight(currentBlockHeight)
    }
  }

  let getRecieptsSelectionOrThrow = makeGetRecieptsSelectionOrThrow(~contracts=T.contracts)

  let getNextPage = async (
    ~fromBlock,
    ~toBlock,
    ~currentBlockHeight,
    ~logger,
    ~setCurrentBlockHeight,
    ~contractAddressMapping,
    ~shouldApplyWildcards,
  ) => {
    //Wait for a valid range to query
    //This should never have to wait since we check that the from block is below the toBlock
    //this in the GlobalState reducer
    await waitForNextBlockBeforeQuery(
      ~serverUrl=T.endpointUrl,
      ~fromBlock,
      ~currentBlockHeight,
      ~setCurrentBlockHeight,
      ~logger,
    )

    //Instantiate each time to add new registered contract addresses
    let recieptsSelection = getRecieptsSelectionOrThrow(
      ~contractAddressMapping,
      ~shouldApplyWildcards,
    )

    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    //fetch batch
    let pageUnsafe = await Helpers.queryLogsPageWithBackoff(
      () =>
        HyperFuel.queryLogsPage(~serverUrl=T.endpointUrl, ~fromBlock, ~toBlock, ~recieptsSelection),
      logger,
    )

    let pageFetchTime =
      startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    {page: pageUnsafe, pageFetchTime}
  }

  let fetchBlockRange = async (
    ~query: blockRangeFetchArgs,
    ~logger,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
  ) => {
    let mkLogAndRaise = ErrorHandling.mkLogAndRaise(~logger, ...)
    try {
      let {fetchStateRegisterId, partitionId, fromBlock, contractAddressMapping, toBlock} = query
      let startFetchingBatchTimeRef = Hrtime.makeTimer()
      //fetch batch
      let {page: pageUnsafe, pageFetchTime} = await getNextPage(
        ~fromBlock,
        ~toBlock,
        ~currentBlockHeight,
        ~contractAddressMapping,
        ~logger,
        ~setCurrentBlockHeight,
        //Only apply wildcards on the first partition and root register
        //to avoid duplicate wildcard queries
        ~shouldApplyWildcards=fetchStateRegisterId == Root && partitionId == 0,
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
      > = // switch pageUnsafe.rollbackGuard {
      // //In the case a rollbackGuard is returned (this only happens at the head for unconfirmed blocks)
      // //use these values
      // | Some({blockNumber, timestamp, hash}) =>
      //   {
      //     ReorgDetection.blockNumber,
      //     blockTimestamp: timestamp,
      //     blockHash: hash,
      //   }->Promise.resolve
      // | None =>
      //The optional block and timestamp of the last item returned by the query
      //(Optional in the case that there are no logs returned in the query)
      switch pageUnsafe.items->Belt.Array.get(pageUnsafe.items->Belt.Array.length - 1) {
      | Some({block}) if block.blockNumber == heighestBlockQueried =>
        //If the last log item in the current page is equal to the
        //heighest block acounted for in the query. Simply return this
        //value without making an extra query
        {
          ReorgDetection.blockNumber: block.blockNumber,
          blockTimestamp: block.timestamp,
          blockHash: block.hash,
        }->Promise.resolve
      //If it does not match it means that there were no matching logs in the last
      //block so we should fetch the block data
      | Some(_)
      | None =>
        //If there were no logs at all in the current page query then fetch the
        //timestamp of the heighest block accounted for
        HyperFuel.queryBlockData(
          ~serverUrl=T.endpointUrl,
          ~blockNumber=heighestBlockQueried,
          ~logger,
        )
        ->Promise.thenResolve(res => {
          switch res {
          | Some(blockData) => blockData
          | None =>
            mkLogAndRaise(
              Not_found,
              ~msg=`Failure, blockData for block ${heighestBlockQueried->Int.toString} unexpectedly returned None`,
            )
          }
        })
        ->Promise.catch(exn => {
          exn->mkLogAndRaise(
            ~msg=`Failed to query blockData for block ${heighestBlockQueried->Int.toString}`,
          )
        })
      }

      let parsingTimeRef = Hrtime.makeTimer()

      let parsedQueueItems = pageUnsafe.items->Array.map(item => {
        let {contractId: contractAddress, receipt, block, receiptIndex} = item

        let chainId = chain->ChainMap.Chain.toChainId
        let sighash = switch receipt {
        | LogData({rb}) => BigInt.toString(rb)
        }

        let eventMod = switch eventModLookup->EventModLookup.get(
          ~tag=sighash,
          ~contractAddressMapping,
          ~contractAddress,
        ) {
        | None => {
            let logger = Logging.createChildFrom(
              ~logger,
              ~params={
                "chainId": chainId,
                "blockNumber": block.blockNumber,
                "logIndex": receiptIndex,
                "contractAddress": contractAddress,
                "sighash": sighash,
              },
            )
            EventRoutingFailed->ErrorHandling.mkLogAndRaise(
              ~msg="Failed to lookup registered event",
              ~logger,
            )
          }
        | Some(eventMod) => eventMod
        }
        let module(Event) = eventMod

        let params = try switch receipt {
        | LogData({data}) => data
        }->Event.decodeHyperFuelData catch {
        | exn => {
            let params = {
              "chainId": chainId,
              "blockNumber": block.blockNumber,
              "logIndex": receiptIndex,
            }
            let logger = Logging.createChildFrom(~logger, ~params)
            exn->ErrorHandling.mkLogAndRaise(
              ~msg="Failed to parse event with viem, please double check your ABI.",
              ~logger,
            )
          }
        }

        (
          {
            eventName: Event.name,
            contractName: Event.contractName,
            handlerRegister: Event.handlerRegister,
            paramsRawEventSchema: Event.paramsRawEventSchema,
            timestamp: block.timestamp,
            chain,
            blockNumber: block.blockNumber,
            logIndex: receiptIndex,
            event: {
              chainId,
              params,
              transaction: {
                "id": item.transactionId,
              }->Obj.magic, // TODO: Obj.magic needed until the field selection types are not configurable for Fuel and Evm separately
              block: {
                "height": block.blockNumber,
                "time": block.timestamp,
                "id": block.hash,
              }->Obj.magic,
              srcAddress: contractAddress,
              logIndex: receiptIndex,
            },
          }: Types.eventBatchQueueItem
        )
      })

      let parsingTimeElapsed =
        parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      let lastBlockScannedData = await lastBlockQueriedPromise

      let reorgGuard = {
        lastBlockScannedData,
        firstBlockParentNumberAndHash: Some({
          ReorgDetection.blockHash: lastBlockScannedData.blockHash,
          blockNumber: lastBlockScannedData.blockNumber,
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

  let getBlockHashes = (~blockNumbers as _, ~logger as _) =>
    Js.Exn.raiseError("HyperFuel does not support getting block hashes")
}
