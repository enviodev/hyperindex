open Source
open Belt

exception EventRoutingFailed

let mintEventTag = "mint"
let burnEventTag = "burn"
let transferEventTag = "transfer"
let callEventTag = "call"

type selectionConfig = {
  getRecieptsSelection: (
    ~addressesByContractName: dict<array<Address.t>>,
  ) => array<HyperFuelClient.QueryTypes.receiptSelection>,
  eventRouter: EventRouter.t<Internal.fuelEventConfig>,
}

let logDataReceiptTypeSelection: array<Fuel.receiptType> = [LogData]

// only transactions with status 1 (success)
let txStatusSelection = [1]

let makeGetNormalRecieptsSelection = (
  ~nonWildcardLogDataRbsByContract,
  ~nonLogDataReceiptTypesByContract,
  ~contractNames,
) => {
  (~addressesByContractName) => {
    let selection: array<HyperFuelClient.QueryTypes.receiptSelection> = []

    //Instantiate each time to add new registered contract addresses
    contractNames->Utils.Set.forEach(contractName => {
      switch addressesByContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
      | None
      | Some([]) => ()
      | Some(addresses) => {
          switch nonLogDataReceiptTypesByContract->Utils.Dict.dangerouslyGetNonOption(
            contractName,
          ) {
          | Some(receiptTypes) =>
            selection
            ->Js.Array2.push({
              rootContractId: addresses,
              receiptType: receiptTypes,
              txStatus: txStatusSelection,
            })
            ->ignore
          | None => ()
          }
          switch nonWildcardLogDataRbsByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
          | None
          | Some([]) => ()
          | Some(nonWildcardLogDataRbs) =>
            selection
            ->Js.Array2.push({
              rootContractId: addresses,
              receiptType: logDataReceiptTypeSelection,
              txStatus: txStatusSelection,
              rb: nonWildcardLogDataRbs,
            })
            ->ignore
          }
        }
      }
    })

    selection
  }
}

let makeWildcardRecieptsSelection = (~wildcardLogDataRbs, ~nonLogDataWildcardReceiptTypes) => {
  let selection: array<HyperFuelClient.QueryTypes.receiptSelection> = []

  switch nonLogDataWildcardReceiptTypes {
  | [] => ()
  | nonLogDataWildcardReceiptTypes =>
    selection
    ->Js.Array2.push(
      (
        {
          receiptType: nonLogDataWildcardReceiptTypes,
          txStatus: txStatusSelection,
        }: HyperFuelClient.QueryTypes.receiptSelection
      ),
    )
    ->ignore
  }

  switch wildcardLogDataRbs {
  | [] => ()
  | wildcardLogDataRbs =>
    selection
    ->Js.Array2.push(
      (
        {
          receiptType: logDataReceiptTypeSelection,
          txStatus: txStatusSelection,
          rb: wildcardLogDataRbs,
        }: HyperFuelClient.QueryTypes.receiptSelection
      ),
    )
    ->ignore
  }

  selection
}

