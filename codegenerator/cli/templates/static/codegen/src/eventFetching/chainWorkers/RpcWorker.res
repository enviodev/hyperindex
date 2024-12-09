open Belt
open ChainWorker

exception InvalidTransactionField({message: string})

let makeThrowingGetEventBlock = (~getBlock) => {
  // The block fields type is a subset of Ethers.JsonRpcProvider.block so we can safely cast
  let blockFieldsFromBlock: Ethers.JsonRpcProvider.block => Internal.eventBlock = Utils.magic

  async (log: Ethers.log): Internal.eventBlock => {
    (await getBlock(log.blockNumber))->blockFieldsFromBlock
  }
}

let makeThrowingGetEventTransaction = (~getTransactionFields) => {
  let fnsCache = Utils.WeakMap.make()
  (log, ~transactionSchema) => {
    (
      switch fnsCache->Utils.WeakMap.get(transactionSchema) {
      | Some(fn) => fn
      // This is not super expensive, but don't want to do it on every event
      | None => {
          transactionSchema->Utils.Schema.removeTypeValidationInPlace

          let transactionFieldItems = switch transactionSchema->S.classify {
          | Object({items}) => items
          | _ => Js.Exn.raiseError("Unexpected internal error: transactionSchema is not an object")
          }

          let parseOrThrowReadableError = data => {
            try data->S.parseAnyOrRaiseWith(transactionSchema) catch {
            | S.Raised(error) =>
              raise(
                InvalidTransactionField({
                  message: `Invalid transaction field "${error.path
                    ->S.Path.toArray
                    ->Js.Array2.joinWith(
                      ".",
                    )}" found in the RPC response. Error: ${error->S.Error.reason}`, // There should always be only one field, but just in case split them with a dot
                }),
              )
            }
          }

          let fn = switch transactionFieldItems {
          | [{location: "transactionIndex"}] =>
            log => log->parseOrThrowReadableError->Promise.resolve
          | [{location: "hash"}]
          | [{location: "hash"}, {location: "transactionIndex"}]
          | [{location: "transactionIndex"}, {location: "hash"}] =>
            (log: Ethers.log) =>
              {
                "hash": log.transactionHash,
                "transactionIndex": log.transactionIndex,
              }
              ->parseOrThrowReadableError
              ->Promise.resolve
          | _ =>
            log =>
              log
              ->getTransactionFields
              ->Promise.thenResolve(parseOrThrowReadableError)
          }
          let _ = fnsCache->Utils.WeakMap.set(transactionSchema, fn)
          fn
        }
      }
    )(log)
  }
}

