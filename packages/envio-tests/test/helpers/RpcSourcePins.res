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
  latestFetchedBlockNumber: int,
  events: array<pinnedEvent>,
  blockHashes: array<ReorgDetection.blockData>,
  requestCounts: dict<int>,
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

// A chain's pair of EVM stores, as `ChainState` builds them.
let makeStores = (~shouldChecksum=false) => (
  BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum),
  TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum),
)

// Resolve a page's items the way the indexer does: both of its stores merge
// into the chain's, and materialisation reads those. Production splits the two
// merges across `registerReorgGuard` and `ChainFetching`, so keeping them in one
// place here is what stops a test drifting from that order.
let applyPage = async (
  response: Source.blockRangeFetchResponse,
  ~blockStore: BlockStore.t,
  ~transactionStore: TransactionStore.t,
) => {
  blockStore->BlockStore.merge(response.blockStore, ~fromBlock=0, ~reportOnly=false)->ignore
  switch response.transactionStore {
  | Some(page) => transactionStore->TransactionStore.merge(page)
  | None => ()
  }
  await ChainState.materializePageItems(
    ~items=response.parsedQueueItems,
    ~transactionStore,
    ~blockStore,
  )
}

// The page's own stores back `block` and `transaction`, so the pin resolves
// them from the chain's stores once the page has been applied to them.
let normalizePage = async (
  response: Source.blockRangeFetchResponse,
  ~blockStore: BlockStore.t,
  ~transactionStore: TransactionStore.t,
): pinnedPage => {
  await response->applyPage(~blockStore, ~transactionStore)
  {
    knownHeight: response.knownHeight,
    latestFetchedBlockNumber: response.latestFetchedBlockNumber,
    events: response.parsedQueueItems->Array.map(normalizeEvent),
    // Read from the merged store: merging moves the page's rows into it, so
    // the page is empty by now.
    blockHashes: blockStore->storedBlockHashes,
    requestCounts: response.requestStats->countRequests,
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
    exn->jsExnMessage
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
      // A field-selection failure carries no provider error of its own, so the
      // cause is null rather than a JS error.
      causeMessage: exn->providerMessage,
    })
  }

// Each pin drives a single fetch, so the chain's stores start empty and the
// page's own rows are all there is to materialise from.
let capture = async getPage => {
  let (blockStore, transactionStore) = makeStores()
  try Ok(await (await getPage())->normalizePage(~blockStore, ~transactionStore)) catch {
  | Source.GetItemsError(error) => Error(error->normalizeError)
  }
}