let getSelectionConfig = (selection: FetchState.selection, ~chain) => {
  let eventRouter = EventRouter.empty()
  let nonWildcardLogDataRbsByContract = Js.Dict.empty()
  let wildcardLogDataRbs = []

  // This is for non-LogData events, since they don't have rb filter and can be grouped
  let nonLogDataReceiptTypesByContract = Js.Dict.empty()
  let nonLogDataWildcardReceiptTypes = []

  let addNonLogDataWildcardReceiptTypes = (receiptType: Fuel.receiptType) => {
    nonLogDataWildcardReceiptTypes->Array.push(receiptType)->ignore
  }
  let addNonLogDataReceiptType = (contractName, receiptType: Fuel.receiptType) => {
    switch nonLogDataReceiptTypesByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
    | None => nonLogDataReceiptTypesByContract->Js.Dict.set(contractName, [receiptType])
    | Some(receiptTypes) => receiptTypes->Array.push(receiptType)->ignore // Duplication prevented by EventRouter
    }
  }

  let contractNames = Utils.Set.make()

  selection.eventConfigs
  ->(Utils.magic: array<Internal.eventConfig> => array<Internal.fuelEventConfig>)
  ->Array.forEach(eventConfig => {
    let contractName = eventConfig.contractName
    if !eventConfig.isWildcard {
      let _ = contractNames->Utils.Set.add(contractName)
    }
    eventRouter->EventRouter.addOrThrow(
      eventConfig.id,
      eventConfig,
      ~contractName,
      ~eventName=eventConfig.name,
      ~chain,
      ~isWildcard=eventConfig.isWildcard,
    )

    switch eventConfig {
    | {kind: Mint, isWildcard: true} => addNonLogDataWildcardReceiptTypes(Mint)
    | {kind: Mint} => addNonLogDataReceiptType(contractName, Mint)
    | {kind: Burn, isWildcard: true} => addNonLogDataWildcardReceiptTypes(Burn)
    | {kind: Burn} => addNonLogDataReceiptType(contractName, Burn)
    | {kind: Transfer, isWildcard: true} => {
        addNonLogDataWildcardReceiptTypes(Transfer)
        addNonLogDataWildcardReceiptTypes(TransferOut)
      }
    | {kind: Transfer} => {
        addNonLogDataReceiptType(contractName, Transfer)
        addNonLogDataReceiptType(contractName, TransferOut)
      }
    | {kind: Call, isWildcard: true} => addNonLogDataWildcardReceiptTypes(Call)
    | {kind: Call} =>
      Js.Exn.raiseError("Call receipt indexing currently supported only in wildcard mode")
    | {kind: LogData({logId}), isWildcard} => {
        let rb = logId->BigInt.fromStringUnsafe
        if isWildcard {
          wildcardLogDataRbs->Array.push(rb)->ignore
        } else {
          switch nonWildcardLogDataRbsByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
          | Some(arr) => arr->Belt.Array.push(rb)
          | None => nonWildcardLogDataRbsByContract->Js.Dict.set(contractName, [rb])
          }
        }
      }
    }
  })

  {
    getRecieptsSelection: switch selection.dependsOnAddresses {
    | false => {
        let recieptsSelection = makeWildcardRecieptsSelection(
          ~wildcardLogDataRbs,
          ~nonLogDataWildcardReceiptTypes,
        )
        (~addressesByContractName as _) => recieptsSelection
      }
    | true =>
      makeGetNormalRecieptsSelection(
        ~nonWildcardLogDataRbsByContract,
        ~nonLogDataReceiptTypesByContract,
        ~contractNames,
      )
    },
    eventRouter,
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
  chain: ChainMap.Chain.t,
  endpointUrl: string,
}

