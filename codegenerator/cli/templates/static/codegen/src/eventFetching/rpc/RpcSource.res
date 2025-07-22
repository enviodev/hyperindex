open Belt
open Source

exception QueryTimout(string)

let getKnownBlock = (provider, blockNumber) =>
  provider
  ->Ethers.JsonRpcProvider.getBlock(blockNumber)
  ->Promise.then(blockNullable =>
    switch blockNullable->Js.Nullable.toOption {
    | Some(block) => Promise.resolve(block)
    | None =>
      Promise.reject(
        Js.Exn.raiseError(`RPC returned null for blockNumber ${blockNumber->Belt.Int.toString}`),
      )
    }
  )

let rec getKnownBlockWithBackoff = async (~provider, ~blockNumber, ~backoffMsOnFailure) =>
  switch await getKnownBlock(provider, blockNumber) {
  | exception err =>
    Logging.warn({
      "err": err,
      "msg": `Issue while running fetching batch of events from the RPC. Will wait ${backoffMsOnFailure->Belt.Int.toString}ms and try again.`,
      "type": "EXPONENTIAL_BACKOFF",
    })
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=backoffMsOnFailure)
    await getKnownBlockWithBackoff(
      ~provider,
      ~blockNumber,
      ~backoffMsOnFailure=backoffMsOnFailure * 2,
    )
  | result => result
  }
