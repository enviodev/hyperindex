// Calls a source the way its contract tests do: once, outside any source
// manager, so a failure comes back as the source reported it instead of being
// retried.

type itemsCall = {
  page?: NativeSource.page,
  knownHeight?: int,
  failure?: Source.ItemsFailure.t,
  cause?: string,
  unexpected?: string,
  requestStats: array<Source.requestStat>,
}

type hashesCall = {
  blocks?: BlockStore.t,
  behindHeadBlock?: int,
  cause?: string,
  requestStats: array<Source.requestStat>,
}

@send
external callItems: (
  NativeSource.t,
  Source.nativeItemsQuery,
  AddressSet.t,
  int,
) => promise<itemsCall> = "callItems"

@send
external callBlockHashes: (NativeSource.t, array<int>) => promise<hashesCall> = "callBlockHashes"

let causeExn = cause => cause->Option.map(cause => JsError.make(cause)->JsExn.anyToExnInternal)

let getItemsOrThrow = async (
  source: Source.t,
  ~fromBlock,
  ~toBlock,
  ~addressSet,
  ~reorgableFrom,
  ~knownHeight,
  ~partitionId,
  ~selection: FetchState.selection,
  ~itemsTarget,
  ~retry,
  ~logger,
): Source.blockRangeFetchResponse =>
  switch source.implementation {
  | ReScript(calls) =>
    await calls.getItemsOrThrow(
      ~fromBlock,
      ~toBlock,
      ~addressSet,
      ~reorgableFrom,
      ~knownHeight,
      ~partitionId,
      ~selection,
      ~itemsTarget,
      ~retry,
      ~logger,
    )
  | Rust({source, decodeItemsPage}) =>
    let call = await source->callItems(
      Source.toNativeItemsQuery(
        ~fromBlock,
        ~toBlock,
        ~partitionId,
        ~knownHeight,
        ~reorgableFrom,
        ~itemsTarget,
        ~selection,
      ),
      addressSet,
      retry,
    )
    let {requestStats} = call
    let exn = causeExn(call.cause)
    switch call {
    | {page, knownHeight} => {...page->decodeItemsPage(~knownHeight), requestStats}
    | {failure: RateLimited({resetMs})} => throw(Source.RateLimited({resetMs, requestStats}))
    | {failure: BehindHead({blockNumber})} =>
      throw(Source.SourceBehindHead({blockNumber, requestStats}))
    | {failure: FieldSelection({message, blockNumber})} =>
      throw(
        Source.GetItemsError(
          FailedGettingFieldSelection({?exn, message, blockNumber, requestStats}),
        ),
      )
    | {failure: SuggestedToBlock({toBlock, attemptedToBlock})} =>
      throw(
        Source.GetItemsError(
          FailedGettingItems({
            ?exn,
            attemptedToBlock,
            retry: WithSuggestedToBlock({toBlock: toBlock}),
            requestStats,
          }),
        ),
      )
    | {failure: Impossible({message, attemptedToBlock})} =>
      throw(
        Source.GetItemsError(
          FailedGettingItems({
            ?exn,
            attemptedToBlock,
            retry: ImpossibleForTheQuery({message: message}),
            requestStats,
          }),
        ),
      )
    | {failure: Backoff({message, backoffMillis, attemptedToBlock})} =>
      throw(
        Source.GetItemsError(
          FailedGettingItems({
            ?exn,
            attemptedToBlock,
            retry: WithBackoff({message, backoffMillis}),
            requestStats,
          }),
        ),
      )
    | {unexpected} => JsError.throwWithMessage(unexpected)
    | _ => JsError.throwWithMessage("A source built in Rust answered with nothing.")
    }
  }

let getBlockHashes = async (
  source: Source.t,
  ~blockNumbers,
  ~logger,
): Source.getBlockHashesResponse =>
  switch source.implementation {
  | ReScript(calls) => await calls.getBlockHashes(~blockNumbers, ~logger)
  | Rust({source}) =>
    let call = await source->callBlockHashes(blockNumbers)
    let {requestStats} = call
    {
      result: switch call {
      | {blocks} => Ok(blocks)
      | {behindHeadBlock} =>
        Error(Source.SourceBehindHead({blockNumber: behindHeadBlock, requestStats}))
      | {cause} => Error(JsError.make(cause)->JsExn.anyToExnInternal)
      | _ =>
        Error(JsError.make("A source built in Rust answered with nothing.")->JsExn.anyToExnInternal)
      },
      requestStats,
    }
  }

// The calls of a source built in ReScript.
let calls = (source: Source.t) =>
  switch source.implementation {
  | ReScript(calls) => calls
  | Rust(_) =>
    JsError.throwWithMessage(`${source.name} is built in Rust and has no ReScript calls.`)
  }
