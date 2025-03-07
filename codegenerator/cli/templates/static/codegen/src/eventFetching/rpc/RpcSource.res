open Belt
open Source

type selectionConfig = {topics: array<array<EvmTypes.Hex.t>>}

let getSelectionConfig = (selection: FetchState.selection, ~contracts: array<Config.contract>) => {
  let includedTopicSelections = []

  contracts->Belt.Array.forEach(contract => {
    contract.events->Belt.Array.forEach(event => {
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
        includedTopicSelections->Js.Array2.pushMany(topicSelections)->ignore
      }
    })
  })

  let topicSelection = switch includedTopicSelections->LogSelection.compressTopicSelections {
  | [] =>
    raise(
      Source.GetItemsError(
        UnsupportedSelection({
          message: "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
        }),
      ),
    )
  | [topicSelection] => topicSelection
  | _ =>
    raise(
      Source.GetItemsError(
        UnsupportedSelection({
          message: "RPC data-source currently supports event filters only when there's a single wildcard event. Join our Discord channel, to get updates on the new releases.",
        }),
      ),
    )
  }

  // Some RPC providers would fail
  // if we don't strip trailing empty topics
  // also we need to change empty topics in the middle to null
  let topics = switch topicSelection {
  | {topic0, topic1: [], topic2: [], topic3: []} => [topic0]
  | {topic0, topic1, topic2: [], topic3: []} => [topic0, topic1]
  | {topic0, topic1: [], topic2, topic3: []} => [topic0, %raw(`null`), topic2]
  | {topic0, topic1, topic2, topic3: []} => [topic0, topic1, topic2]
  | {topic0, topic1: [], topic2: [], topic3} => [topic0, %raw(`null`), %raw(`null`), topic3]
  | {topic0, topic1: [], topic2, topic3} => [topic0, %raw(`null`), topic2, topic3]
  | {topic0, topic1, topic2: [], topic3} => [topic0, topic1, %raw(`null`), topic3]
  | {topic0, topic1, topic2, topic3} => [topic0, topic1, topic2, topic3]
  }

  {
    topics: topics,
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
          let transactionSchema = transactionSchema->S.removeTypeValidation

          let transactionFieldItems = switch transactionSchema->S.classify {
          | Object({items}) => items
          | _ => Js.Exn.raiseError("Unexpected internal error: transactionSchema is not an object")
          }

          let parseOrThrowReadableError = data => {
            try data->S.parseOrThrow(transactionSchema) catch {
            | S.Raised(error) =>
              Js.Exn.raiseError(
                `Invalid transaction field "${error.path
                  ->S.Path.toArray
                  ->Js.Array2.joinWith(
                    ".",
                  )}" found in the RPC response. Error: ${error->S.Error.reason}`,
              ) // There should always be only one field, but just in case split them with a dot
            }
          }

          let fn = switch transactionFieldItems {
          | [] => _ => %raw(`{}`)->Promise.resolve
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

let sanitizeUrl = (url: string) => {
  // Regular expression requiring protocol and capturing hostname
  // - (https?:\/\/) : Required http:// or https:// (capturing group)
  // - ([^\/?]+) : Capture hostname (one or more characters that aren't / or ?)
  // - .* : Match rest of the string
  let regex = %re("/https?:\/\/([^\/?]+).*/")

  switch Js.Re.exec_(regex, url) {
  | Some(result) =>
    switch Js.Re.captures(result)->Belt.Array.get(1) {
    | Some(host) => host->Js.Nullable.toOption
    | None => None
    }
  | None => None
  }
}

type options = {
  sourceFor: Source.sourceFor,
  syncConfig: Config.syncConfig,
  url: string,
  chain: ChainMap.Chain.t,
  contracts: array<Config.contract>,
  eventRouter: EventRouter.t<module(Types.InternalEvent)>,
}

let make = ({sourceFor, syncConfig, url, chain, contracts, eventRouter}: options): t => {
  let urlHost = switch sanitizeUrl(url) {
  | None =>
    Js.Exn.raiseError(
      `EE109: The RPC url "${url}" is incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  let provider = Ethers.JsonRpcProvider.make(
    ~rpcUrls=[url],
    ~chainId=chain->ChainMap.Chain.toChainId,
    ~fallbackStallTimeout=syncConfig.fallbackStallTimeout,
  )

  let getSelectionConfig = memoGetSelectionConfig(~contracts)

  let suggestedBlockIntervals = Js.Dict.empty()

  let transactionLoader = LazyLoader.make(
    ~loaderFn=transactionHash => provider->Ethers.JsonRpcProvider.getTransaction(~transactionHash),
    ~onError=(am, ~exn) => {
      Logging.error({
        "err": exn,
        "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
            ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
        "metadata": {
          {
            "asyncTaskName": "transactionLoader: fetching transaction data - `getTransaction` rpc call",
            "caller": "RPC Source",
            "suggestedFix": "This likely means the RPC url you are using is not responding correctly. Please try another RPC endipoint.",
          }
        },
      })
    },
  )

  let blockLoader = LazyLoader.make(
    ~loaderFn=blockNumber =>
      EventFetching.getKnownBlockWithBackoff(~provider, ~backoffMsOnFailure=1000, ~blockNumber),
    ~onError=(am, ~exn) => {
      Logging.error({
        "err": exn,
        "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
            ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
        "metadata": {
          {
            "asyncTaskName": "blockLoader: fetching block data - `getBlock` rpc call",
            "caller": "RPC Source",
            "suggestedFix": "This likely means the RPC url you are using is not responding correctly. Please try another RPC endipoint.",
          }
        },
      })
    },
  )

  let getEventBlockOrThrow = makeThrowingGetEventBlock(~getBlock=blockNumber =>
    blockLoader->LazyLoader.get(blockNumber)
  )
  let getEventTransactionOrThrow = makeThrowingGetEventTransaction(
    ~getTransactionFields=Ethers.JsonRpcProvider.makeGetTransactionFields(
      ~getTransactionByHash=LazyLoader.get(transactionLoader, _),
    ),
  )

  let contractNameAbiMapping = Js.Dict.empty()
  contracts->Belt.Array.forEach(contract => {
    contractNameAbiMapping->Js.Dict.set(contract.name, contract.abi)
  })

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~contractAddressMapping,
    ~currentBlockHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~logger,
  ) => {
    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    // Always have a toBlock for an RPC worker
    let toBlock = switch toBlock {
    | Some(toBlock) => Pervasives.min(toBlock, currentBlockHeight)
    | None => currentBlockHeight
    }

    let suggestedBlockInterval =
      suggestedBlockIntervals
      ->Utils.Dict.dangerouslyGetNonOption(partitionId)
      ->Belt.Option.getWithDefault(syncConfig.initialBlockInterval)

    let firstBlockParentPromise =
      fromBlock > 0
        ? blockLoader->LazyLoader.get(fromBlock - 1)->Promise.thenResolve(res => res->Some)
        : Promise.resolve(None)

    let {topics} = getSelectionConfig(selection)
    let addresses = switch contractAddressMapping->ContractAddressingMap.getAllAddresses {
    | [] => None
    | addresses => Some(addresses)
    }

    let {logs, nextSuggestedBlockInterval, latestFetchedBlock} = await EventFetching.getNextPage(
      ~fromBlock,
      ~toBlock,
      ~addresses,
      ~topics,
      ~loadBlock=blockNumber => blockLoader->LazyLoader.get(blockNumber),
      ~suggestedBlockInterval,
      ~syncConfig,
      ~provider,
      ~logger,
    )
    suggestedBlockIntervals->Js.Dict.set(partitionId, nextSuggestedBlockInterval)

    let parsedQueueItems =
      await logs
      ->Belt.Array.keepMap(log => {
        let topic0 = log.topics->Js.Array2.unsafe_get(0)
        switch eventRouter->EventRouter.get(
          ~tag=EventRouter.getEvmEventId(
            ~sighash=topic0->EvmTypes.Hex.toString,
            ~topicCount=log.topics->Array.length,
          ),
          ~contractAddressMapping,
          ~contractAddress=log.address,
        ) {
        | None => None //ignore events that aren't registered
        | Some(eventMod: module(Types.InternalEvent)) =>
          let module(Event) = eventMod
          let blockNumber = log.blockNumber
          let logIndex = log.logIndex
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
                  raise(
                    Source.GetItemsError(
                      FailedGettingFieldSelection({
                        message: "Failed getting selected fields. Please double-check your RPC provider returns correct data.",
                        exn,
                        blockNumber,
                        logIndex,
                      }),
                    ),
                  )
                }

                let decodedEvent = try contractNameAbiMapping->Viem.parseLogOrThrow(
                  ~contractName=Event.contractName,
                  ~topics=log.topics,
                  ~data=log.data,
                ) catch {
                | exn =>
                  raise(
                    Source.GetItemsError(
                      FailedParsingItems({
                        message: "Failed to parse event with viem, please double-check your ABI.",
                        exn,
                        blockNumber,
                        logIndex,
                      }),
                    ),
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
                      chainId: chain->ChainMap.Chain.toChainId,
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

    let optFirstBlockParent = await firstBlockParentPromise

    let totalTimeElapsed =
      startFetchingBatchTimeRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis

    let reorgGuard: ReorgDetection.reorgGuard = {
      firstBlockParentNumberAndHash: optFirstBlockParent->Option.map(b => {
        ReorgDetection.blockNumber: b.number,
        blockHash: b.hash,
      }),
      lastBlockScannedData: {
        blockNumber: latestFetchedBlock.number,
        blockHash: latestFetchedBlock.hash,
      },
    }

    {
      latestFetchedBlockTimestamp: latestFetchedBlock.timestamp,
      latestFetchedBlockNumber: latestFetchedBlock.number,
      parsedQueueItems,
      stats: {
        totalTimeElapsed: totalTimeElapsed,
      },
      currentBlockHeight,
      reorgGuard,
      fromBlockQueried: fromBlock,
    }
  }

  let getBlockHashes = (~blockNumbers, ~logger as _currentlyUnusedLogger) => {
    blockNumbers
    ->Array.map(blockNum => blockLoader->LazyLoader.get(blockNum))
    ->Promise.all
    ->Promise.thenResolve(blocks => {
      blocks
      ->Array.map((b): ReorgDetection.blockDataWithTimestamp => {
        blockNumber: b.number,
        blockHash: b.hash,
        blockTimestamp: b.timestamp,
      })
      ->Ok
    })
    ->Promise.catch(exn => exn->Error->Promise.resolve)
  }

  let client = Rest.client(url)

  {
    name,
    sourceFor,
    chain,
    poweredByHyperSync: false,
    pollingInterval: 1000,
    getBlockHashes,
    getHeightOrThrow: () => Rpc.GetBlockHeight.route->Rest.fetch((), ~client),
    getItemsOrThrow,
  }
}