module Make = (
  T: {
    let syncConfig: Config.syncConfig
    let provider: Ethers.JsonRpcProvider.t
    let chain: ChainMap.Chain.t
    let contracts: array<Config.contract>
    let eventRouter: EventRouter.t<module(Types.InternalEvent)>
  },
): S => {
  T.contracts->Belt.Array.forEach(contract => {
    contract.events->Belt.Array.forEach(event => {
      let module(Event) = event
      let {isWildcard, topicSelections} =
        Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions

      let logger = Logging.createChild(
        ~params={
          "chainId": T.chain->ChainMap.Chain.toChainId,
          "contractName": contract.name,
          "eventName": Event.name,
        },
      )
      if isWildcard {
        %raw(`null`)->ErrorHandling.mkLogAndRaise(
          ~msg="RPC worker does not yet support wildcard events",
          ~logger,
        )
      }

      topicSelections->Belt.Array.forEach(
        topicSelection => {
          if topicSelection->LogSelection.hasFilters {
            %raw(`null`)->ErrorHandling.mkLogAndRaise(
              ~msg="RPC worker does not yet support event filters",
              ~logger,
            )
          }
        },
      )
    })
  })

  let name = "RPC"
  let chain = T.chain
  let eventRouter = T.eventRouter

  let blockIntervals = Js.Dict.empty()

  let transactionLoader = LazyLoader.make(
    ~loaderFn=transactionHash =>
      T.provider->Ethers.JsonRpcProvider.getTransaction(~transactionHash),
    ~onError=(am, ~exn) => {
      Logging.error({
        "err": exn,
        "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
            ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
        "metadata": {
          {
            "asyncTaskName": "transactionLoader: fetching transaction data - `getTransaction` rpc call",
            "caller": "RPC ChainWorker",
            "suggestedFix": "This likely means the RPC url you are using is not responding correctly. Please try another RPC endipoint.",
          }
        },
      })
    },
  )

  let blockLoader = LazyLoader.make(
    ~loaderFn=blockNumber =>
      EventFetching.getKnownBlockWithBackoff(
        ~provider=T.provider,
        ~backoffMsOnFailure=1000,
        ~blockNumber,
      ),
    ~onError=(am, ~exn) => {
      Logging.error({
        "err": exn,
        "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
            ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
        "metadata": {
          {
            "asyncTaskName": "blockLoader: fetching block data - `getBlock` rpc call",
            "caller": "RPC ChainWorker",
            "suggestedFix": "This likely means the RPC url you are using is not responding correctly. Please try another RPC endipoint.",
          }
        },
      })
    },
  )

  let waitForBlockGreaterThanCurrentHeight = async (~currentBlockHeight, ~logger) => {
    let provider = T.provider
    let nextBlockWait = provider->EventUtils.waitForNextBlock
    let latestHeight =
      await provider
      ->Ethers.JsonRpcProvider.getBlockNumber
      ->Promise.catch(_err => {
        logger->Logging.childWarn("Error getting current block number")
        0->Promise.resolve
      })
    if latestHeight > currentBlockHeight {
      latestHeight
    } else {
      await nextBlockWait
    }
  }

  let getEventBlockOrThrow = makeThrowingGetEventBlock(~getBlock=blockNumber =>
    blockLoader->LazyLoader.get(blockNumber)
  )
  let getEventTransactionOrThrow = makeThrowingGetEventTransaction(
    ~getTransactionFields=Ethers.JsonRpcProvider.makeGetTransactionFields(
      ~getTransactionByHash=LazyLoader.get(transactionLoader, _),
    ),
  )

  let fetchBlockRange = async (
    ~query: blockRangeFetchArgs,
    ~logger,
    ~currentBlockHeight,
    ~isPreRegisteringDynamicContracts,
  ) => {
    try {
      if isPreRegisteringDynamicContracts {
        Js.Exn.raiseError("HyperIndex RPC does not support pre registering dynamic contracts yet")
      }
      let {fromBlock, toBlock, contractAddressMapping, fetchStateRegisterId, partitionId} = query

      let startFetchingBatchTimeRef = Hrtime.makeTimer()

      // Always have a toBlock for an RPC worker
      let toBlock = switch toBlock {
      | Some(toBlock) => Pervasives.min(toBlock, currentBlockHeight)
      | None => currentBlockHeight
      }

      let currentBlockInterval =
        blockIntervals
        ->Utils.Dict.dangerouslyGetNonOption(partitionId->Belt.Int.toString)
        ->Belt.Option.getWithDefault(T.syncConfig.initialBlockInterval)

      let targetBlock =
        Pervasives.min(toBlock, fromBlock + currentBlockInterval - 1)->Pervasives.max(fromBlock) //Defensively ensure we never query a target block below fromBlock

      let toBlockPromise = blockLoader->LazyLoader.get(targetBlock)

      let firstBlockParentPromise =
        fromBlock > 0
          ? blockLoader->LazyLoader.get(fromBlock - 1)->Promise.thenResolve(res => res->Some)
          : Promise.resolve(None)

      //Needs to be run on every loop in case of new registrations
      let contractInterfaceManager = ContractInterfaceManager.make(
        ~contracts=T.contracts,
        ~contractAddressMapping,
      )

      let {logs, finalExecutedBlockInterval} = await EventFetching.getNextPage(
        ~contractInterfaceManager,
        ~fromBlock,
        ~toBlock=targetBlock,
        ~initialBlockInterval=currentBlockInterval,
        ~minFromBlockLogIndex=0,
        ~syncConfig=T.syncConfig,
        ~provider=T.provider,
        ~logger,
      )
      blockIntervals->Js.Dict.set(partitionId->Belt.Int.toString, finalExecutedBlockInterval)

      let parsedQueueItems =
        await logs
        ->Belt.Array.keepMap(log => {
          let topic0 = log.topics->Js.Array2.unsafe_get(0)
          switch eventRouter->EventRouter.get(
            ~tag=EventRouter.getEvmEventTag(
              ~sighash=topic0->EvmTypes.Hex.toString,
              ~topicCount=log.topics->Array.length,
            ),
            ~contractAddressMapping=contractInterfaceManager.contractAddressMapping,
            ~contractAddress=log.address,
          ) {
          | None => None //ignore events that aren't registered
          | Some(eventMod: module(Types.InternalEvent)) =>
            let module(Event) = eventMod
            let chainId = chain->ChainMap.Chain.toChainId
            let logger = Logging.createChildFrom(
              ~logger,
              ~params={
                {
                  "chainId": chainId,
                  "blockNumber": log.blockNumber,
                  "logIndex": log.logIndex,
                }
              },
            )
            Some(
              (
                async () => {
                  let (block, transaction) = try await Promise.all2((
                    log->getEventBlockOrThrow,
                    log->getEventTransactionOrThrow(~transactionSchema=Event.transactionSchema),
                  )) catch {
                  // Promise.catch won't work here, because the error
                  // might be thrown before a microtask is created
                  | exn =>
                    exn->ErrorHandling.mkLogAndRaise(
                      ~msg="Failed getting selected fields. Please double-check your RPC provider returns correct data.",
                      ~logger,
                    )
                  }

                  let decodedEvent = try contractInterfaceManager->ContractInterfaceManager.parseLogViemOrThrow(
                    ~address=log.address,
                    ~topics=log.topics,
                    ~data=log.data,
                  ) catch {
                  | exn =>
                    exn->ErrorHandling.mkLogAndRaise(
                      ~msg="Failed to parse event with viem, please double-check your ABI.",
                      ~logger,
                    )
                  }

                  (
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
                        params: decodedEvent.args,
                        transaction,
                        block,
                        srcAddress: log.address,
                        logIndex: log.logIndex,
                      }->Internal.fromGenericEvent,
                    }: Internal.eventItem
                  )
                }
              )(),
            )
          }
        })
        ->Promise.all

      let (optFirstBlockParent, toBlock) = (await firstBlockParentPromise, await toBlockPromise)

      let heighestQueriedBlockNumber = targetBlock

      let totalTimeElapsed =
        startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

      let reorgGuard: reorgGuard = {
        firstBlockParentNumberAndHash: optFirstBlockParent->Option.map(b => {
          ReorgDetection.blockNumber: b.number,
          blockHash: b.hash,
        }),
        lastBlockScannedData: {
          blockNumber: toBlock.number,
          blockTimestamp: toBlock.timestamp,
          blockHash: toBlock.hash,
        },
      }

      {
        latestFetchedBlockTimestamp: toBlock.timestamp,
        parsedQueueItems,
        heighestQueriedBlockNumber,
        stats: {
          totalTimeElapsed: totalTimeElapsed,
        },
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

  let getBlockHashes = (~blockNumbers, ~logger as _currentlyUnusedLogger) => {
    blockNumbers
    ->Array.map(blockNum => blockLoader->LazyLoader.get(blockNum))
    ->Promise.all
    ->Promise.thenResolve(blocks => {
      blocks
      ->Array.map(b => {
        ReorgDetection.blockNumber: b.number,
        blockHash: b.hash,
        blockTimestamp: b.timestamp,
      })
      ->Ok
    })
    ->Promise.catch(exn => exn->Error->Promise.resolve)
  }
}
