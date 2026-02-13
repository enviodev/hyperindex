open Belt
open Source

exception QueryTimout(string)

let getKnownBlock = async (~client, ~blockNumber) =>
  switch await Rpc.getBlock(~client, ~blockNumber) {
  | Some(block) => block
  | None =>
    Js.Exn.raiseError(`RPC returned null for blockNumber ${blockNumber->Belt.Int.toString}`)
  }

let getKnownBlockWithBackoff = async (
  ~client,
  ~sourceName,
  ~chain,
  ~blockNumber,
  ~backoffMsOnFailure,
  ~lowercaseAddresses: bool,
) => {
  let currentBackoff = ref(backoffMsOnFailure)
  let result = ref(None)

  while result.contents->Option.isNone {
    Prometheus.SourceRequestCount.increment(~sourceName, ~chainId=chain->ChainMap.Chain.toChainId)
    switch await getKnownBlock(~client, ~blockNumber) {
    | exception err =>
      Logging.warn({
        "err": err->Utils.prettifyExn,
        "msg": `Issue while running fetching batch of events from the RPC. Will wait ${currentBackoff.contents->Belt.Int.toString}ms and try again.`,
        "source": sourceName,
        "chainId": chain->ChainMap.Chain.toChainId,
        "type": "EXPONENTIAL_BACKOFF",
      })
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=currentBackoff.contents)
      currentBackoff := currentBackoff.contents * 2
    | block =>
      block.miner = if lowercaseAddresses {
        block.miner->Address.Evm.fromAddressLowercaseOrThrow
      } else {
        block.miner->Address.Evm.fromAddressOrThrow
      }
      result := Some(block)
    }
  }
  result.contents->Option.getExn
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

  let parseMessageForBlockRange = (message: string) => {
    // Helper to extract block range from regex match
    let extractBlockRange = (execResult, ~isMaxRange) =>
          switch execResult->Js.Re.captures {
          | [_, Js.Nullable.Value(blockRangeLimit)] =>
            switch blockRangeLimit->Int.fromString {
            | Some(blockRangeLimit) if blockRangeLimit > 0 => Some(blockRangeLimit, isMaxRange)
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
              Some(toBlock - fromBlock + 1, false)
            | _ => None
            }
          | _ => None
          }
        | None =>
          // Try each provider's specific error pattern
          switch blockRangeLimitRegExp->Js.Re.exec_(message) {
          | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
          | None =>
            switch alchemyRangeRegExp->Js.Re.exec_(message) {
            | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
            | None =>
              switch cloudflareRangeRegExp->Js.Re.exec_(message) {
              | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
              | None =>
                switch thirdwebRangeRegExp->Js.Re.exec_(message) {
                | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                | None =>
                  switch blockpiRangeRegExp->Js.Re.exec_(message) {
                  | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                  | None =>
                    switch maxAllowedBlocksRegExp->Js.Re.exec_(message) {
                    | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                    | None =>
                      switch baseRangeRegExp->Js.Re.exec_(message) {
                      | Some(_) => Some(2000, true)
                      | None =>
                        switch blastPaidRegExp->Js.Re.exec_(message) {
                        | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                        | None =>
                          switch chainstackRegExp->Js.Re.exec_(message) {
                          | Some(_) => Some(10000, true)
                          | None =>
                            switch coinbaseRegExp->Js.Re.exec_(message) {
                            | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                            | None =>
                              switch publicNodeRegExp->Js.Re.exec_(message) {
                              | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                              | None =>
                                switch hyperliquidRegExp->Js.Re.exec_(message) {
                                | Some(execResult) =>
                                  extractBlockRange(execResult, ~isMaxRange=true)
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
  }

  (exn): option<(
    // The suggested block range
    int,
    // Whether it's the max range that the provider allows
    bool,
  )> =>
    switch exn {
    | Rpc.JsonRpcError({message}) => parseMessageForBlockRange(message)
    | Js.Exn.Error(error) =>
      try {
        let message: string = (error->Obj.magic)["error"]["message"]
        message->S.assertOrThrow(S.string)
        parseMessageForBlockRange(message)
      } catch {
      | _ => None
      }
    | _ => None
    }
}

type eventBatchQuery = {
  logs: array<Rpc.GetLogs.log>,
  latestFetchedBlock: Rpc.GetBlockByNumber.block,
}

let maxSuggestedBlockIntervalKey = "max"

let getNextPage = (
  ~fromBlock,
  ~toBlock,
  ~addresses,
  ~topicQuery,
  ~loadBlock,
  ~syncConfig as sc: Config.sourceSync,
  ~client,
  ~mutSuggestedBlockIntervals,
  ~partitionId,
  ~sourceName,
  ~chainId,
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
  Prometheus.SourceRequestCount.increment(~sourceName, ~chainId)
  let logsPromise =
    Rpc.getLogs(
      ~client,
      ~param={
        address: ?addresses,
        topics: topicQuery,
        fromBlock,
        toBlock,
      },
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
    | Some((nextBlockIntervalTry, isMaxRange)) =>
      mutSuggestedBlockIntervals->Js.Dict.set(
        isMaxRange ? maxSuggestedBlockIntervalKey : partitionId,
        nextBlockIntervalTry,
      )
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
      mutSuggestedBlockIntervals->Js.Dict.set(partitionId, nextBlockIntervalTry)
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

let memoGetSelectionConfig = (~chain) =>
  Utils.WeakMap.memoize(selection => selection->getSelectionConfig(~chain))

let makeThrowingGetEventBlock = (~getBlock) => {
  async (log: Rpc.GetLogs.log) => {
    await getBlock(log.blockNumber)
  }
}

// Field source classification for RPC calls
type fieldSource = TransactionOnly | ReceiptOnly | Both

type fieldDef = {
  jsonKey: string,
  schema: S.t<Js.Json.t>, // Type-erased schema for the inner value (not nullable)
  source: fieldSource,
  isAddress: bool,
}

// Get a property from raw JSON object
let unsafeJsonGet: (Js.Json.t, string) => Js.Nullable.t<Js.Json.t> = %raw(`(obj, key) => obj[key]`)
// Set a property on a mutable JS object
let unsafeSet: ({..}, string, Js.Json.t) => unit = %raw(`(obj, key, val) => { obj[key] = val }`)

// Type-erase a schema for storage in the field registry
external toFieldSchema: S.t<'a> => S.t<Js.Json.t> = "%identity"

// Field registry: maps field location (= JS property name) to parsing info.
// Only includes fields that require an RPC call. Log-derived fields (hash, transactionIndex) are special-cased.
let fieldRegistry: Js.Dict.t<fieldDef> = Js.Dict.fromArray([
  // TransactionOnly fields (only in eth_getTransactionByHash)
  ("gas", {jsonKey: "gas", schema: Rpc.hexBigintSchema->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("gasPrice", {jsonKey: "gasPrice", schema: Rpc.hexBigintSchema->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("input", {jsonKey: "input", schema: S.string->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("nonce", {jsonKey: "nonce", schema: Rpc.hexBigintSchema->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("value", {jsonKey: "value", schema: Rpc.hexBigintSchema->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("v", {jsonKey: "v", schema: S.string->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("r", {jsonKey: "r", schema: S.string->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("s", {jsonKey: "s", schema: S.string->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("yParity", {jsonKey: "yParity", schema: S.string->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("maxPriorityFeePerGas", {jsonKey: "maxPriorityFeePerGas", schema: Rpc.hexBigintSchema->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("maxFeePerGas", {jsonKey: "maxFeePerGas", schema: Rpc.hexBigintSchema->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("maxFeePerBlobGas", {jsonKey: "maxFeePerBlobGas", schema: Rpc.hexBigintSchema->toFieldSchema, source: TransactionOnly, isAddress: false}),
  ("blobVersionedHashes", {jsonKey: "blobVersionedHashes", schema: S.array(S.string)->toFieldSchema, source: TransactionOnly, isAddress: false}),
  // ReceiptOnly fields (only in eth_getTransactionReceipt)
  ("gasUsed", {jsonKey: "gasUsed", schema: Rpc.hexBigintSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("cumulativeGasUsed", {jsonKey: "cumulativeGasUsed", schema: Rpc.hexBigintSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("effectiveGasPrice", {jsonKey: "effectiveGasPrice", schema: Rpc.hexBigintSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("contractAddress", {jsonKey: "contractAddress", schema: S.string->toFieldSchema, source: ReceiptOnly, isAddress: true}),
  ("logsBloom", {jsonKey: "logsBloom", schema: S.string->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("root", {jsonKey: "root", schema: S.string->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("status", {jsonKey: "status", schema: Rpc.hexIntSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("l1Fee", {jsonKey: "l1Fee", schema: Rpc.hexBigintSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("l1GasPrice", {jsonKey: "l1GasPrice", schema: Rpc.hexBigintSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("l1GasUsed", {jsonKey: "l1GasUsed", schema: Rpc.hexBigintSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("l1FeeScalar", {jsonKey: "l1FeeScalar", schema: Rpc.decimalFloatSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  ("gasUsedForL1", {jsonKey: "gasUsedForL1", schema: Rpc.hexBigintSchema->toFieldSchema, source: ReceiptOnly, isAddress: false}),
  // Both fields (available in both eth_getTransactionByHash and eth_getTransactionReceipt)
  ("from", {jsonKey: "from", schema: S.string->toFieldSchema, source: Both, isAddress: true}),
  ("to", {jsonKey: "to", schema: S.string->toFieldSchema, source: Both, isAddress: true}),
  ("type", {jsonKey: "type", schema: Rpc.hexIntSchema->toFieldSchema, source: Both, isAddress: false}),
])

type fetchStrategy = NoRpc | TransactionOnly | ReceiptOnly | TransactionAndReceipt

let makeThrowingGetEventTransaction = (
  ~getTransactionJson: string => promise<Js.Json.t>,
  ~getReceiptJson: string => promise<Js.Json.t>,
  ~lowercaseAddresses: bool,
) => {
  let fnsCache = Utils.WeakMap.make()
  (log, ~transactionSchema) => {
    (
      switch fnsCache->Utils.WeakMap.get(transactionSchema) {
      | Some(fn) => fn
      // Build per-field parser on first call, then cache in WeakMap
      | None => {
          let transactionSchema = transactionSchema->S.removeTypeValidation

          let transactionFieldItems = switch transactionSchema->S.classify {
          | Object({items}) => items
          | _ => Js.Exn.raiseError("Unexpected internal error: transactionSchema is not an object")
          }

          // Classify fields: log-derived vs RPC fields
          // For each RPC field, look up source and determine which JSON to extract from
          let hasTransactionOnly = ref(false)
          let hasReceiptOnly = ref(false)
          let hasShared = ref(false)
          let logFields: array<S.item> = []
          let rpcFields: array<(S.item, fieldDef)> = []

          transactionFieldItems->Array.forEach(item => {
            switch item.location {
            | "transactionIndex" | "hash" => logFields->Js.Array2.push(item)->ignore
            | _ =>
              switch fieldRegistry->Js.Dict.get(item.location) {
              | Some(def) => {
                  rpcFields->Js.Array2.push((item, def))->ignore
                  switch def.source {
                  | TransactionOnly => hasTransactionOnly := true
                  | ReceiptOnly => hasReceiptOnly := true
                  | Both => hasShared := true
                  }
                }
              | None => () // Unknown field — skip silently
              }
            }
          })

          // Determine fetch strategy
          let strategy = switch (
            hasTransactionOnly.contents,
            hasReceiptOnly.contents,
            hasShared.contents,
          ) {
          | (false, false, false) if logFields->Array.length > 0 => NoRpc
          | (false, false, false) => NoRpc
          | (true, true, _) => TransactionAndReceipt
          | (true, false, _) => TransactionOnly
          | (false, true, _) | (false, false, true) => ReceiptOnly
          }

          // Assign each Both field to an actual JSON source
          // Use whichever source is already being fetched; default to receipt
          let assignedSource = (def: fieldDef) =>
            switch def.source {
            | TransactionOnly => #transaction
            | ReceiptOnly => #receipt
            | Both =>
              switch strategy {
              | TransactionOnly => #transaction
              | _ => #receipt
              }
            }

          let fn = switch (transactionFieldItems, strategy) {
          | ([], _) => _ => %raw(`{}`)->Promise.resolve
          | (_, NoRpc) =>
            // All fields are log-derived
            (log: Rpc.GetLogs.log) => {
              let result: {..} = %raw(`{}`)
              logFields->Array.forEach(item => {
                switch item.location {
                | "transactionIndex" =>
                  unsafeSet(
                    result,
                    "transactionIndex",
                    log.transactionIndex->(Utils.magic: int => Js.Json.t),
                  )
                | "hash" =>
                  unsafeSet(
                    result,
                    "hash",
                    log.transactionHash->(Utils.magic: string => Js.Json.t),
                  )
                | _ => ()
                }
              })
              (result->(Utils.magic: {..} => 'a))->Promise.resolve
            }
          | (_, _) =>
            (log: Rpc.GetLogs.log) => {
              // Fetch needed JSON(s)
              let txJsonPromise = switch strategy {
              | TransactionOnly | TransactionAndReceipt =>
                getTransactionJson(log.transactionHash)->Promise.thenResolve(v => Some(v))
              | _ => Promise.resolve(None)
              }
              let receiptJsonPromise = switch strategy {
              | ReceiptOnly | TransactionAndReceipt =>
                getReceiptJson(log.transactionHash)->Promise.thenResolve(v => Some(v))
              | _ => Promise.resolve(None)
              }

              Promise.all2((txJsonPromise, receiptJsonPromise))->Promise.thenResolve(((
                txJson,
                receiptJson,
              )) => {
                let result: {..} = %raw(`{}`)

                // Set log-derived fields
                logFields->Array.forEach(item => {
                  switch item.location {
                  | "transactionIndex" =>
                    unsafeSet(
                      result,
                      "transactionIndex",
                      log.transactionIndex->(Utils.magic: int => Js.Json.t),
                    )
                  | "hash" =>
                    unsafeSet(
                      result,
                      "hash",
                      log.transactionHash->(Utils.magic: string => Js.Json.t),
                    )
                  | _ => ()
                  }
                })

                // Parse RPC fields from raw JSON
                rpcFields->Array.forEach(((item, def)) => {
                  let json = switch assignedSource(def) {
                  | #transaction => txJson
                  | #receipt => receiptJson
                  }
                  switch json {
                  | None => ()
                  | Some(json) =>
                    switch unsafeJsonGet(json, def.jsonKey)->Js.Nullable.toOption {
                    | None => ()
                    | Some(raw) =>
                      if def.isAddress {
                        let str: string = raw->(Utils.magic: Js.Json.t => string)
                        let addr = if lowercaseAddresses {
                          str->Js.String2.toLowerCase->Address.unsafeFromString
                        } else {
                          str->Address.Evm.fromStringOrThrow
                        }
                        unsafeSet(
                          result,
                          item.location,
                          addr->(Utils.magic: Address.t => Js.Json.t),
                        )
                      } else {
                        try {
                          let parsed = raw->S.parseOrThrow(def.schema)
                          unsafeSet(result, item.location, parsed)
                        } catch {
                        | S.Raised(error) =>
                          Js.Exn.raiseError(
                            `Invalid transaction field "${item.location}" found in the RPC response. Error: ${error->S.Error.reason}`,
                          )
                        }
                      }
                    }
                  }
                })

                result->(Utils.magic: {..} => 'a)
              })
            }
          }
          let _ = fnsCache->Utils.WeakMap.set(transactionSchema, fn)
          fn
        }
      }
    )(log)
  }
}

type options = {
  sourceFor: Source.sourceFor,
  syncConfig: Config.sourceSync,
  url: string,
  chain: ChainMap.Chain.t,
  eventRouter: EventRouter.t<Internal.evmEventConfig>,
  allEventSignatures: array<string>,
  lowercaseAddresses: bool,
  ws?: string,
}

let make = (
  {sourceFor, syncConfig, url, chain, eventRouter, allEventSignatures, lowercaseAddresses, ?ws}: options,
): t => {
  let chainId = chain->ChainMap.Chain.toChainId
  let urlHost = switch Utils.Url.getHostFromUrl(url) {
  | None =>
    Js.Exn.raiseError(
      `EE109: The RPC url for chain ${chainId->Belt.Int.toString} is in incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  let getSelectionConfig = memoGetSelectionConfig(~chain)

  let mutSuggestedBlockIntervals = Js.Dict.empty()

  let client = Rpc.makeClient(url)

  let makeTransactionLoader = () =>
    LazyLoader.make(
      ~loaderFn=transactionHash => {
        Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId=chain->ChainMap.Chain.toChainId)
        Rpc.GetTransactionByHash.rawRoute->Rest.fetch(transactionHash, ~client)
      },
      ~onError=(am, ~exn) => {
        Logging.error({
          "err": exn->Utils.prettifyExn,
          "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
              ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
          "source": name,
          "chainId": chain->ChainMap.Chain.toChainId,
          "metadata": {
            {
              "asyncTaskName": "transactionLoader: fetching transaction data - `getTransaction` rpc call",
              "suggestedFix": "This likely means the RPC url you are using is not responding correctly. Please try another RPC endipoint.",
            }
          },
        })
      },
    )

  let makeBlockLoader = () =>
    LazyLoader.make(
      ~loaderFn=blockNumber =>
        getKnownBlockWithBackoff(
          ~client,
          ~sourceName=name,
          ~chain,
          ~backoffMsOnFailure=1000,
          ~blockNumber,
          ~lowercaseAddresses,
        ),
      ~onError=(am, ~exn) => {
        Logging.error({
          "err": exn->Utils.prettifyExn,
          "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
              ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
          "source": name,
          "chainId": chain->ChainMap.Chain.toChainId,
          "metadata": {
            {
              "asyncTaskName": "blockLoader: fetching block data - `getBlock` rpc call",
              "suggestedFix": "This likely means the RPC url you are using is not responding correctly. Please try another RPC endipoint.",
            }
          },
        })
      },
    )

  let makeReceiptLoader = () =>
    LazyLoader.make(
      ~loaderFn=transactionHash => {
        Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId=chain->ChainMap.Chain.toChainId)
        Rpc.GetTransactionReceipt.rawRoute->Rest.fetch(transactionHash, ~client)
      },
      ~onError=(am, ~exn) => {
        Logging.error({
          "err": exn->Utils.prettifyExn,
          "msg": `EE1100: Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
              ->Belt.Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
          "source": name,
          "chainId": chain->ChainMap.Chain.toChainId,
          "metadata": {
            {
              "asyncTaskName": "receiptLoader: fetching transaction receipt - `getTransactionReceipt` rpc call",
              "suggestedFix": "This likely means the RPC url you are using is not responding correctly. Please try another RPC endipoint.",
            }
          },
        })
      },
    )

  let blockLoader = ref(makeBlockLoader())
  let transactionLoader = ref(makeTransactionLoader())
  let receiptLoader = ref(makeReceiptLoader())

  let getEventBlockOrThrow = makeThrowingGetEventBlock(~getBlock=blockNumber =>
    blockLoader.contents->LazyLoader.get(blockNumber)
  )
  let getEventTransactionOrThrow = makeThrowingGetEventTransaction(
    ~getTransactionJson=async transactionHash => {
      switch await transactionLoader.contents->LazyLoader.get(transactionHash) {
      | Some(json) => json
      | None => Js.Exn.raiseError(`Transaction not found for hash: ${transactionHash}`)
      }
    },
    ~getReceiptJson=async transactionHash => {
      switch await receiptLoader.contents->LazyLoader.get(transactionHash) {
      | Some(json) => json
      | None => Js.Exn.raiseError(`Transaction receipt not found for hash: ${transactionHash}`)
      }
    },
    ~lowercaseAddresses,
  )

  let convertLogToHyperSyncEvent = (log: Rpc.GetLogs.log): HyperSyncClient.ResponseTypes.event => {
    let hyperSyncLog: HyperSyncClient.ResponseTypes.log = {
      removed: log.removed,
      index: log.logIndex,
      transactionIndex: log.transactionIndex,
      transactionHash: log.transactionHash,
      blockHash: log.blockHash,
      blockNumber: log.blockNumber,
      address: log.address,
      data: log.data,
      topics: log.topics->(Utils.magic: array<string> => array<Js.Nullable.t<EvmTypes.Hex.t>>),
    }
    {log: hyperSyncLog}
  }

  let hscDecoder: ref<option<HyperSyncClient.Decoder.t>> = ref(None)
  let getHscDecoder = () => {
    switch hscDecoder.contents {
    | Some(decoder) => decoder
    | None => {
        let decoder = HyperSyncClient.Decoder.fromSignatures(allEventSignatures)
        decoder
      }
    }
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~indexingContracts,
    ~knownHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~retry as _,
    ~logger as _,
  ) => {
    let startFetchingBatchTimeRef = Hrtime.makeTimer()

    let suggestedBlockInterval = switch mutSuggestedBlockIntervals->Utils.Dict.dangerouslyGetNonOption(
      maxSuggestedBlockIntervalKey,
    ) {
    | Some(maxSuggestedBlockInterval) => maxSuggestedBlockInterval
    | None =>
      mutSuggestedBlockIntervals
      ->Utils.Dict.dangerouslyGetNonOption(partitionId)
      ->Belt.Option.getWithDefault(syncConfig.initialBlockInterval)
    }

    // Always have a toBlock for an RPC worker
    let toBlock = switch toBlock {
    | Some(toBlock) => Pervasives.min(toBlock, knownHeight)
    | None => knownHeight
    }

    let suggestedToBlock = Pervasives.min(fromBlock + suggestedBlockInterval - 1, toBlock)
    //Defensively ensure we never query a target block below fromBlock
    ->Pervasives.max(fromBlock)

    let firstBlockParentPromise =
      fromBlock > 0
        ? blockLoader.contents->LazyLoader.get(fromBlock - 1)->Promise.thenResolve(res => res->Some)
        : Promise.resolve(None)

    let {getLogSelectionOrThrow} = getSelectionConfig(selection)
    let {addresses, topicQuery} = getLogSelectionOrThrow(~addressesByContractName)

    let {logs, latestFetchedBlock} = await getNextPage(
      ~fromBlock,
      ~toBlock=suggestedToBlock,
      ~addresses,
      ~topicQuery,
      ~loadBlock=blockNumber => blockLoader.contents->LazyLoader.get(blockNumber),
      ~syncConfig,
      ~client,
      ~mutSuggestedBlockIntervals,
      ~partitionId,
      ~sourceName=name,
      ~chainId=chain->ChainMap.Chain.toChainId,
    )

    let executedBlockInterval = suggestedToBlock - fromBlock + 1

    // Increase the suggested block interval only when it was actually applied
    // and we didn't query to a hard toBlock
    // We also don't care about it when we have a hard max block interval
    if (
      executedBlockInterval >= suggestedBlockInterval &&
        !(mutSuggestedBlockIntervals->Utils.Dict.has(maxSuggestedBlockIntervalKey))
    ) {
      // Increase batch size going forward, but do not increase past a configured maximum
      // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
      mutSuggestedBlockIntervals->Js.Dict.set(
        partitionId,
        Pervasives.min(
          executedBlockInterval + syncConfig.accelerationAdditive,
          syncConfig.intervalCeiling,
        ),
      )
    }

    // Convert RPC logs to HyperSync events
    let hyperSyncEvents = logs->Belt.Array.map(convertLogToHyperSyncEvent)

    // Decode using HyperSyncClient decoder
    let parsedEvents = try await getHscDecoder().decodeEvents(hyperSyncEvents) catch {
    | exn =>
      raise(
        Source.GetItemsError(
          FailedGettingItems({
            exn,
            attemptedToBlock: toBlock,
            retry: ImpossibleForTheQuery({
              message: "Failed to parse events using hypersync client decoder. Please double-check your ABI.",
            }),
          }),
        ),
      )
    }

    let parsedQueueItems =
      await logs
      ->Array.zip(parsedEvents)
      ->Array.keepMap(((
        log: Rpc.GetLogs.log,
        maybeDecodedEvent: Js.Nullable.t<HyperSyncClient.Decoder.decodedEvent>,
      )) => {
        let topic0 = log.topics[0]->Option.getWithDefault("0x0")
        let routedAddress = if lowercaseAddresses {
          log.address->Address.Evm.fromAddressLowercaseOrThrow
        } else {
          log.address->Address.Evm.fromAddressOrThrow
        }

        switch eventRouter->EventRouter.get(
          ~tag=EventRouter.getEvmEventId(
            ~sighash=topic0,
            ~topicCount=log.topics->Array.length,
          ),
          ~indexingContracts,
          ~contractAddress=routedAddress,
          ~blockNumber=log.blockNumber,
        ) {
        | None => None
        | Some(eventConfig) =>
          switch maybeDecodedEvent {
          | Js.Nullable.Value(decoded) =>
            Some(
              (
                async () => {
                  let (block, transaction) = try await Promise.all2((
                    log->getEventBlockOrThrow,
                    log->getEventTransactionOrThrow(
                      ~transactionSchema=eventConfig.transactionSchema,
                    ),
                  )) catch {
                  | exn =>
                    raise(
                      Source.GetItemsError(
                        FailedGettingFieldSelection({
                          message: "Failed getting selected fields. Please double-check your RPC provider returns correct data.",
                          exn,
                          blockNumber: log.blockNumber,
                          logIndex: log.logIndex,
                        }),
                      ),
                    )
                  }

                  Internal.Event({
                    eventConfig: (eventConfig :> Internal.eventConfig),
                    timestamp: block.timestamp,
                    blockNumber: block.number,
                    chain,
                    logIndex: log.logIndex,
                    event: {
                      chainId: chain->ChainMap.Chain.toChainId,
                      params: decoded->eventConfig.convertHyperSyncEventArgs,
                      transaction,
                      block: block->(
                        Utils.magic: Rpc.GetBlockByNumber.block => Internal.eventBlock
                      ),
                      srcAddress: routedAddress,
                      logIndex: log.logIndex,
                    }->Internal.fromGenericEvent,
                  })
                }
              )(),
            )
          | Js.Nullable.Null
          | Js.Nullable.Undefined =>
            None
          }
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
      knownHeight,
      reorgGuard,
      fromBlockQueried: fromBlock,
    }
  }

  let getBlockHashes = (~blockNumbers, ~logger as _currentlyUnusedLogger) => {
    // Clear cache by creating a fresh LazyLoader
    // This is important, since we call this
    // function when a reorg is detected
    blockLoader := makeBlockLoader()
    transactionLoader := makeTransactionLoader()
    receiptLoader := makeReceiptLoader()

    blockNumbers
    ->Array.map(blockNum => blockLoader.contents->LazyLoader.get(blockNum))
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

  let createHeightSubscription = ws->Belt.Option.map(wsUrl =>
    (~onHeight) => RpcWebSocketHeightStream.subscribe(~wsUrl, ~chainId, ~onHeight)
  )

  {
    name,
    sourceFor,
    chain,
    poweredByHyperSync: false,
    pollingInterval: syncConfig.pollingInterval,
    getBlockHashes,
    getHeightOrThrow: () => {
      Prometheus.SourceRequestCount.increment(~sourceName=name, ~chainId=chain->ChainMap.Chain.toChainId)
      Rpc.GetBlockHeight.route->Rest.fetch((), ~client)
    },
    getItemsOrThrow,
    ?createHeightSubscription,
  }
}
