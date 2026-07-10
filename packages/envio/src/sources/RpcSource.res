open Source

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
  ~recordRequest: (~method: string, ~seconds: float) => unit,
) => {
  let currentBackoff = ref(backoffMsOnFailure)
  let result = ref(None)

  while result.contents->Option.isNone {
    let timerRef = Performance.now()
    switch await getKnownRawBlock(~client, ~blockNumber) {
    | exception err =>
      recordRequest(~method="eth_getBlockByNumber", ~seconds=timerRef->Performance.secondsSince)
      Logging.warn({
        "err": err->Utils.prettifyExn,
        "msg": `Issue while running fetching batch of events from the RPC. Will wait ${currentBackoff.contents->Int.toString}ms and try again.`,
        "source": sourceName,
        "chainId": chain->ChainMap.Chain.toChainId,
        "type": "EXPONENTIAL_BACKOFF",
      })
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=currentBackoff.contents)
      currentBackoff := currentBackoff.contents * 2
    | json =>
      recordRequest(~method="eth_getBlockByNumber", ~seconds=timerRef->Performance.secondsSince)
      result := Some(json)
    }
  }
  result.contents->Option.getOrThrow
}
// Pulls the underlying provider error message back out of a caught exn, for
// logging/debugging. Provider JSON-RPC errors surface as `Rpc.JsonRpcError`;
// the paging retry decision (see `parseGetNextPageRetryError` below) surfaces
// as a napi `JsExn` whose message is the JSON payload `EvmRpcClient.getNextPage`
// throws, carrying the classified message (if any) under `errorMessage`.
let getErrorMessage = (exn: exn): option<string> =>
  switch exn {
  | Rpc.JsonRpcError({message}) => Some(message)
  | JsExn(e) =>
    switch e->JsExn.message {
    | Some(msg) =>
      switch msg->JSON.parseOrThrow->JSON.Decode.object {
      | exception _ => None
      | None => None
      | Some(obj) =>
        switch obj->Dict.get("errorMessage") {
        | Some(String(message)) => Some(message)
        | _ => None
        }
      }
    | None => None
    }
  | _ => None
  }


// `EvmRpcClient.getNextPage` throws a napi error whose message is a JSON
// payload describing the retry decision:
// `{"kind":"Retry","attemptedToBlock":int,"errorMessage":string|null,
// "requestStats":[{"method":string,"seconds":float}],"retry":
// {"tag":"WithSuggestedToBlock","toBlock":int} |
// {"tag":"WithBackoff","message":string,"backoffMillis":int}}`.
let parseGetNextPageRetryError = (exn: exn): option<(
  int,
  Source.getItemsRetry,
  array<Source.requestStat>,
)> =>
  switch exn {
  | JsExn(e) =>
    switch e->JsExn.message {
    | Some(msg) =>
      switch msg->JSON.parseOrThrow->JSON.Decode.object {
      | exception _ => None
      | None => None
      | Some(obj) =>
        switch (obj->Dict.get("kind"), obj->Dict.get("attemptedToBlock"), obj->Dict.get("retry")) {
        | (Some(String("Retry")), Some(Number(attemptedToBlock)), Some(Object(retryObj))) =>
          let requestStats = switch obj->Dict.get("requestStats") {
          | Some(Array(stats)) =>
            stats->Array.filterMap(s =>
              switch s->JSON.Decode.object {
              | Some(o) =>
                switch (o->Dict.get("method"), o->Dict.get("seconds")) {
                | (Some(String(method)), Some(Number(seconds))) => Some({Source.method, seconds})
                | _ => None
                }
              | None => None
              }
            )
          | _ => []
          }
          let retry = switch retryObj->Dict.get("tag") {
          | Some(String("WithSuggestedToBlock")) =>
            switch retryObj->Dict.get("toBlock") {
            | Some(Number(toBlock)) =>
              Some(Source.WithSuggestedToBlock({toBlock: toBlock->Float.toInt}))
            | _ => None
            }
          | Some(String("WithBackoff")) =>
            switch (retryObj->Dict.get("message"), retryObj->Dict.get("backoffMillis")) {
            | (Some(String(message)), Some(Number(backoffMillis))) =>
              Some(Source.WithBackoff({message, backoffMillis: backoffMillis->Float.toInt}))
            | _ => None
            }
          | _ => None
          }
          retry->Option.map(retry => (attemptedToBlock->Float.toInt, retry, requestStats))
        | _ => None
        }
      }
    | None => None
    }
  | _ => None
  }

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

