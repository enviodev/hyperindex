open Source

exception QueryTimout(string)

// eth_getTransactionByHash/eth_getTransactionReceipt returning null is usually
// transient: a load-balanced provider can route the lookup to a node that
// hasn't caught up with the one that served eth_getLogs. Must stay retryable,
// unlike other field-selection failures which disable the source.
exception TransactionDataNotFound({message: string})

// Minimal block data needed for infrastructure (reorg guard, timestamps, etc.)
type blockInfo = {
  number: int,
  timestamp: int,
  hash: string,
  parentHash: string,
}

let getKnownRawBlock = async (~client, ~blockNumber) =>
  switch await Rpc.getRawBlock(~client, ~blockNumber) {
  | Some(json) => json
  | None =>
    JsError.throwWithMessage(`RPC returned null for blockNumber ${blockNumber->Int.toString}`)
  }

// Extract infrastructure fields (number, timestamp, hash) from raw block JSON
let parseBlockInfo = (json: JSON.t): blockInfo => {
  let jsonDict = json->(Utils.magic: JSON.t => dict<JSON.t>)
  {
    number: jsonDict
    ->Dict.getUnsafe("number")
    ->S.parseOrThrow(Rpc.hexIntSchema),
    timestamp: jsonDict
    ->Dict.getUnsafe("timestamp")
    ->S.parseOrThrow(Rpc.hexIntSchema),
    hash: jsonDict
    ->Dict.getUnsafe("hash")
    ->S.parseOrThrow(S.string),
    parentHash: jsonDict
    ->Dict.getUnsafe("parentHash")
    ->S.parseOrThrow(S.string),
  }
}

let getKnownRawBlockWithBackoff = async (
  ~client,
  ~sourceName,
  ~chain,
  ~blockNumber,
  ~backoffMsOnFailure,
) => {
  let currentBackoff = ref(backoffMsOnFailure)
  let result = ref(None)

  while result.contents->Option.isNone {
    Prometheus.SourceRequestCount.increment(
      ~sourceName,
      ~chainId=chain->ChainMap.Chain.toChainId,
      ~method="eth_getBlockByNumber",
    )
    switch await getKnownRawBlock(~client, ~blockNumber) {
    | exception err =>
      Logging.warn({
        "err": err->Utils.prettifyExn,
        "msg": `Issue while running fetching batch of events from the RPC. Will wait ${currentBackoff.contents->Int.toString}ms and try again.`,
        "source": sourceName,
        "chainId": chain->ChainMap.Chain.toChainId,
        "type": "EXPONENTIAL_BACKOFF",
      })
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=currentBackoff.contents)
      currentBackoff := currentBackoff.contents * 2
    | json => result := Some(json)
    }
  }
  result.contents->Option.getOrThrow
}
// Pulls the provider error message out of either a parsed Rpc.JsonRpcError or
// the raw napi JsExn shape (`error.error.message`), so classifiers below don't
// each have to re-derive it.
let getErrorMessage = (exn: exn): option<string> =>
  switch exn {
  | Rpc.JsonRpcError({message}) => Some(message)
  | JsExn(error) =>
    try {
      let message: string = (error->Obj.magic)["error"]["message"]
      message->S.assertOrThrow(S.string)
      Some(message)
    } catch {
    | _ => None
    }
  | _ => None
  }

// Deterministic "the range returned too much data" errors that carry no numeric
// block-range suggestion (HyperRPC's 50k-log cap, response-size and result-count
// limits). They depend on log density, not on a fixed block window, so waiting
// never helps — the same range always re-trips the same cap. The reaction is to
// shrink the range and retry immediately, ratcheting the max range down.
let isResponseTooLargeError = {
  let patterns = [
    /more than \d+ logs/i, // HyperRPC: "More than 50000 logs returned"
    /\d+ logs returned/i,
    /too many logs/i,
    /query returned more than \d+ results/i, // ZkEVM
    /query exceeds max results/i, // LlamaRPC
    /response size should not/i, // 1RPC
    /(backend )?response too large/i, // Optimism
    /logs matched by query exceeds limit/i, // Arbitrum
    /block range is too wide/i, // Ankr
  ]
  (exn: exn) =>
    switch exn->getErrorMessage {
    | Some(message) => patterns->Array.some(re => re->RegExp.test(message))
    | None => false
    }
}