let getSuggestedBlockIntervalFromExn = {
  // Unknown provider: "retry with the range 123-456"
  let suggestedRangeRegExp = %re(`/retry with the range (\d+)-(\d+)/`)

  // QuickNode, 1RPC, Blast: "limited to a 1000 blocks range"
  let blockRangeLimitRegExp = %re(`/limited to a (\d+) blocks range/`)

  // Alchemy: "up to a 500 block range"
  let alchemyRangeRegExp = %re(`/up to a (\d+) block range/`)

  // Cloudflare: "Max range: 3500"
  let cloudflareRangeRegExp = %re(`/Max range: (\d+)/`)

  // Thirdweb: "Maximum allowed number of requested blocks is 3500"
  let thirdwebRangeRegExp = %re(`/Maximum allowed number of requested blocks is (\d+)/`)

  // BlockPI: "limited to 2000 block"
  let blockpiRangeRegExp = %re(`/limited to (\d+) block/`)

  // Base: "block range too large" - fixed 2000 block limit
  let baseRangeRegExp = %re(`/block range too large/`)

  // evm-rpc.sei-apis.com: "block range too large (2000), maximum allowed is 1000 blocks"
  let maxAllowedBlocksRegExp = %re(`/maximum allowed is (\d+) blocks/`)

  // Blast (paid): "exceeds the range allowed for your plan (5000 > 3000)"
  let blastPaidRegExp = %re(`/exceeds the range allowed for your plan \(\d+ > (\d+)\)/`)

  // Chainstack: "Block range limit exceeded" - 10000 block limit
  let chainstackRegExp = %re(`/Block range limit exceeded./`)

  // Coinbase: "please limit the query to at most 1000 blocks"
  let coinbaseRegExp = %re(`/please limit the query to at most (\d+) blocks/`)

  // PublicNode: "maximum block range: 2000"
  let publicNodeRegExp = %re(`/maximum block range: (\d+)/`)

  // Hyperliquid: "query exceeds max block range 1000"
  let hyperliquidRegExp = %re(`/query exceeds max block range (\d+)/`)

  // TODO: Reproduce how the error message looks like
  // when we send request with numeric block range instead of hex
  // Infura, ZkSync: "Try with this block range [0x123,0x456]"

  // Future handling needed for these providers that don't suggest ranges:
  // - Ankr: "block range is too wide"
  // - 1RPC: "response size should not greater than 10000000 bytes"
  // - ZkEVM: "query returned more than 10000 results"
  // - LlamaRPC: "query exceeds max results"
  // - Optimism: "backend response too large" or "Block range is too large"
  // - Arbitrum: "logs matched by query exceeds limit of 10000"

  exn =>
    switch exn {
    | Js.Exn.Error(error) =>
      try {
        let message: string = (error->Obj.magic)["error"]["message"]
        message->S.assertOrThrow(S.string)

        // Helper to extract block range from regex match
        let extractBlockRange = execResult =>
          switch execResult->Js.Re.captures {
          | [_, Js.Nullable.Value(blockRangeLimit)] =>
            switch blockRangeLimit->Int.fromString {
            | Some(blockRangeLimit) if blockRangeLimit > 0 => Some(blockRangeLimit)
            | _ => None
            }
          | _ => None
          }

        // Try each regex pattern in order
        switch suggestedRangeRegExp->Js.Re.exec_(message) {
        | Some(execResult) =>
          switch execResult->Js.Re.captures {
          | [_, Js.Nullable.Value(fromBlock), Js.Nullable.Value(toBlock)] =>
            switch (fromBlock->Int.fromString, toBlock->Int.fromString) {
            | (Some(fromBlock), Some(toBlock)) if toBlock >= fromBlock =>
              Some(toBlock - fromBlock + 1)
            | _ => None
            }
          | _ => None
          }
        | None =>
          // Try each provider's specific error pattern
          switch blockRangeLimitRegExp->Js.Re.exec_(message) {
          | Some(execResult) => extractBlockRange(execResult)
          | None =>
            switch alchemyRangeRegExp->Js.Re.exec_(message) {
            | Some(execResult) => extractBlockRange(execResult)
            | None =>
              switch cloudflareRangeRegExp->Js.Re.exec_(message) {
              | Some(execResult) => extractBlockRange(execResult)
              | None =>
                switch thirdwebRangeRegExp->Js.Re.exec_(message) {
                | Some(execResult) => extractBlockRange(execResult)
                | None =>
                  switch blockpiRangeRegExp->Js.Re.exec_(message) {
                  | Some(execResult) => extractBlockRange(execResult)
                  | None =>
                    switch maxAllowedBlocksRegExp->Js.Re.exec_(message) {
                    | Some(execResult) => extractBlockRange(execResult)
                    | None =>
                      switch baseRangeRegExp->Js.Re.exec_(message) {
                      | Some(_) => Some(2000)
                      | None =>
                                                switch blastPaidRegExp->Js.Re.exec_(message) {
                        | Some(execResult) => extractBlockRange(execResult)
                        | None =>
                          switch chainstackRegExp->Js.Re.exec_(message) {
                          | Some(_) => Some(10000)
                          | None =>
                            switch coinbaseRegExp->Js.Re.exec_(message) {
                            | Some(execResult) => extractBlockRange(execResult)
                            | None =>
                              switch publicNodeRegExp->Js.Re.exec_(message) {
                              | Some(execResult) => extractBlockRange(execResult)
                              | None =>
                                switch hyperliquidRegExp->Js.Re.exec_(message) {
                                | Some(execResult) => extractBlockRange(execResult)
                                | None => None
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      } catch {
      | _ => None
      }
    | _ => None
    }
}

type eventBatchQuery = {
  logs: array<Ethers.log>,
  latestFetchedBlock: Ethers.JsonRpcProvider.block,
}

let getNextPage = (
  ~fromBlock,
  ~toBlock,
  ~addresses,
  ~topicQuery,
  ~loadBlock,
  ~syncConfig as sc: Config.syncConfig,
  ~provider,
  ~suggestedBlockIntervals,
  ~partitionId,
): promise<eventBatchQuery> => {
  //If the query hangs for longer than this, reject this promise to reduce the block interval
  let queryTimoutPromise =
    Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.queryTimeoutMillis)->Promise.then(() =>
      Promise.reject(
        QueryTimout(
          `Query took longer than ${Belt.Int.toString(sc.queryTimeoutMillis / 1000)} seconds`,
        ),
      )
    )

  let latestFetchedBlockPromise = loadBlock(toBlock)
  let logsPromise =
    provider
    ->Ethers.JsonRpcProvider.getLogs(
      ~filter={
        address: ?addresses,
        topics: topicQuery,
        fromBlock,
        toBlock,
      }->Ethers.CombinedFilter.toFilter,
    )
    ->Promise.then(async logs => {
      {
        logs,
        latestFetchedBlock: await latestFetchedBlockPromise,
      }
    })

  [queryTimoutPromise, logsPromise]
  ->Promise.race
  ->Promise.catch(err => {
    switch getSuggestedBlockIntervalFromExn(err) {
    | Some(nextBlockIntervalTry) =>
      suggestedBlockIntervals->Js.Dict.set(partitionId, nextBlockIntervalTry)
      raise(
        Source.GetItemsError(
          FailedGettingItems({
            exn: err,
            attemptedToBlock: toBlock,
            retry: WithSuggestedToBlock({
              toBlock: fromBlock + nextBlockIntervalTry - 1,
            }),
          }),
        ),
      )
    | None =>
      let executedBlockInterval = toBlock - fromBlock + 1
      let nextBlockIntervalTry =
        (executedBlockInterval->Belt.Int.toFloat *. sc.backoffMultiplicative)->Belt.Int.fromFloat
      suggestedBlockIntervals->Js.Dict.set(partitionId, nextBlockIntervalTry)
      raise(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn: err,
            attemptedToBlock: toBlock,
            retry: WithBackoff({
              message: `Failed getting data for the block range. Will try smaller block range for the next attempt.`,
              backoffMillis: sc.backoffMillis,
            }),
          }),
        ),
      )
    }
  })
}

type logSelection = {
  addresses: option<array<Address.t>>,
  topicQuery: Rpc.GetLogs.topicQuery,
}

type selectionConfig = {
  getLogSelectionOrThrow: (~addressesByContractName: dict<array<Address.t>>) => logSelection,
}

let getSelectionConfig = (selection: FetchState.selection, ~chain) => {
  let staticTopicSelections = []
  let dynamicEventFilters = []

  selection.eventConfigs
  ->(Utils.magic: array<Internal.eventConfig> => array<Internal.evmEventConfig>)
  ->Belt.Array.forEach(({getEventFiltersOrThrow}) => {
    switch getEventFiltersOrThrow(chain) {
    | Static(s) => staticTopicSelections->Js.Array2.pushMany(s)->ignore
    | Dynamic(fn) => dynamicEventFilters->Js.Array2.push(fn)->ignore
    }
  })

  let getLogSelectionOrThrow = switch (
    staticTopicSelections->LogSelection.compressTopicSelections,
    dynamicEventFilters,
  ) {
  | ([], []) =>
    raise(
      Source.GetItemsError(
        UnsupportedSelection({
          message: "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
        }),
      ),
    )
  | ([topicSelection], []) => {
      let topicQuery = topicSelection->Rpc.GetLogs.mapTopicQuery
      (~addressesByContractName) => {
        addresses: switch addressesByContractName->FetchState.addressesByContractNameGetAll {
        | [] => None
        | addresses => Some(addresses)
        },
        topicQuery,
      }
    }
  | ([], [dynamicEventFilter]) if selection.eventConfigs->Js.Array2.length === 1 =>
    let eventConfig = selection.eventConfigs->Js.Array2.unsafe_get(0)

    (~addressesByContractName) => {
      let addresses = addressesByContractName->FetchState.addressesByContractNameGetAll
      {
        addresses: eventConfig.isWildcard ? None : Some(addresses),
        topicQuery: switch dynamicEventFilter(addresses) {
        | [topicSelection] => topicSelection->Rpc.GetLogs.mapTopicQuery
        | _ =>
          raise(
            Source.GetItemsError(
              UnsupportedSelection({
                message: "RPC data-source currently doesn't support an array of event filters. Please, create a GitHub issue if it's a blocker for you.",
              }),
            ),
          )
        },
      }
    }
  | _ =>
    raise(
      Source.GetItemsError(
        UnsupportedSelection({
          message: "RPC data-source currently supports event filters only when there's a single wildcard event. Please, create a GitHub issue if it's a blocker for you.",
        }),
      ),
    )
  }

  {
    getLogSelectionOrThrow: getLogSelectionOrThrow,
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
  contracts: array<Internal.evmContractConfig>,
  eventRouter: EventRouter.t<Internal.evmEventConfig>,
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

  let provider = Ethers.JsonRpcProvider.make(~rpcUrl=url, ~chainId=chain->ChainMap.Chain.toChainId)

  let getSelectionConfig = memoGetSelectionConfig(~chain)

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
      getKnownBlockWithBackoff(~provider, ~backoffMsOnFailure=1000, ~blockNumber),
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
    ~addressesByContractName,
    ~indexingContracts,
    ~currentBlockHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~retry as _,
    ~logger as _,
  ) => {
    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    let suggestedBlockInterval =
      suggestedBlockIntervals
      ->Utils.Dict.dangerouslyGetNonOption(partitionId)
      ->Belt.Option.getWithDefault(syncConfig.initialBlockInterval)

    // Always have a toBlock for an RPC worker
    let toBlock = switch toBlock {
    | Some(toBlock) => Pervasives.min(toBlock, currentBlockHeight)
    | None => currentBlockHeight
    }

    let suggestedToBlock = Pervasives.min(fromBlock + suggestedBlockInterval - 1, toBlock)
    //Defensively ensure we never query a target block below fromBlock
    ->Pervasives.max(fromBlock)

    let firstBlockParentPromise =
      fromBlock > 0
        ? blockLoader->LazyLoader.get(fromBlock - 1)->Promise.thenResolve(res => res->Some)
        : Promise.resolve(None)

    let {getLogSelectionOrThrow} = getSelectionConfig(selection)
    let {addresses, topicQuery} = getLogSelectionOrThrow(~addressesByContractName)

    let {logs, latestFetchedBlock} = await getNextPage(
      ~fromBlock,
      ~toBlock=suggestedToBlock,
      ~addresses,
      ~topicQuery,
      ~loadBlock=blockNumber => blockLoader->LazyLoader.get(blockNumber),
      ~syncConfig,
      ~provider,
      ~suggestedBlockIntervals,
      ~partitionId,
    )

    let executedBlockInterval = suggestedToBlock - fromBlock + 1

    // Increase the suggested block interval only when it was actually applied
    // and we didn't query to a hard toBlock
    if executedBlockInterval >= suggestedBlockInterval {
      // Increase batch size going forward, but do not increase past a configured maximum
      // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
      suggestedBlockIntervals->Js.Dict.set(
        partitionId,
        Pervasives.min(
          executedBlockInterval + syncConfig.accelerationAdditive,
          syncConfig.intervalCeiling,
        ),
      )
    }

    let parsedQueueItems =
      await logs
      ->Belt.Array.keepMap(log => {
        let topic0 = log.topics->Js.Array2.unsafe_get(0)
        switch eventRouter->EventRouter.get(
          ~tag=EventRouter.getEvmEventId(
            ~sighash=topic0->EvmTypes.Hex.toString,
            ~topicCount=log.topics->Array.length,
          ),
          ~indexingContracts,
          ~contractAddress=log.address,
          ~blockNumber=log.blockNumber,
        ) {
        | None => None //ignore events that aren't registered
        | Some(eventConfig) =>
          let blockNumber = log.blockNumber
          let logIndex = log.logIndex
          Some(
            (
              async () => {
                let (block, transaction) = try await Promise.all2((
                  log->getEventBlockOrThrow,
                  log->getEventTransactionOrThrow(~transactionSchema=eventConfig.transactionSchema),
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
                  ~contractName=eventConfig.contractName,
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
                    eventConfig: (eventConfig :> Internal.eventConfig),
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
      prevRangeLastBlock: optFirstBlockParent->Option.map(b => {
        ReorgDetection.blockNumber: b.number,
        blockHash: b.hash,
      }),
      rangeLastBlock: {
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