// `number` is always part of the selected block fields, so it can be read
// from the assembled block for the item's own `blockNumber`.
@get external getBlockNumber: Internal.eventBlock => int = "number"

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
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.evmOnEventRegistration>,
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
    onEventRegistrations,
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

  let client = Rpc.makeClient(url, ~headers?)
  let rpcClient = EvmRpcClient.make(
    ~url,
    ~eventRegistrations=HyperSyncClient.Registration.fromOnEventRegistrations(
      onEventRegistrations,
    ),
    ~checksumAddresses=!lowercaseAddresses,
    ~syncConfig,
    ~headers?,
  )

  // Requests are made from shared, memoized loaders, so they can't be
  // attributed to a single getItemsOrThrow/getHeightOrThrow/getBlockHashes
  // call at its call site. Every actual request (cache/dedup hits never reach
  // recordRequest) pushes here; each method drains whatever is pending when it
  // returns. Since a push always lands in exactly one drain, per-source totals
  // stay exact even with concurrent in-flight calls — which call happens to
  // drain a given entry doesn't matter, since SourceManager aggregates by
  // (source, method) regardless of which call returned it.
  let pendingRequestStats: array<Source.requestStat> = []
  let recordRequest = (~method, ~seconds) => {
    pendingRequestStats->Array.push({Source.method, seconds})->ignore
  }
  let drainRequestStats = () => {
    let stats = pendingRequestStats->Utils.Array.copy
    pendingRequestStats->Utils.Array.clearInPlace
    stats
  }

  let makeTransactionLoader = () =>
    LazyLoader.make(
      ~loaderFn=transactionHash => {
        let timerRef = Performance.now()
        Rpc.GetTransactionByHash.rawRoute
        ->Rest.fetch(transactionHash, ~client)
        ->Promise.thenResolve(res => {
          recordRequest(
            ~method="eth_getTransactionByHash",
            ~seconds=timerRef->Performance.secondsSince,
          )
          res
        })
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
          ~recordRequest,
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
        let timerRef = Performance.now()
        Rpc.GetTransactionReceipt.rawRoute
        ->Rest.fetch(transactionHash, ~client)
        ->Promise.thenResolve(res => {
          recordRequest(
            ~method="eth_getTransactionReceipt",
            ~seconds=timerRef->Performance.secondsSince,
          )
          res
        })
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
    ~contractNameByAddress as _,
    ~knownHeight,
    ~partitionId,
    ~selection: FetchState.selection,
    ~itemsTarget as _,
    ~retry,
    ~logger as _,
  ) => {
    let startFetchingBatchTimeRef = Performance.now()

    // Always have a toBlock for an RPC worker
    let toBlock = switch toBlock {
    | Some(toBlock) => Pervasives.min(toBlock, knownHeight)
    | None => knownHeight
    }

    let firstBlockParentPromise =
      fromBlock > 0
        ? blockLoader.contents
          ->LazyLoader.get(fromBlock - 1)
          ->Promise.thenResolve(json => Some(parseBlockInfo(json)))
        : Promise.resolve(None)

    if selection.onEventRegistrations->Utils.Array.isEmpty {
      throw(
        Source.GetItemsError(
          UnsupportedSelection({
            message: "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
          }),
        ),
      )
    }

    let {items, toBlock: queriedToBlock, requestStats} = try await rpcClient.getNextPage({
      fromBlock,
      toBlockCeiling: toBlock,
      partitionId,
      registrationIndexes: selection.onEventRegistrations->Array.map(reg => reg.index),
      addressesByContractName,
    }) catch {
    | exn =>
      switch exn->parseGetNextPageRetryError {
      | Some((attemptedToBlock, retry, requestStats)) =>
        requestStats->Array.forEach(stat =>
          recordRequest(~method=stat.method, ~seconds=stat.seconds)
        )
        throw(Source.GetItemsError(FailedGettingItems({exn, attemptedToBlock, retry})))
      | None =>
        throw(
          Source.GetItemsError(
            FailedGettingItems({
              exn,
              attemptedToBlock: toBlock,
              retry: WithBackoff({
                message: "Unexpected issue while fetching events from the RPC client. Attempt a retry.",
                backoffMillis: switch retry {
                | 0 => 500
                | _ => 1000 * retry
                },
              }),
            }),
          ),
        )
      }
    }
    requestStats->Array.forEach(stat => recordRequest(~method=stat.method, ~seconds=stat.seconds))

    let latestFetchedBlockInfo = await blockLoader.contents
    ->LazyLoader.get(queriedToBlock)
    ->Promise.thenResolve(parseBlockInfo)

    let parsedQueueItems = await items
    ->Array.map(({log, onEventRegistrationIndex, params: decoded}: EvmRpcClient.rpcEventItem) => {
      // `log.address` comes back already normalized to the client's casing.
      let onEventRegistration = onEventRegistrations->Array.getUnsafe(onEventRegistrationIndex)
      let eventConfig =
        onEventRegistration.eventConfig->(
          Utils.magic: Internal.eventConfig => Internal.evmEventConfig
        )
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
                  onEventRegistrationIndex,
                  blockNumber: block->getBlockNumber,
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
                    srcAddress: log.address,
                    logIndex: log.logIndex,
                  }->Evm.fromPayload,
                })
        }
      )()
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
      requestStats: drainRequestStats(),
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
      let result =
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
      {Source.result, requestStats: drainRequestStats()}
    })
    ->Promise.catch(exn =>
      {Source.result: Error(exn), requestStats: drainRequestStats()}->Promise.resolve
    )
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
        recordRequest(~method="eth_blockNumber", ~seconds=timerRef->Performance.secondsSince)
        exn->throw
      }
      recordRequest(~method="eth_blockNumber", ~seconds=timerRef->Performance.secondsSince)
      {height, requestStats: drainRequestStats()}
    },
    getItemsOrThrow,
    ?createHeightSubscription,
  }
}