let getSuggestedBlockIntervalFromExn = {
  // Unknown provider: "retry with the range 123-456"
  let suggestedRangeRegExp = /retry with the range (\d+)-(\d+)/

  // QuickNode, 1RPC, Blast: "limited to a 1000 blocks range"
  let blockRangeLimitRegExp = /limited to a (\d+) blocks range/

  // Alchemy: "up to a 500 block range"
  let alchemyRangeRegExp = /up to a (\d+) block range/

  // Cloudflare: "Max range: 3500"
  let cloudflareRangeRegExp = /Max range: (\d+)/

  // Thirdweb: "Maximum allowed number of requested blocks is 3500"
  let thirdwebRangeRegExp = /Maximum allowed number of requested blocks is (\d+)/

  // BlockPI: "limited to 2000 block"
  let blockpiRangeRegExp = /limited to (\d+) block/

  // Base: "block range too large" - fixed 2000 block limit
  let baseRangeRegExp = /block range too large/

  // evm-rpc.sei-apis.com: "block range too large (2000), maximum allowed is 1000 blocks"
  let maxAllowedBlocksRegExp = /maximum allowed is (\d+) blocks/

  // Blast (paid): "exceeds the range allowed for your plan (5000 > 3000)"
  let blastPaidRegExp = /exceeds the range allowed for your plan \(\d+ > (\d+)\)/

  // Chainstack: "Block range limit exceeded" - 10000 block limit
  let chainstackRegExp = /Block range limit exceeded./

  // Coinbase: "please limit the query to at most 1000 blocks"
  let coinbaseRegExp = /please limit the query to at most (\d+) blocks/

  // PublicNode: "maximum block range: 2000"
  let publicNodeRegExp = /maximum block range: (\d+)/

  // Hyperliquid: "query exceeds max block range 1000"
  let hyperliquidRegExp = /query exceeds max block range (\d+)/

  // TODO: Reproduce how the error message looks like
  // when we send request with numeric block range instead of hex
  // Infura, ZkSync: "Try with this block range [0x123,0x456]"

  let parseMessageForBlockRange = (message: string) => {
    // Helper to extract block range from regex match
    let extractBlockRange = (execResult, ~isMaxRange) =>
      switch execResult->RegExp.Result.matches {
      | [Some(blockRangeLimit)] =>
        switch blockRangeLimit->Int.fromString {
        | Some(blockRangeLimit) if blockRangeLimit > 0 => Some(blockRangeLimit, isMaxRange)
        | _ => None
        }
      | _ => None
      }

    // Try each regex pattern in order
    switch suggestedRangeRegExp->RegExp.exec(message) {
    | Some(execResult) =>
      switch execResult->RegExp.Result.matches {
      | [Some(fromBlock), Some(toBlock)] =>
        switch (fromBlock->Int.fromString, toBlock->Int.fromString) {
        | (Some(fromBlock), Some(toBlock)) if toBlock >= fromBlock =>
          Some(toBlock - fromBlock + 1, false)
        | _ => None
        }
      | _ => None
      }
    | None =>
      // Try each provider's specific error pattern
      switch blockRangeLimitRegExp->RegExp.exec(message) {
      | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
      | None =>
        switch alchemyRangeRegExp->RegExp.exec(message) {
        | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
        | None =>
          switch cloudflareRangeRegExp->RegExp.exec(message) {
          | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
          | None =>
            switch thirdwebRangeRegExp->RegExp.exec(message) {
            | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
            | None =>
              switch blockpiRangeRegExp->RegExp.exec(message) {
              | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
              | None =>
                switch maxAllowedBlocksRegExp->RegExp.exec(message) {
                | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                | None =>
                  switch baseRangeRegExp->RegExp.exec(message) {
                  | Some(_) => Some(2000, true)
                  | None =>
                    switch blastPaidRegExp->RegExp.exec(message) {
                    | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                    | None =>
                      switch chainstackRegExp->RegExp.exec(message) {
                      | Some(_) => Some(10000, true)
                      | None =>
                        switch coinbaseRegExp->RegExp.exec(message) {
                        | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                        | None =>
                          switch publicNodeRegExp->RegExp.exec(message) {
                          | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
                          | None =>
                            switch hyperliquidRegExp->RegExp.exec(message) {
                            | Some(execResult) => extractBlockRange(execResult, ~isMaxRange=true)
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
    switch exn->getErrorMessage {
    | Some(message) => parseMessageForBlockRange(message)
    | None => None
    }
}

type eventBatchQuery = {
  items: array<EvmRpcClient.rpcEventItem>,
  latestFetchedBlockInfo: blockInfo,
}

let maxSuggestedBlockIntervalKey = "max"

let getSourceMaxBlockInterval = (mutSuggestedBlockIntervals, ~intervalCeiling) =>
  mutSuggestedBlockIntervals
  ->Utils.Dict.dangerouslyGetNonOption(maxSuggestedBlockIntervalKey)
  ->Option.getOr(intervalCeiling)

type logSelection = {
  addresses: option<array<Address.t>>,
  topicQuery: Rpc.GetLogs.topicQuery,
}

// A log can satisfy more than one selection when a single event's `where` is an
// OR of param groups, so dedup the fanned-out responses by (blockNumber,
// logIndex) — unique per chain — keeping the first occurrence.
let mergeAndDedupItems = (itemsPerSelection: array<array<EvmRpcClient.rpcEventItem>>) => {
  let seen = Utils.Set.make()
  let merged = []
  itemsPerSelection->Array.forEach(items =>
    items->Array.forEach((item: EvmRpcClient.rpcEventItem) => {
      let key = `${item.log.blockNumber->Int.toString}-${item.log.logIndex->Int.toString}`
      if seen->Utils.Set.has(key)->not {
        seen->Utils.Set.add(key)->ignore
        merged->Array.push(item)->ignore
      }
    })
  )
  merged
}

let getNextPage = (
  ~fromBlock,
  ~toBlock,
  ~logSelections: array<logSelection>,
  ~loadBlock,
  ~syncConfig as sc: Config.sourceSync,
  ~rpcClient: EvmRpcClient.t,
  ~mutSuggestedBlockIntervals,
  ~partitionId,
  ~sourceName,
  ~chainId,
): promise<eventBatchQuery> => {
  //If the query hangs for longer than this, reject this promise to reduce the block interval
  let queryTimoutPromise =
    Time.resolvePromiseAfterDelay(~delayMilliseconds=sc.queryTimeoutMillis)->Promise.then(() =>
      Promise.reject(
        QueryTimout(`Query took longer than ${Int.toString(sc.queryTimeoutMillis / 1000)} seconds`),
      )
    )

  let latestFetchedBlockPromise = loadBlock(toBlock)

  let queryLogs = ({addresses, topicQuery}: logSelection) => {
    Prometheus.SourceRequestCount.increment(~sourceName, ~chainId, ~method="eth_getLogs")
    rpcClient.getLogs({
      fromBlock,
      toBlock,
      ?addresses,
      topics: topicQuery->Array.map(filter =>
        switch filter {
        | Rpc.GetLogs.Null => Nullable.null
        | Single(topic) => Nullable.make([topic])
        | Multiple(topics) => Nullable.make(topics)
        }
      ),
    })
  }

  let logsPromise = switch logSelections {
  | [] =>
    latestFetchedBlockPromise->Promise.thenResolve((latestFetchedBlockInfo): eventBatchQuery => {
      items: [],
      latestFetchedBlockInfo,
    })
  // Fast path: a single selection needs no cross-request merge or dedup.
  | [logSelection] =>
    logSelection
    ->queryLogs
    ->Promise.then(async items => {
      {
        items,
        latestFetchedBlockInfo: await latestFetchedBlockPromise,
      }
    })
  | _ =>
    logSelections
    ->Array.map(queryLogs)
    ->Promise.all
    ->Promise.then(async itemsPerSelection => {
      {
        items: itemsPerSelection->mergeAndDedupItems,
        latestFetchedBlockInfo: await latestFetchedBlockPromise,
      }
    })
  }

  [queryTimoutPromise, logsPromise]
  ->Promise.race
  ->Promise.catch(err => {
    let executedBlockInterval = toBlock - fromBlock + 1
    let shrunkBlockInterval =
      Pervasives.max(1, (executedBlockInterval->Int.toFloat *. sc.backoffMultiplicative)->Float.toInt)

    let throwFailedGettingItems = retry =>
      throw(Source.GetItemsError(FailedGettingItems({exn: err, attemptedToBlock: toBlock, retry})))
    let throwResize = interval =>
      throwFailedGettingItems(WithSuggestedToBlock({toBlock: fromBlock + interval - 1}))

    switch getSuggestedBlockIntervalFromExn(err) {
    // "limited to N blocks" — a structural cap on the whole source; only tighten.
    | Some((interval, true)) =>
      let capped = Pervasives.min(
        mutSuggestedBlockIntervals->getSourceMaxBlockInterval(~intervalCeiling=sc.intervalCeiling),
        interval,
      )
      mutSuggestedBlockIntervals->Dict.set(maxSuggestedBlockIntervalKey, capped)
      throwResize(capped)
    // A one-off suggested range ("retry with range X-Y") — apply to this partition.
    | Some((interval, false)) =>
      mutSuggestedBlockIntervals->Dict.set(partitionId, interval)
      throwResize(interval)
    // Density cap with no suggested number (too many logs / response too large):
    // shrink THIS partition and retry immediately (no wait); acceleration
    // re-adapts on the next successful query. The interval>1 guard avoids a
    // no-progress tight loop on a single over-cap block.
    | None if executedBlockInterval > 1 && err->isResponseTooLargeError =>
      mutSuggestedBlockIntervals->Dict.set(partitionId, shrunkBlockInterval)
      throwResize(shrunkBlockInterval)
    // Transient/unknown — shrink this partition and back off.
    | None =>
      mutSuggestedBlockIntervals->Dict.set(partitionId, shrunkBlockInterval)
      throwFailedGettingItems(
        WithBackoff({
          message: `Failed getting data for the block range. Will try smaller block range for the next attempt.`,
          backoffMillis: sc.backoffMillis,
        }),
      )
    }
  })
}

type selectionConfig = {
  getLogSelectionsOrThrow: (
    ~addressesByContractName: dict<array<Address.t>>,
  ) => array<logSelection>,
}

let getSelectionConfig = (selection: FetchState.selection, ~chain) => {
  let evmEventConfigs =
    selection.eventConfigs->(
      Utils.magic: array<Internal.eventConfig> => array<Internal.evmEventConfig>
    )

  if evmEventConfigs->Utils.Array.isEmpty {
    throw(
      Source.GetItemsError(
        UnsupportedSelection({
          message: "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
        }),
      ),
    )
  }

  // eth_getLogs takes one address list and one topic selection per request, so
  // fan out to one request per selection. Each address-bound event is grouped by
  // its contract and later scoped to that contract's own addresses — pooling all
  // contracts' addresses would let one contract's query fetch a sibling's logs,
  // which route back by address and bypass the sibling's filter (routing never
  // re-applies it). Pure-wildcard events carry no address constraint, so they're
  // pooled and resolved once.
  let noAddressTopicSelections = []
  let staticByContract = Dict.make()
  let dynamicByContract = Dict.make()
  let dynamicWildcardByContract = Dict.make()
  let contractNames = Utils.Set.make()

  evmEventConfigs->Array.forEach(({
    contractName,
    isWildcard,
    dependsOnAddresses,
    getEventFiltersOrThrow,
  }) => {
    let eventFilters = getEventFiltersOrThrow(chain)
    if dependsOnAddresses {
      contractNames->Utils.Set.add(contractName)->ignore
      switch eventFilters {
      | Internal.Static(topicSelections) =>
        staticByContract->Utils.Dict.pushMany(contractName, topicSelections)
      | Dynamic(fn) =>
        (isWildcard ? dynamicWildcardByContract : dynamicByContract)->Utils.Dict.push(
          contractName,
          fn,
        )
      }
    } else {
      noAddressTopicSelections
      ->Array.pushMany(
        switch eventFilters {
        | Static(s) => s
        | Dynamic(fn) => fn([])
        },
      )
      ->ignore
    }
  })

  // `compressTopicSelections` folds the filter-less events into a single topic0
  // OR-set, keeping the common case at one request.
  let toLogSelections = (~addresses, topicSelections): array<logSelection> =>
    topicSelections
    ->LogSelection.compressTopicSelections
    ->Array.map(topicSelection => {
      addresses,
      topicQuery: topicSelection->Rpc.GetLogs.mapTopicQuery,
    })

  // Address-independent, so resolve once (the wildcard partition reuses this).
  let noAddressLogSelections = toLogSelections(~addresses=None, noAddressTopicSelections)

  let getLogSelectionsOrThrow = if contractNames->Utils.Set.size === 0 {
    (~addressesByContractName as _) => noAddressLogSelections
  } else {
    (~addressesByContractName): array<logSelection> => {
      let logSelections = noAddressLogSelections->Array.copy
      contractNames->Utils.Set.forEach(contractName => {
        switch addressesByContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
        | None
        | Some([]) => ()
        | Some(addresses) =>
          // Static + dynamic non-wildcard filters, scoped to this contract's addresses.
          let addressedTopicSelections = []
          switch staticByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
          | Some(s) => addressedTopicSelections->Array.pushMany(s)->ignore
          | None => ()
          }
          switch dynamicByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
          | Some(fns) =>
            fns->Array.forEach(fn =>
              addressedTopicSelections->Array.pushMany(fn(addresses))->ignore
            )
          | None => ()
          }
          logSelections
          ->Array.pushMany(toLogSelections(~addresses=Some(addresses), addressedTopicSelections))
          ->ignore

          // Dynamic wildcard-by-address filters fold the address into the topics,
          // so they still match any address.
          switch dynamicWildcardByContract->Utils.Dict.dangerouslyGetNonOption(contractName) {
          | Some(fns) =>
            logSelections
            ->Array.pushMany(
              toLogSelections(~addresses=None, fns->Array.flatMap(fn => fn(addresses))),
            )
            ->ignore
          | None => ()
          }
        }
      })
      logSelections
    }
  }

  {
    getLogSelectionsOrThrow: getLogSelectionsOrThrow,
  }
}

let memoGetSelectionConfig = (~chain) =>
  Utils.WeakMap.memoize(selection => selection->getSelectionConfig(~chain))

// Type-erase a schema for storage in the field registry
external toFieldSchema: S.t<'a> => S.t<JSON.t> = "%identity"

let lowercaseAddressSchema: S.t<JSON.t> =
  S.string
  ->S.transform(_ => {
    parser: str => str->String.toLowerCase->Address.unsafeFromString,
  })
  ->toFieldSchema

let checksumAddressSchema: S.t<JSON.t> =
  S.string
  ->S.transform(_ => {
    parser: str => str->Address.Evm.fromStringOrThrow,
  })
  ->toFieldSchema

// Block field definition for per-field parsing
type blockFieldDef = {
  location: Internal.evmBlockField,
  jsonKey: string,
  schema: S.t<JSON.t>, // Type-erased schema
}

// Block field registry: maps field location (= JS property name) to parsing info.
let makeBlockFieldRegistry = (addressSchema: S.t<JSON.t>): Utils.Record.t<
  Internal.evmBlockField,
  blockFieldDef,
> =>
  [
    {location: Number, jsonKey: "number", schema: Rpc.hexIntSchema->toFieldSchema},
    {location: Timestamp, jsonKey: "timestamp", schema: Rpc.hexIntSchema->toFieldSchema},
    {location: Hash, jsonKey: "hash", schema: S.string->toFieldSchema},
    {location: ParentHash, jsonKey: "parentHash", schema: S.string->toFieldSchema},
    {location: Nonce, jsonKey: "nonce", schema: Rpc.hexBigintSchema->toFieldSchema},
    {location: Sha3Uncles, jsonKey: "sha3Uncles", schema: S.string->toFieldSchema},
    {location: LogsBloom, jsonKey: "logsBloom", schema: S.string->toFieldSchema},
    {location: TransactionsRoot, jsonKey: "transactionsRoot", schema: S.string->toFieldSchema},
    {location: StateRoot, jsonKey: "stateRoot", schema: S.string->toFieldSchema},
    {location: ReceiptsRoot, jsonKey: "receiptsRoot", schema: S.string->toFieldSchema},
    {location: Miner, jsonKey: "miner", schema: addressSchema},
    {location: Difficulty, jsonKey: "difficulty", schema: Rpc.hexBigintSchema->toFieldSchema},
    {
      location: TotalDifficulty,
      jsonKey: "totalDifficulty",
      schema: Rpc.hexBigintSchema->toFieldSchema,
    },
    {location: ExtraData, jsonKey: "extraData", schema: S.string->toFieldSchema},
    {location: Size, jsonKey: "size", schema: Rpc.hexBigintSchema->toFieldSchema},
    {location: GasLimit, jsonKey: "gasLimit", schema: Rpc.hexBigintSchema->toFieldSchema},
    {location: GasUsed, jsonKey: "gasUsed", schema: Rpc.hexBigintSchema->toFieldSchema},
    {location: Uncles, jsonKey: "uncles", schema: S.array(S.string)->toFieldSchema},
    {location: BaseFeePerGas, jsonKey: "baseFeePerGas", schema: Rpc.hexBigintSchema->toFieldSchema},
    {location: BlobGasUsed, jsonKey: "blobGasUsed", schema: Rpc.hexBigintSchema->toFieldSchema},
    {location: ExcessBlobGas, jsonKey: "excessBlobGas", schema: Rpc.hexBigintSchema->toFieldSchema},
    {
      location: ParentBeaconBlockRoot,
      jsonKey: "parentBeaconBlockRoot",
      schema: S.string->toFieldSchema,
    },
    {location: WithdrawalsRoot, jsonKey: "withdrawalsRoot", schema: S.string->toFieldSchema},
    {location: L1BlockNumber, jsonKey: "l1BlockNumber", schema: Rpc.hexIntSchema->toFieldSchema},
    {location: SendCount, jsonKey: "sendCount", schema: S.string->toFieldSchema},
    {location: SendRoot, jsonKey: "sendRoot", schema: S.string->toFieldSchema},
    {location: MixHash, jsonKey: "mixHash", schema: S.string->toFieldSchema},
  ]
  ->Array.map(def => (
    def.location,
    if Internal.evmNullableBlockFields->Utils.Set.has(def.location) {
      {...def, schema: S.nullable(def.schema)->toFieldSchema}
    } else {
      def
    },
  ))
  ->Utils.Record.fromArray

let blockFieldRegistryLowercase = makeBlockFieldRegistry(lowercaseAddressSchema)
let blockFieldRegistryChecksum = makeBlockFieldRegistry(checksumAddressSchema)

// Parse block fields from raw JSON, similar to parseFieldsFromJson for transactions
let parseBlockFieldsFromJson = (
  mutBlockAcc: dict<JSON.t>,
  fields: array<blockFieldDef>,
  json: JSON.t,
) => {
  let jsonDict = json->(Utils.magic: JSON.t => dict<JSON.t>)
  fields->Array.forEach(def => {
    let raw = jsonDict->Dict.getUnsafe(def.jsonKey)
    try {
      let parsed = raw->S.parseOrThrow(def.schema)
      mutBlockAcc->Dict.set((def.location :> string), parsed)
    } catch {
    | S.Raised(error) =>
      JsError.throwWithMessage(
        `Invalid block field "${(def.location :> string)}" found in the RPC response. Error: ${error->S.Error.reason}`,
      )
    }
  })
}

let makeThrowingGetEventBlock = (
  ~getBlockJson: int => promise<JSON.t>,
  ~lowercaseAddresses: bool,
) => {
  let blockFieldRegistry = if lowercaseAddresses {
    blockFieldRegistryLowercase
  } else {
    blockFieldRegistryChecksum
  }
  let fnsCache = Utils.WeakMap.make()
  (log: Rpc.GetLogs.log, ~selectedBlockFields: Utils.Set.t<Internal.evmBlockField>) => {
    (
      switch fnsCache->Utils.WeakMap.get(selectedBlockFields) {
      | Some(fn) => fn
      // Build per-field parser on first call, then cache in WeakMap
      | None => {
          let fields: array<blockFieldDef> = []
          selectedBlockFields->Utils.Set.forEach(fieldName => {
            fields->Array.push(blockFieldRegistry->Utils.Record.getUnsafe(fieldName))->ignore
          })

          let fn = if selectedBlockFields->Utils.Set.size == 0 {
            _ => %raw(`{}`)->(Utils.magic: 'a => Internal.eventBlock)->Promise.resolve
          } else {
            (log: Rpc.GetLogs.log) => {
              getBlockJson(log.blockNumber)->Promise.thenResolve(json => {
                let mutBlockAcc = Dict.make()
                parseBlockFieldsFromJson(mutBlockAcc, fields, json)
                mutBlockAcc->(Utils.magic: dict<JSON.t> => Internal.eventBlock)
              })
            }
          }
          let _ = fnsCache->Utils.WeakMap.set(selectedBlockFields, fn)
          fn
        }
      }
    )(log)
  }
}

// `number`, `timestamp` and `hash` are always part of the selected block
// fields, so they can be read from the assembled block at item construction.
@get external getBlockNumber: Internal.eventBlock => int = "number"
@get external getBlockTimestamp: Internal.eventBlock => int = "timestamp"
@get external getBlockHash: Internal.eventBlock => string = "hash"

// Field source classification for RPC calls
type fieldSource = TransactionOnly | ReceiptOnly | Both

type fieldDef = {
  location: Internal.evmTransactionField,
  jsonKey: string,
  schema: S.t<JSON.t>, // Type-erased schema (S.nullable for optional fields)
  source: fieldSource,
}

// Field registry: maps field location (= JS property name) to parsing info.
// Only includes fields that require an RPC call. Log-derived fields (hash, transactionIndex) are special-cased.
// Nullable fields are wrapped with S.nullable during registry construction based on Internal.evmNullableTransactionFields
let makeFieldRegistry = (addressSchema: S.t<JSON.t>): Utils.Record.t<
  Internal.evmTransactionField,
  fieldDef,
> =>
  [
    // TransactionOnly fields (only in eth_getTransactionByHash)
    {
      location: Gas,
      jsonKey: "gas",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: TransactionOnly,
    },
    {
      location: GasPrice,
      jsonKey: "gasPrice",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: TransactionOnly,
    },
    {location: Input, jsonKey: "input", schema: S.string->toFieldSchema, source: TransactionOnly},
    {
      location: Nonce,
      jsonKey: "nonce",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: TransactionOnly,
    },
    {
      location: Value,
      jsonKey: "value",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: TransactionOnly,
    },
    {location: V, jsonKey: "v", schema: S.string->toFieldSchema, source: TransactionOnly},
    {location: R, jsonKey: "r", schema: S.string->toFieldSchema, source: TransactionOnly},
    {location: S, jsonKey: "s", schema: S.string->toFieldSchema, source: TransactionOnly},
    {
      location: YParity,
      jsonKey: "yParity",
      schema: S.string->toFieldSchema,
      source: TransactionOnly,
    },
    {
      location: MaxPriorityFeePerGas,
      jsonKey: "maxPriorityFeePerGas",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: TransactionOnly,
    },
    {
      location: MaxFeePerGas,
      jsonKey: "maxFeePerGas",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: TransactionOnly,
    },
    {
      location: MaxFeePerBlobGas,
      jsonKey: "maxFeePerBlobGas",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: TransactionOnly,
    },
    {
      location: BlobVersionedHashes,
      jsonKey: "blobVersionedHashes",
      schema: S.array(S.string)->toFieldSchema,
      source: TransactionOnly,
    },
    // ReceiptOnly fields (only in eth_getTransactionReceipt)
    {
      location: GasUsed,
      jsonKey: "gasUsed",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: CumulativeGasUsed,
      jsonKey: "cumulativeGasUsed",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: EffectiveGasPrice,
      jsonKey: "effectiveGasPrice",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: ContractAddress,
      jsonKey: "contractAddress",
      schema: addressSchema,
      source: ReceiptOnly,
    },
    {
      location: LogsBloom,
      jsonKey: "logsBloom",
      schema: S.string->toFieldSchema,
      source: ReceiptOnly,
    },
    {location: Root, jsonKey: "root", schema: S.string->toFieldSchema, source: ReceiptOnly},
    {
      location: Status,
      jsonKey: "status",
      schema: Rpc.hexIntSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: L1Fee,
      jsonKey: "l1Fee",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: L1GasPrice,
      jsonKey: "l1GasPrice",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: L1GasUsed,
      jsonKey: "l1GasUsed",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: L1FeeScalar,
      jsonKey: "l1FeeScalar",
      schema: Rpc.decimalFloatSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    {
      location: GasUsedForL1,
      jsonKey: "gasUsedForL1",
      schema: Rpc.hexBigintSchema->toFieldSchema,
      source: ReceiptOnly,
    },
    // Both fields (available in both eth_getTransactionByHash and eth_getTransactionReceipt)
    {location: From, jsonKey: "from", schema: addressSchema, source: Both},
    {location: To, jsonKey: "to", schema: addressSchema, source: Both},
    {location: Type, jsonKey: "type", schema: Rpc.hexIntSchema->toFieldSchema, source: Both},
  ]
  ->Array.map(def => (
    def.location,
    if Internal.evmNullableTransactionFields->Utils.Set.has(def.location) {
      {...def, schema: S.nullable(def.schema)->toFieldSchema}
    } else {
      def
    },
  ))
  ->Utils.Record.fromArray

let fieldRegistryLowercase = makeFieldRegistry(lowercaseAddressSchema)
let fieldRegistryChecksum = makeFieldRegistry(checksumAddressSchema)

type fetchStrategy = NoRpc | TransactionOnly | ReceiptOnly | TransactionAndReceipt

// Parse fields from a raw JSON object into a result dict.
// Uses unsafeGet so nullable schemas (S.nullable) handle both null and undefined.
let parseFieldsFromJson = (
  mutTransactionAcc: dict<JSON.t>,
  fields: array<fieldDef>,
  json: JSON.t,
) => {
  let jsonDict = json->(Utils.magic: JSON.t => dict<JSON.t>)
  fields->Array.forEach(def => {
    let raw = jsonDict->Dict.getUnsafe(def.jsonKey)
    try {
      let parsed = raw->S.parseOrThrow(def.schema)
      mutTransactionAcc->Dict.set((def.location :> string), parsed)
    } catch {
    | S.Raised(error) =>
      JsError.throwWithMessage(
        `Invalid transaction field "${(def.location :> string)}" found in the RPC response. Error: ${error->S.Error.reason}`,
      )
    }
  })
}

let makeThrowingGetEventTransaction = (
  ~getTransactionJson: string => promise<JSON.t>,
  ~getReceiptJson: string => promise<JSON.t>,
  ~lowercaseAddresses: bool,
) => {
  let fieldRegistry = if lowercaseAddresses {
    fieldRegistryLowercase
  } else {
    fieldRegistryChecksum
  }
  let fnsCache = Utils.WeakMap.make()
  (log, ~selectedTransactionFields: Utils.Set.t<Internal.evmTransactionField>) => {
    (
      switch fnsCache->Utils.WeakMap.get(selectedTransactionFields) {
      | Some(fn) => fn
      // Build per-field parser on first call, then cache in WeakMap
      | None => {
          // Classify fields: log-derived vs RPC fields
          let hasTransactionIndex = ref(false)
          let hasHash = ref(false)
          let txFields: array<fieldDef> = []
          let receiptFields: array<fieldDef> = []
          let bothFields: array<fieldDef> = []

          selectedTransactionFields->Utils.Set.forEach(fieldName => {
            switch fieldName {
            | TransactionIndex => hasTransactionIndex := true
            | Hash => hasHash := true
            | _ =>
              switch fieldRegistry->Utils.Record.get(fieldName) {
              | Some(def) =>
                switch def.source {
                | TransactionOnly => txFields->Array.push(def)->ignore
                | ReceiptOnly => receiptFields->Array.push(def)->ignore
                | Both => bothFields->Array.push(def)->ignore
                }
              | None => () // Unknown field — skip silently
              }
            }
          })

          // Determine fetch strategy
          let strategy = switch (txFields->Array.length > 0, receiptFields->Array.length > 0) {
          | (true, true) => TransactionAndReceipt
          | (true, false) => TransactionOnly
          | (false, true) => ReceiptOnly
          | (false, false) if bothFields->Array.length > 0 => TransactionOnly
          | (false, false) => NoRpc
          }

          // Assign Both fields to whichever source is already being fetched; default to transaction
          let targetForBoth = strategy == ReceiptOnly ? receiptFields : txFields
          bothFields->Array.forEach(f => targetForBoth->Array.push(f)->ignore)

          // Set log-derived fields on the mutable accumulator
          let setLogFields = (mutTransactionAcc: dict<JSON.t>, log: Rpc.GetLogs.log) => {
            if hasTransactionIndex.contents {
              mutTransactionAcc->Dict.set(
                "transactionIndex",
                log.transactionIndex->(Utils.magic: int => JSON.t),
              )
            }
            if hasHash.contents {
              mutTransactionAcc->Dict.set(
                "hash",
                log.transactionHash->(Utils.magic: string => JSON.t),
              )
            }
          }

          let fn = if selectedTransactionFields->Utils.Set.size == 0 {
            _ => %raw(`{}`)->Promise.resolve
          } else {
            switch strategy {
            | NoRpc =>
              (log: Rpc.GetLogs.log) => {
                let mutTransactionAcc = Dict.make()
                setLogFields(mutTransactionAcc, log)
                mutTransactionAcc->(Utils.magic: dict<JSON.t> => 'a)->Promise.resolve
              }
            | _ =>
              (log: Rpc.GetLogs.log) => {
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
                  let mutTransactionAcc = Dict.make()
                  setLogFields(mutTransactionAcc, log)

                  switch txJson {
                  | Some(json) => parseFieldsFromJson(mutTransactionAcc, txFields, json)
                  | None => ()
                  }
                  switch receiptJson {
                  | Some(json) => parseFieldsFromJson(mutTransactionAcc, receiptFields, json)
                  | None => ()
                  }

                  mutTransactionAcc->(Utils.magic: dict<JSON.t> => 'a)
                })
              }
            }
          }
          let _ = fnsCache->Utils.WeakMap.set(selectedTransactionFields, fn)
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
  allEventParams: array<HyperSyncClient.Decoder.eventParamsInput>,
  lowercaseAddresses: bool,
  ws?: string,
  headers?: dict<string>,
}

let make = (
  {
    sourceFor,
    syncConfig,
    url,
    chain,
    eventRouter,
    allEventParams,
    lowercaseAddresses,
    ?ws,
    ?headers,
  }: options,
): t => {
  let chainId = chain->ChainMap.Chain.toChainId
  let urlHost = switch Utils.Url.getHostFromUrl(url) {
  | None =>
    JsError.throwWithMessage(
      `The RPC url for chain ${chainId->Int.toString} is in incorrect format. The RPC url needs to start with either http:// or https://`,
    )
  | Some(host) => host
  }
  let name = `RPC (${urlHost})`

  let getSelectionConfig = memoGetSelectionConfig(~chain)

  // Per-partition adaptive block interval (AIMD), keyed by partitionId. The
  // `max` key holds a source-wide ceiling that only ever tightens, set by
  // structural provider limits ("limited to N blocks"). A partition's own entry
  // can go stale when partitions merge/split — acceptable, it re-adapts.
  let mutSuggestedBlockIntervals = Dict.make()

  let client = Rpc.makeClient(url, ~headers?)
  let rpcClient = EvmRpcClient.make(
    ~url,
    ~allEventParams,
    ~checksumAddresses=!lowercaseAddresses,
    ~headers?,
  )

  let makeTransactionLoader = () =>
    LazyLoader.make(
      ~loaderFn=transactionHash => {
        Prometheus.SourceRequestCount.increment(
          ~sourceName=name,
          ~chainId=chain->ChainMap.Chain.toChainId,
          ~method="eth_getTransactionByHash",
        )
        Rpc.GetTransactionByHash.rawRoute->Rest.fetch(transactionHash, ~client)
      },
      ~onError=(am, ~exn) => {
        Logging.error({
          "err": exn->Utils.prettifyExn,
          "msg": `Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
              ->Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
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
      ~loaderFn=blockNumber => {
        getKnownRawBlockWithBackoff(
          ~client,
          ~sourceName=name,
          ~chain,
          ~backoffMsOnFailure=1000,
          ~blockNumber,
        )
      },
      ~onError=(am, ~exn) => {
        Logging.error({
          "err": exn->Utils.prettifyExn,
          "msg": `Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
              ->Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
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
        Prometheus.SourceRequestCount.increment(
          ~sourceName=name,
          ~chainId=chain->ChainMap.Chain.toChainId,
          ~method="eth_getTransactionReceipt",
        )
        Rpc.GetTransactionReceipt.rawRoute->Rest.fetch(transactionHash, ~client)
      },
      ~onError=(am, ~exn) => {
        Logging.error({
          "err": exn->Utils.prettifyExn,
          "msg": `Top level promise timeout reached. Please review other errors or warnings in the code. This function will retry in ${(am._retryDelayMillis / 1000)
              ->Int.toString} seconds. It is highly likely that your indexer isn't syncing on one or more chains currently. Also take a look at the "suggestedFix" in the metadata of this command`,
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

  let getEventBlockOrThrow = makeThrowingGetEventBlock(
    ~getBlockJson=blockNumber => blockLoader.contents->LazyLoader.get(blockNumber),
    ~lowercaseAddresses,
  )
  let getEventTransactionOrThrow = makeThrowingGetEventTransaction(
    ~getTransactionJson=async transactionHash => {
      switch await transactionLoader.contents->LazyLoader.get(transactionHash) {
      | Some(json) => json
      | None =>
        throw(
          TransactionDataNotFound({message: `Transaction not found for hash: ${transactionHash}`}),
        )
      }
    },
    ~getReceiptJson=async transactionHash => {
      switch await receiptLoader.contents->LazyLoader.get(transactionHash) {
      | Some(json) => json
      | None =>
        throw(
          TransactionDataNotFound({
            message: `Transaction receipt not found for hash: ${transactionHash}`,
          }),
        )
      }
    },
    ~lowercaseAddresses,
  )

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~contractNameByAddress,
    ~knownHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~retry,
    ~logger as _,
  ) => {
    let startFetchingBatchTimeRef = Performance.now()

    let sourceMaxBlockInterval =
      mutSuggestedBlockIntervals->getSourceMaxBlockInterval(~intervalCeiling=syncConfig.intervalCeiling)
    let suggestedBlockInterval = Pervasives.min(
      mutSuggestedBlockIntervals
      ->Utils.Dict.dangerouslyGetNonOption(partitionId)
      ->Option.getOr(syncConfig.initialBlockInterval),
      sourceMaxBlockInterval,
    )

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
        ? blockLoader.contents
          ->LazyLoader.get(fromBlock - 1)
          ->Promise.thenResolve(json => Some(parseBlockInfo(json)))
        : Promise.resolve(None)

    let {getLogSelectionsOrThrow} = getSelectionConfig(selection)
    let logSelections = getLogSelectionsOrThrow(~addressesByContractName)

    let {items, latestFetchedBlockInfo} = await getNextPage(
      ~fromBlock,
      ~toBlock=suggestedToBlock,
      ~logSelections,
      ~loadBlock=blockNumber =>
        blockLoader.contents
        ->LazyLoader.get(blockNumber)
        ->Promise.thenResolve(parseBlockInfo),
      ~syncConfig,
      ~rpcClient,
      ~mutSuggestedBlockIntervals,
      ~partitionId,
      ~sourceName=name,
      ~chainId=chain->ChainMap.Chain.toChainId,
    )

    let executedBlockInterval = suggestedToBlock - fromBlock + 1

    // Grow this partition's interval only when the full suggested range was
    // actually applied (not clamped by a hard toBlock). The min clamps to the
    // source-wide ceiling, which also stops growth once a structural cap tightened it.
    // See: https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease
    if executedBlockInterval >= suggestedBlockInterval {
      mutSuggestedBlockIntervals->Dict.set(
        partitionId,
        Pervasives.min(
          executedBlockInterval + syncConfig.accelerationAdditive,
          sourceMaxBlockInterval,
        ),
      )
    }

    let parsedQueueItems = await items
    ->Array.filterMap(({log, params: maybeDecodedEvent}: EvmRpcClient.rpcEventItem) => {
      let topic0 = log.topics[0]->Option.getOr("0x0")
      let routedAddress = if lowercaseAddresses {
        log.address->Address.Evm.fromAddressLowercaseOrThrow
      } else {
        log.address->Address.Evm.fromAddressOrThrow
      }

      switch eventRouter->EventRouter.get(
        ~tag=EventRouter.getEvmEventId(~sighash=topic0, ~topicCount=log.topics->Array.length),
        ~contractNameByAddress,
        ~contractAddress=routedAddress,
      ) {
      | None => None
      | Some(eventConfig) =>
        switch maybeDecodedEvent
        ->Nullable.toOption
        ->Option.flatMap(Dict.get(_, eventConfig.contractName)) {
        | Some(decoded) =>
          Some(
            (
              async () => {
                let (block, transaction) = try await Promise.all2((
                  log->getEventBlockOrThrow(~selectedBlockFields=eventConfig.selectedBlockFields),
                  log->getEventTransactionOrThrow(
                    ~selectedTransactionFields=eventConfig.selectedTransactionFields->(
                      Utils.magic: Utils.Set.t<string> => Utils.Set.t<Internal.evmTransactionField>
                    ),
                  ),
                )) catch {
                | TransactionDataNotFound({message}) =>
                  let backoffMillis = switch retry {
                  | 0 => 100
                  | _ => 500 * retry
                  }
                  throw(
                    Source.GetItemsError(
                      FailedGettingItems({
                        exn: %raw(`null`),
                        attemptedToBlock: toBlock,
                        retry: WithBackoff({
                          message: `${message}. The RPC provider might be load-balanced between nodes that drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${backoffMillis->Int.toString}ms.`,
                          backoffMillis,
                        }),
                      }),
                    ),
                  )
                | exn =>
                  throw(
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
                  timestamp: block->getBlockTimestamp,
                  blockNumber: block->getBlockNumber,
                  blockHash: block->getBlockHash,
                  chain,
                  logIndex: log.logIndex,
                  transactionIndex: log.transactionIndex,
                  payload: {
                    contractName: eventConfig.contractName,
                    eventName: eventConfig.name,
                    chainId: chain->ChainMap.Chain.toChainId,
                    params: decoded,
                    block,
                    transaction,
                    srcAddress: routedAddress,
                    logIndex: log.logIndex,
                  }->Evm.fromPayload,
                })
              }
            )(),
          )
        | None => None
        }
      }
    })
    ->Promise.all

    let optFirstBlockParent = await firstBlockParentPromise

    let totalTimeElapsed = startFetchingBatchTimeRef->Performance.secondsSince

    // Every fetched block carries `hash` and `parentHash`, so each one yields
    // two confirmed (number, hash) pairs for reorg detection at no extra cost.
    let blockHashes = []
    let pushBlockInfo = (b: blockInfo) => {
      blockHashes->Array.push({ReorgDetection.blockNumber: b.number, blockHash: b.hash})->ignore
      if b.number > 0 {
        blockHashes
        ->Array.push({ReorgDetection.blockNumber: b.number - 1, blockHash: b.parentHash})
        ->ignore
      }
    }
    pushBlockInfo(latestFetchedBlockInfo)
    switch optFirstBlockParent {
    | Some(b) => pushBlockInfo(b)
    | None => ()
    }
    items->Array.forEach(({log}) =>
      blockHashes
      ->Array.push({ReorgDetection.blockNumber: log.blockNumber, blockHash: log.blockHash})
      ->ignore
    )

    {
      latestFetchedBlockTimestamp: latestFetchedBlockInfo.timestamp,
      latestFetchedBlockNumber: latestFetchedBlockInfo.number,
      parsedQueueItems,
      // RPC keeps the transaction and block inline on the payload; no store pages.
      transactionStore: None,
      blockStore: None,
      stats: {
        totalTimeElapsed: totalTimeElapsed,
      },
      knownHeight,
      blockHashes,
      fromBlockQueried: fromBlock,
    }
  }

  let onReorg = (~rollbackTargetBlock as _) => {
    // Drop cached block/transaction/receipt data — after a reorg the cached
    // entries may refer to orphaned-chain values.
    blockLoader := makeBlockLoader()
    transactionLoader := makeTransactionLoader()
    receiptLoader := makeReceiptLoader()
  }

  let getBlockHashes = (~blockNumbers, ~logger as _currentlyUnusedLogger) => {
    blockNumbers
    ->Array.map(blockNum => blockLoader.contents->LazyLoader.get(blockNum))
    ->Promise.all
    ->Promise.thenResolve(rawBlocks => {
      rawBlocks
      ->Array.map(json => {
        let b = parseBlockInfo(json)

        (
          {
            blockNumber: b.number,
            blockHash: b.hash,
            blockTimestamp: b.timestamp,
          }: ReorgDetection.blockDataWithTimestamp
        )
      })
      ->Ok
    })
    ->Promise.catch(exn => exn->Error->Promise.resolve)
  }

  let createHeightSubscription =
    ws->Option.map(wsUrl =>
      (~onHeight) => RpcWebSocketHeightStream.subscribe(~wsUrl, ~chainId, ~onHeight)
    )

  {
    name,
    sourceFor,
    chain,
    poweredByHyperSync: false,
    pollingInterval: syncConfig.pollingInterval,
    getBlockHashes,
    onReorg,
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = try {
        await rpcClient.getHeight()
      } catch {
      | exn =>
        let seconds = timerRef->Performance.secondsSince
        Prometheus.SourceRequestCount.increment(
          ~sourceName=name,
          ~chainId=chain->ChainMap.Chain.toChainId,
          ~method="eth_blockNumber",
        )
        Prometheus.SourceRequestCount.addSeconds(
          ~sourceName=name,
          ~chainId=chain->ChainMap.Chain.toChainId,
          ~method="eth_blockNumber",
          ~seconds,
        )
        exn->throw
      }
      let seconds = timerRef->Performance.secondsSince
      Prometheus.SourceRequestCount.increment(
        ~sourceName=name,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~method="eth_blockNumber",
      )
      Prometheus.SourceRequestCount.addSeconds(
        ~sourceName=name,
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~method="eth_blockNumber",
        ~seconds,
      )
      height
    },
    getItemsOrThrow,
    ?createHeightSubscription,
  }
}
