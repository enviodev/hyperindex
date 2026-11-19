// Stable projections of the public Source.t RPC behavior. These deliberately
// omit wall-clock durations and JS stacks while preserving request counts,
// event order, selected payload fields, reorg hashes, and retry decisions.

type pinnedEvent = {
  registrationIndex: int,
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
  | FailedGettingFieldSelection({blockNumber: int, message: string, causeMessage: option<string>})
  | BehindHead({blockNumber: int})

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
        registrationIndex: onEventRegistration.index,
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
let storedBlockHashes = (buffer: ChainBuffer.t): array<ReorgDetection.blockData> => {
  let {blockNumbers, hashes} =
    buffer->ChainBuffer.getBlockHashes(~fromBlock=0, ~belowBlock=2147483647)
  blockNumbers->Array.mapWithIndex((blockNumber, index) => {
    ReorgDetection.blockNumber,
    blockHash: hashes->Array.getUnsafe(index),
  })
}

// A chain's buffer, as `ChainState` builds it: the RPC source reads it to
// leave out what it already holds, and the pages it returns merge into it.
let makeBuffer = (
  ~onEventRegistrations: array<Internal.onEventRegistration>,
  ~addressStore,
  ~shouldChecksum=false,
) =>
  ChainBuffer.makeForChain(
    ~ecosystem=Evm,
    ~onEventRegistrations,
    ~onBlockRegistrations=[],
    ~shouldChecksum,
    ~addressStore,
  )

// Resolve a page's items the way the indexer does: the page merges into the
// chain's buffer, and a build matches, decodes and joins its rows.
let applyPage = async (
  response: Source.blockRangeFetchResponse,
  ~buffer: ChainBuffer.t,
  ~onEventRegistrations: array<Internal.onEventRegistration>,
) =>
  await response.page->TestChainBuffer.buildAll(
    ~buffer,
    ~context={chainId: 1->ChainId.fromInt, onEventRegistrations, onBlockRegistrations: []},
  )

// The buffer backs `block` and `transaction`, so the pin resolves them once
// the page has been merged into it.
let normalizePage = async (
  response: Source.blockRangeFetchResponse,
  ~buffer: ChainBuffer.t,
  ~onEventRegistrations,
): pinnedPage => {
  let items = await response->applyPage(~buffer, ~onEventRegistrations)
  {
    knownHeight: response.knownHeight,
    latestFetchedBlockNumber: response.latestFetchedBlockNumber,
    events: items->Array.map(normalizeEvent),
    // Read from the buffer: merging moves the page's rows into it, so the
    // page is empty by now.
    blockHashes: buffer->storedBlockHashes,
    requestCounts: response.requestStats->countRequests,
  }
}

let jsExnMessage = exn =>
  switch exn {
  | JsExn(e) => e->JsExn.message
  | _ => None
  }

let providerMessage = exn => exn->Option.flatMap(jsExnMessage)

let normalizeRetry = retry =>
  switch retry {
  | Source.WithSuggestedToBlock({toBlock}) => SuggestedToBlock(toBlock)
  | WithBackoff({message, backoffMillis}) => Backoff({message, backoffMillis})
  | ImpossibleForTheQuery({message}) => Impossible(message)
  }

let normalizeError = error =>
  switch error {
  | Source.UnsupportedSelection({message}) => UnsupportedSelection(message)
  | FailedGettingItems({?exn, attemptedToBlock, retry}) =>
    FailedGettingItems({
      attemptedToBlock,
      providerMessage: exn->providerMessage,
      retry: retry->normalizeRetry,
    })
  | FailedGettingFieldSelection({?exn, blockNumber, message}) =>
    FailedGettingFieldSelection({
      blockNumber,
      message,
      causeMessage: exn->providerMessage,
    })
  }

// Each pin drives a single fetch, so the chain's buffer starts empty and the
// page's own rows are all there is to build from.
let capture = async (getPage, ~onEventRegistrations, ~addressStore, ~shouldChecksum=false) => {
  let buffer = makeBuffer(~onEventRegistrations, ~addressStore, ~shouldChecksum)
  try Ok(await (await getPage())->normalizePage(~buffer, ~onEventRegistrations)) catch {
  | Source.GetItemsError(error) => Error(error->normalizeError)
  | Source.SourceBehindHead({blockNumber}) => Error(BehindHead({blockNumber: blockNumber}))
  }
}