let make = ({chain, endpointUrl}: options): t => {
  let name = "HyperFuel"

  let getSelectionConfig = memoGetSelectionConfig(~chain)

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~indexingContracts,
    ~currentBlockHeight,
    ~partitionId as _,
    ~selection: FetchState.selection,
    ~retry,
    ~logger,
  ) => {
    let mkLogAndRaise = ErrorHandling.mkLogAndRaise(~logger, ...)
    let totalTimeRef = Hrtime.makeTimer()

    let selectionConfig = getSelectionConfig(selection)
    let recieptsSelection = selectionConfig.getRecieptsSelection(~addressesByContractName)

    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    //fetch batch
    let pageUnsafe = try await HyperFuel.GetLogs.query(
      ~serverUrl=endpointUrl,
      ~fromBlock,
      ~toBlock,
      ~recieptsSelection,
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
                message: `Block #${fromBlock->Int.toString} not found in HyperFuel. HyperFuel has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${backoffMillis->Int.toString}ms.`,
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
              message: `Unexpected issue while fetching events from HyperFuel client. Attempt a retry.`,
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

    let lastBlockQueriedPromise = // switch pageUnsafe.rollbackGuard {
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
    | Some({block}) if block.height == heighestBlockQueried =>
      //If the last log item in the current page is equal to the
      //heighest block acounted for in the query. Simply return this
      //value without making an extra query

      (
        {
          blockNumber: block.height,
          blockTimestamp: block.time,
          blockHash: block.id,
        }: ReorgDetection.blockDataWithTimestamp
      )->Promise.resolve
    //If it does not match it means that there were no matching logs in the last
    //block so we should fetch the block data
    | Some(_)
    | None =>
      //If there were no logs at all in the current page query then fetch the
      //timestamp of the heighest block accounted for
      HyperFuel.queryBlockData(~serverUrl=endpointUrl, ~blockNumber=heighestBlockQueried, ~logger)
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
      let eventId = switch receipt {
      | LogData({rb}) => BigInt.toString(rb)
      | Mint(_) => mintEventTag
      | Burn(_) => burnEventTag
      | Transfer(_)
      | TransferOut(_) => transferEventTag
      | Call(_) => callEventTag
      }

      let eventConfig = switch selectionConfig.eventRouter->EventRouter.get(
        ~tag=eventId,
        ~indexingContracts,
        ~contractAddress,
        ~blockNumber=block.height,
      ) {
      | None => {
          let logger = Logging.createChildFrom(
            ~logger,
            ~params={
              "chainId": chainId,
              "blockNumber": block.height,
              "logIndex": receiptIndex,
              "contractAddress": contractAddress,
              "eventId": eventId,
            },
          )
          EventRoutingFailed->ErrorHandling.mkLogAndRaise(
            ~msg="Failed to route registered event",
            ~logger,
          )
        }
      | Some(eventConfig) => eventConfig
      }

      let params = switch (eventConfig, receipt) {
      | ({kind: LogData({decode})}, LogData({data})) =>
        try decode(data) catch {
        | exn => {
            let params = {
              "chainId": chainId,
              "blockNumber": block.height,
              "logIndex": receiptIndex,
            }
            let logger = Logging.createChildFrom(~logger, ~params)
            exn->ErrorHandling.mkLogAndRaise(
              ~msg="Failed to decode Fuel LogData receipt, please double check your ABI.",
              ~logger,
            )
          }
        }
      | (_, Mint({val, subId}))
      | (_, Burn({val, subId})) =>
        (
          {
            subId,
            amount: val,
          }: Internal.fuelSupplyParams
        )->Obj.magic
      | (_, Transfer({amount, assetId, to})) =>
        (
          {
            to: to->Address.unsafeFromString,
            assetId,
            amount,
          }: Internal.fuelTransferParams
        )->Obj.magic
      | (_, TransferOut({amount, assetId, toAddress})) =>
        (
          {
            to: toAddress->Address.unsafeFromString,
            assetId,
            amount,
          }: Internal.fuelTransferParams
        )->Obj.magic
      | (_, Call({amount, assetId, to})) =>
        (
          {
            to: to->Address.unsafeFromString,
            assetId,
            amount,
          }: Internal.fuelTransferParams
        )->Obj.magic
      // This should never happen unless there's a bug in the routing logic
      | _ => Js.Exn.raiseError("Unexpected bug in the event routing logic")
      }

      (
        {
          eventConfig: (eventConfig :> Internal.eventConfig),
          timestamp: block.time,
          chain,
          blockNumber: block.height,
          logIndex: receiptIndex,
          event: {
            chainId,
            params,
            transaction: {
              "id": item.transactionId,
            }->Obj.magic, // TODO: Obj.magic needed until the field selection types are not configurable for Fuel and Evm separately
            block: block->Obj.magic,
            srcAddress: contractAddress,
            logIndex: receiptIndex,
          },
        }: Internal.eventItem
      )
    })

    let parsingTimeElapsed = parsingTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let rangeLastBlock = await lastBlockQueriedPromise

    let reorgGuard: ReorgDetection.reorgGuard = {
      rangeLastBlock: rangeLastBlock->ReorgDetection.generalizeBlockDataWithTimestamp,
      prevRangeLastBlock: None,
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

  let getBlockHashes = (~blockNumbers as _, ~logger as _) =>
    Js.Exn.raiseError("HyperFuel does not support getting block hashes")

  let jsonApiClient = Rest.client(endpointUrl)

  {
    name,
    sourceFor: Sync,
    chain,
    getBlockHashes,
    pollingInterval: 100,
    poweredByHyperSync: true,
    getHeightOrThrow: () => HyperFuel.heightRoute->Rest.fetch((), ~client=jsonApiClient),
    getItemsOrThrow,
  }
}
