// Stable projections of the public Source.t RPC behavior. These deliberately
// omit wall-clock durations and JS stacks while preserving request counts,
// event order, selected payload fields, reorg hashes, and retry decisions.

type pinnedEvent = {
  registrationId: string,
  chainId: int,
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
  latestFetchedBlockTimestamp: int,
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
  | FailedGettingItems({
      attemptedToBlock: int,
      providerMessage: option<string>,
      retry: pinnedRetry,
    })
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
      chain,
      blockNumber,
      logIndex,
      transactionIndex,
      payload,
    }) => {
      let payload = payload->Evm.toPayload
      {
        registrationId: onEventRegistration.eventConfig.id,
        chainId: chain->ChainMap.Chain.toChainId,
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

let normalizePage = (response: Source.blockRangeFetchResponse): pinnedPage => {
  knownHeight: response.knownHeight,
  fromBlockQueried: response.fromBlockQueried,
  latestFetchedBlockNumber: response.latestFetchedBlockNumber,
  latestFetchedBlockTimestamp: response.latestFetchedBlockTimestamp,
  events: response.parsedQueueItems->Array.map(normalizeEvent),
  blockHashes: response.blockHashes,
  requestCounts: response.requestStats->countRequests,
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
  try Ok((await getPage())->normalizePage) catch {
  | Source.GetItemsError(error) => Error(error->normalizeError)
  }
