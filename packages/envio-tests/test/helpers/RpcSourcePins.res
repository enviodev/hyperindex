// Stable projections of the public Source.t RPC behavior. These deliberately
// omit wall-clock durations and JS stacks while preserving request counts,
// event order, selected payload fields, reorg hashes, and retry decisions.

type pinnedEvent = {
  registrationId: string,
  chainId: ChainId.t,
  blockNumber: int,
  logIndex: int,
  transactionIndex: int,
  contractName: string,
  eventName: string,
  srcAddress: string,
  params: Internal.eventParams,
  block: option<Internal.eventBlock>,
  transaction: option<Internal.eventTransaction>,
}

type pinnedPage = {
  knownHeight: int,
  fromBlockQueried: int,
  latestFetchedBlockNumber: int,
  events: array<pinnedEvent>,
  blockHashes: array<ReorgDetection.blockData>,
  requestCounts: dict<int>,
  // Store rows the response reported missing (a null answer from the
  // provider), as stable key projections. SourceManager fills these through
  // fetchItemsStoreData before a response is applied.
  missingBlocks: array<int>,
  missingTransactions: array<(int, int)>,
}

type pinnedRetry =
  | SuggestedToBlock(int)
  | Backoff({message: string, backoffMillis: int})
  | Impossible(string)

type pinnedError =
  | UnsupportedSelection(string)
  | FailedGettingItems({attemptedToBlock: int, providerMessage: option<string>, retry: pinnedRetry})
  | FailedGettingFieldSelection({
      blockNumber: int,
      logIndex: int,
      message: string,
      causeMessage: option<string>,
    })

let countRequests = (stats: array<Source.requestStat>) => {
  let counts = Dict.make()
  stats->Array.forEach(({method}) =>
    counts->Dict.set(method, counts->Dict.get(method)->Option.getOr(0) + 1)
  )
  counts
}

let normalizeEvent = item =>
  switch item {
  | Internal.Event({
      onEventRegistration,
      chainId,
      blockNumber,
      logIndex,
      transactionIndex,
      payload,
    }) => {
      let payload = payload->Evm.toPayload
      {
        registrationId: onEventRegistration.eventConfig.id,
        chainId,
        blockNumber,
        logIndex,
        transactionIndex,
        contractName: payload.contractName,
        eventName: payload.eventName,
        srcAddress: payload.srcAddress->Address.toString,
        params: payload.params,
        block: payload.block,
        transaction: payload.transaction,
      }
    }
  | Internal.Block(_) =>
    JsError.throwWithMessage("RPC source contract pin unexpectedly received an onBlock item")
  }

// The page's reorg hashes as a stable (blockNumber, blockHash) list, ascending
// and deduplicated by block number.
let storedBlockHashes = (blockStore: BlockStore.t): array<ReorgDetection.blockData> =>
  blockStore
  ->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=2147483647)
  ->Array.filterMap(blockNumber =>
    switch blockStore->BlockStore.getHash(blockNumber) {
    | Null.Value(blockHash) => Some({ReorgDetection.blockNumber, blockHash})
    | Null.Null => None
    }
  )

let normalizePage = async (response: Source.blockRangeFetchResponse): pinnedPage => {
  // The payloads' block/transaction come from the response's store pages, the
  // way batch prep materialises them in production.
  await ChainState.materializePageItems(
    ~items=response.parsedQueueItems,
    ~transactionStore=response.transactionStore,
    ~blockStore=response.blockStore,
  )
  {
    knownHeight: response.knownHeight,
    fromBlockQueried: response.fromBlockQueried,
    latestFetchedBlockNumber: response.latestFetchedBlockNumber,
    events: response.parsedQueueItems->Array.map(normalizeEvent),
    blockHashes: response.blockStore->storedBlockHashes,
    requestCounts: response.requestStats->countRequests,
    missingBlocks: switch response.missingStoreData {
    | Some(missing) => missing.blocks->Array.map(b => b.blockNumber)
    | None => []
    },
    missingTransactions: switch response.missingStoreData {
    | Some(missing) => missing.transactions->Array.map(m => (m.blockNumber, m.transactionIndex))
    | None => []
    },
  }
}

let jsExnMessage = exn =>
  switch exn {
  | JsExn(e) => e->JsExn.message
  | _ => None
  }

let isNullish: 'a => bool = %raw(`value => value == null`)

let providerMessage = exn =>
  if exn->isNullish {
    None
  } else {
    exn->RpcSource.getErrorMessage
  }

let normalizeRetry = retry =>
  switch retry {
  | Source.WithSuggestedToBlock({toBlock}) => SuggestedToBlock(toBlock)
  | WithBackoff({message, backoffMillis}) => Backoff({message, backoffMillis})
  | ImpossibleForTheQuery({message}) => Impossible(message)
  }

let normalizeError = error =>
  switch error {
  | Source.UnsupportedSelection({message}) => UnsupportedSelection(message)
  | FailedGettingItems({exn, attemptedToBlock, retry}) =>
    FailedGettingItems({
      attemptedToBlock,
      providerMessage: exn->providerMessage,
      retry: retry->normalizeRetry,
    })
  | FailedGettingFieldSelection({exn, blockNumber, logIndex, message}) =>
    FailedGettingFieldSelection({
      blockNumber,
      logIndex,
      message,
      causeMessage: exn->jsExnMessage,
    })
  }

let capture = async getPage =>
  try Ok(await (await getPage())->normalizePage) catch {
  | Source.GetItemsError(error) => Error(error->normalizeError)
  }
