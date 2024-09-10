open ChainWorker
open Belt

exception EventRoutingFailed

module Make = (
  T: {
    let chain: ChainMap.Chain.t
    let contracts: array<Config.contract>
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

  let getNextPage = async (
    ~fromBlock,
    ~toBlock,
    ~currentBlockHeight,
    ~logger,
    ~setCurrentBlockHeight,
    ~contractAddressMapping,
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
    let contractsReceiptQuery = T.contracts->Belt.Array.keepMap((contract): option<
      HyperFuel.contractReceiptQuery,
    > => {
      switch contractAddressMapping->ContractAddressingMap.getAddressesFromContractName(
        ~contractName=contract.name,
      ) {
      | [] => None
      | addresses =>
        Some({
          addresses,
          rb: contract.events->Js.Array2.map(eventMod => {
            let module(Event: Types.Event) = eventMod
            Event.sighash->BigInt.fromStringUnsafe
          }),
        })
      }
    })

    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    //fetch batch
    let pageUnsafe = await Helpers.queryLogsPageWithBackoff(
      () =>
        HyperFuel.queryLogsPage(
          ~serverUrl=T.endpointUrl,
          ~fromBlock,
          ~toBlock,
          ~contractsReceiptQuery,
        ),
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
      // }

      let parsingTimeRef = Hrtime.makeTimer()

      let parsedQueueItems = pageUnsafe.items->Array.map(item => {
        let {contractId: contractAddress, receipt, block, receiptIndex} = item

        let chainId = chain->ChainMap.Chain.toChainId
        let sighash = switch receipt {
        | LogData({rb}) => BigInt.toString(rb)
        }

        let eventMod = switch eventModLookup->EventModLookup.get(
          ~sighash,
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
            timestamp: block.timestamp,
            chain,
            blockNumber: block.blockNumber,
            logIndex: receiptIndex,
            event: {
              chainId,
              params,
              transaction: {
                "hash": item.transactionId,
              }->Obj.magic, // TODO: Obj.magic needed until the field selection types are not configurable for Fuel and Evm separately
              block: {
                "number": block.blockNumber,
                "timestamp": block.timestamp,
                "hash": block.hash,
              }->Obj.magic,
              srcAddress: contractAddress,
              logIndex: receiptIndex,
            },
            eventMod,
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
