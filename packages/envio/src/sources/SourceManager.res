// Rust decides which source answers, how a failure is retried and when a wait
// for a new block is over (`source_manager/`). This side makes the calls it
// asks for, arms its timers on the clock, and tells it how each one went.

module Native = {
  // Effects are only ever built by Rust.
  @@warning("-37")

  type t

  type sourceSpec = {
    name: string,
    sourceFor: Source.sourceFor,
    pollingInterval: int,
    canStream: bool,
  }

  @tag("kind")
  type effect =
    | Log({
        fieldsJson?: string,
        level: Logger.level,
        message: string,
        paramsJson?: string,
        err?: int,
      })
    | ArmTimer({timer: int, label: string, millis: int, jitter: bool})
    | ClearTimer({timer: int})
    | Defer({token: int})
    | RequestHeight({request: int, source: int})
    | SubscribeStream({source: int})
    | CloseStream({source: int})
    | ResolveWait({wait: int, height: int})
    | Reorg({source: int})
    | Attempt({request: int, source: int, toBlock?: int, retry: int, fieldsJson: string})
    | Resolve({request: int})
    | Reject({request: int, message: string})

  @tag("kind")
  type itemsFailure =
    | RateLimited({resetMs: int})
    | BehindHead({blockNumber: int})
    | UnsupportedSelection({message: string})
    | FieldSelection({message: string, blockNumber: int})
    | SuggestedToBlock({toBlock: int, attemptedToBlock: int})
    | Impossible({message: string, attemptedToBlock: int})
    | Backoff({message: string, backoffMillis: int, attemptedToBlock: int})

  type requestStatSample = {
    source: int,
    method: string,
    count: int,
    seconds: float,
    responseBlocks: Null.t<int>,
    emptyResponseCount: int,
  }
  type sourceHeightSample = {source: int, height: int}
  type heightStreamSample = {
    source: int,
    connectCount: int,
    disconnectReasons: array<string>,
    disconnectCounts: array<int>,
  }

  @send external make: (Core.sourceManagerCtor, array<sourceSpec>, bool, 'timing) => t = "make"
  @send external takeEffect: t => Nullable.t<effect> = "takeEffect"
  @send external timerFired: (t, int, float) => unit = "timerFired"
  @send
  external waitForNewBlock: (
    t,
    ~knownHeight: int,
    ~isRealtime: bool,
    ~reducedPolling: bool,
    ~now: float,
  ) => int = "waitForNewBlock"
  @send
  external heightAnswered: (t, int, int, array<Source.requestStat>) => unit = "heightAnswered"
  @send
  external heightFailed: (t, int, array<Source.requestStat>, Nullable.t<int>) => unit =
    "heightFailed"
  @send external streamHeight: (t, int, int) => unit = "streamHeight"
  @send external streamLive: (t, int) => unit = "streamLive"
  @send external streamDown: (t, int, string, Nullable.t<string>) => unit = "streamDown"
  @send
  external startItemsQuery: (
    t,
    ~fromBlock: int,
    ~toBlock: Nullable.t<int>,
    ~partitionId: string,
    ~addresses: int,
    ~isRealtime: bool,
    ~now: float,
  ) => int = "startItemsQuery"
  @send
  external itemsAnswered: (t, int, BlockStore.t, int, array<Source.requestStat>, float) => unit =
    "itemsAnswered"
  @send
  external itemsFailed: (
    t,
    int,
    itemsFailure,
    array<Source.requestStat>,
    Nullable.t<int>,
    float,
  ) => unit = "itemsFailed"
  @send
  external startBlockHashes: (t, array<int>, bool, float) => int = "startBlockHashes"
  @send
  external hashesAnswered: (t, int, BlockStore.t, array<Source.requestStat>, float) => unit =
    "hashesAnswered"
  @send
  external hashesFailed: (
    t,
    int,
    ~rateLimitResetMs: Nullable.t<int>,
    ~behindHeadBlock: Nullable.t<int>,
    array<Source.requestStat>,
    Nullable.t<int>,
    float,
  ) => unit = "hashesFailed"
  @send external abandonRequest: (t, int) => unit = "abandonRequest"
  @send external beginWaiting: (t, int) => bool = "beginWaiting"
  @send external finishWaiting: (t, int) => bool = "finishWaiting"
  @send external queriesStarted: (t, int) => unit = "queriesStarted"
  @send external queryFinished: t => unit = "queryFinished"
  @send external activeSource: t => int = "activeSource"
  @send external inFlight: t => int = "inFlight"
  @send external idleSeconds: t => float = "idleSeconds"
  @send external waitingForNewBlockSeconds: t => float = "waitingForNewBlockSeconds"
  @send external queryingSeconds: t => float = "queryingSeconds"
  @send external rateLimitTimeMs: (t, float) => float = "rateLimitTimeMs"
  @send external rateLimitResetInMs: (t, float) => Nullable.t<float> = "rateLimitResetInMs"
  @send external requestStatSamples: t => array<requestStatSample> = "requestStatSamples"
  @send external sourceHeightSamples: t => array<sourceHeightSample> = "sourceHeightSamples"
  @send external heightStreamSamples: t => array<heightStreamSample> = "heightStreamSamples"
}

type itemsRequest = {
  query: FetchState.query,
  knownHeight: int,
  reorgableFrom: option<int>,
  resolveItems: Source.blockRangeFetchResponse => unit,
  // Held between the answer and Rust accepting it, which can take a retry.
  mutable response: option<Source.blockRangeFetchResponse>,
}

type hashesRequest = {
  blockNumbers: array<int>,
  resolveHashes: BlockStore.t => unit,
  mutable blockStore: option<BlockStore.t>,
}

type requestKind = Items(itemsRequest) | Hashes(hashesRequest)

type request = {
  kind: requestKind,
  reject: exn => unit,
}

type t = {
  native: Native.t,
  sources: array<Source.t>,
  logger: Logger.t,
  clock: Clock.t,
  timers: Map.t<int, Clock.timer>,
  waits: Map.t<int, int => unit>,
  requests: Map.t<int, request>,
  closeStreams: Map.t<int, unit => unit>,
  // Failures a report handed over for its log lines, which only this side can
  // render. Released once the report's effects have run.
  errors: Map.t<int, exn>,
  mutable nextErrorId: int,
}

// Every field defaults to the production value. Only tests set them, to reach
// a stall, a recovery or a retry schedule without waiting out the real window.
type timing = {
  newBlockStallTimeout?: int,
  newBlockStallTimeoutRealtime?: int,
  stalledPollingInterval?: int,
  reducedPollingInterval?: int,
  recoveryTimeout?: float,
  heightRetryInitialMillis?: int,
  heightRetryMultiplier?: int,
  heightRetryMaxMillis?: int,
  heightPollTimeout?: int,
  clock?: Clock.t,
}

let make = (~sources: array<Source.t>, ~logger: Logger.t, ~isRealtime, ~timing: timing={}) => {
  native: Core.getAddon().sourceManager->Native.make(
    sources->Array.map((source): Native.sourceSpec => {
      name: source.name,
      sourceFor: source.sourceFor,
      pollingInterval: source.pollingInterval,
      canStream: source.createHeightSubscription->Option.isSome,
    }),
    isRealtime,
    timing,
  ),
  sources,
  logger,
  clock: timing.clock->Option.getOr(Clock.real),
  timers: Map.make(),
  waits: Map.make(),
  requests: Map.make(),
  closeStreams: Map.make(),
  errors: Map.make(),
  nextErrorId: 0,
}

let now = (sm: t) => sm.clock.now()

let holdError = (sm: t, exn) => {
  sm.nextErrorId = sm.nextErrorId + 1
  let id = sm.nextErrorId
  sm.errors->Map.set(id, exn)
  id
}

let logEffect = (sm: t, ~fieldsJson, ~level, ~message, ~paramsJson, ~err) => {
  let logger = switch fieldsJson {
  | Some(fieldsJson) => sm.logger->Logger.withFieldsJson(fieldsJson)
  | None => sm.logger
  }
  switch err->Option.flatMap(id => sm.errors->Map.get(id)) {
  | Some(exn) if logger->Logger.isEnabled(level) =>
    let params =
      paramsJson->Option.mapOr(Dict.make(), json =>
        json->JSON.parseOrThrow->(Utils.magic: JSON.t => dict<unknown>)
      )
    params->Dict.set("err", exn->Utils.prettifyExn->(Utils.magic: exn => unknown))
    logger->Logger.logAt(level, message, ~params)
  | _ => logger->Logger.logAtJson(level, message, ~paramsJson)
  }
}

let requestOrThrow = (sm: t, id) =>
  switch sm.requests->Map.get(id) {
  | Some(request) => request
  | None => JsError.throwWithMessage(`SourceManager has no request ${id->Int.toString}.`)
  }

// Drained one effect at a time: a call made while carrying one out can queue
// more, and they still run in the order they were owed.
let rec flush = (sm: t) => {
  let continue = ref(true)
  while continue.contents {
    switch sm.native->Native.takeEffect->Nullable.toOption {
    | Some(effect) => sm->execute(effect)
    | None => continue := false
    }
  }
}

// Every report to Rust goes through here, so the effects it leaves run before
// anything else does, and the failure it handed over is only held that long.
and report = (sm: t, ~err=?, call: option<int> => unit) => {
  let errId = err->Option.map(exn => sm->holdError(exn))
  call(errId)
  sm->flush
  errId->Option.forEach(id => sm.errors->Map.delete(id)->ignore)
}

and execute = (sm: t, effect: Native.effect) =>
  switch effect {
  | Log({?fieldsJson, level, message, ?paramsJson, ?err}) =>
    sm->logEffect(~fieldsJson, ~level, ~message, ~paramsJson, ~err)
  | ArmTimer({timer, label, millis, jitter}) =>
    let millis = jitter ? sm.clock->Clock.jitter(millis) : millis
    sm.timers->Map.set(
      timer,
      sm.clock.setTimeout(
        ~label,
        () => {
          sm.timers->Map.delete(timer)->ignore
          sm->report(_ => sm.native->Native.timerFired(timer, sm->now))
        },
        millis,
      ),
    )
  | Defer({token}) =>
    Promise.resolve()
    ->Promise.thenResolve(() => sm->report(_ => sm.native->Native.timerFired(token, sm->now)))
    ->Promise.ignore
  | ClearTimer({timer}) =>
    switch sm.timers->Map.get(timer) {
    | Some(handle) =>
      sm.clock.clearTimeout(handle)
      sm.timers->Map.delete(timer)->ignore
    | None => ()
    }
  | RequestHeight({request, source}) => sm->requestHeight(~request, ~source)
  | SubscribeStream({source}) => sm->subscribeStream(~source)
  | CloseStream({source}) =>
    switch sm.closeStreams->Map.get(source) {
    | Some(close) =>
      sm.closeStreams->Map.delete(source)->ignore
      close()
    | None => ()
    }
  | ResolveWait({wait, height}) =>
    switch sm.waits->Map.get(wait) {
    | Some(resolve) =>
      sm.waits->Map.delete(wait)->ignore
      resolve(height)
    | None => ()
    }
  | Reorg({source}) => (sm.sources->Array.getUnsafe(source)).onReorg->Option.forEach(cb => cb())
  | Attempt({request, source, ?toBlock, retry, fieldsJson}) =>
    sm->attempt(
      ~id=request,
      ~source=sm.sources->Array.getUnsafe(source),
      ~toBlock,
      ~retry,
      ~fieldsJson,
    )
  | Resolve({request}) =>
    let {kind} = sm->requestOrThrow(request)
    sm.requests->Map.delete(request)->ignore
    switch kind {
    | Items({resolveItems, response: Some(response)}) => resolveItems(response)
    | Hashes({resolveHashes, blockStore: Some(blockStore)}) => resolveHashes(blockStore)
    | Items(_) | Hashes(_) =>
      JsError.throwWithMessage("SourceManager resolved a request that has no answer.")
    }
  | Reject({request, message}) =>
    let {reject} = sm->requestOrThrow(request)
    sm.requests->Map.delete(request)->ignore
    reject(
      try %raw(`null`)->ErrorHandling.mkLogAndRaise(~logger=sm.logger, ~msg=message) catch {
      | exn => exn
      },
    )
  }

and requestHeight = (sm: t, ~request, ~source) => {
  let call = try (sm.sources->Array.getUnsafe(source)).getHeightOrThrow() catch {
  | exn => Promise.reject(exn)
  }
  // Raced and awaited the way the height feed did before it moved to Rust, so
  // the answer lands as many reactions after the call as it always has: what
  // reacts to the waits it settles still runs where it used to, relative to
  // the rest of the indexer.
  let outcome = Promise.race([
    call
    ->Promise.thenResolve(response => Ok(response))
    ->Promise.catch(exn => Promise.resolve(Error(exn))),
    Promise.make((_, _) => ()),
  ])->Promise.thenResolve(outcome => outcome)
  let reportOutcome = async () =>
    switch await outcome {
    | Ok({height, requestStats}: Source.getHeightResponse) =>
      sm->report(_ => sm.native->Native.heightAnswered(request, height, requestStats))
    | Error(exn) =>
      // Billed whether or not it answered; unwrapping also keeps the log the
      // provider's own message rather than the envelope carrying it.
      let failure = exn->Source.unpackNativeRequestFailure
      sm->report(~err=failure.cause, err =>
        sm.native->Native.heightFailed(request, failure.requestStats, err->Nullable.fromOption)
      )
    }
  reportOutcome()->Promise.ignore
}

and subscribeStream = (sm: t, ~source) =>
  switch (sm.sources->Array.getUnsafe(source)).createHeightSubscription {
  | Some(createSubscription) =>
    sm.closeStreams->Map.set(
      source,
      createSubscription(
        ~clock=sm.clock,
        ~onHeight=height => sm->report(_ => sm.native->Native.streamHeight(source, height)),
        ~onStatus=status =>
          sm->report(_ =>
            switch status {
            | Live => sm.native->Native.streamLive(source)
            | Down({reason, ?detail}) =>
              sm.native->Native.streamDown(
                source,
                reason->Source.downReasonLabel,
                detail->Nullable.fromOption,
              )
            }
          ),
      ),
    )
  | None => ()
  }

and attempt = (sm: t, ~id, ~source: Source.t, ~toBlock, ~retry, ~fieldsJson) => {
  let request = sm->requestOrThrow(id)
  let logger = sm.logger->Logger.withFieldsJson(fieldsJson)
  switch request.kind {
  | Items(items) => sm->attemptItems(~id, ~request, ~items, ~source, ~toBlock, ~retry, ~logger)
  | Hashes(hashes) => sm->attemptHashes(~id, ~hashes, ~source, ~logger)
  }
}

and attemptItems = (sm: t, ~id, ~request, ~items, ~source: Source.t, ~toBlock, ~retry, ~logger) => {
  let {query, knownHeight, reorgableFrom} = items
  let call = try source.getItemsOrThrow(
    ~fromBlock=query.fromBlock,
    ~toBlock,
    ~addressSet=query.addresses,
    ~reorgableFrom,
    ~partitionId=query.partitionId,
    ~knownHeight,
    ~selection=query.selection->FetchState.narrowSelectionToRange(~toBlock),
    ~itemsTarget=query.itemsTarget,
    ~retry,
    ~logger,
  ) catch {
  | exn => Promise.reject(exn)
  }
  call
  ->Promise.thenResolve(response => {
    items.response = Some(response)
    sm->report(_ =>
      sm.native->Native.itemsAnswered(
        id,
        response.blockStore,
        response.knownHeight,
        response.requestStats,
        sm->now,
      )
    )
  })
  ->Promise.catch(exn => {
    let failed = (~err=?, ~requestStats, failure) =>
      sm->report(~err?, err =>
        sm.native->Native.itemsFailed(id, failure, requestStats, err->Nullable.fromOption, sm->now)
      )
    switch exn {
    | Source.RateLimited({resetMs, requestStats}) =>
      failed(~requestStats, RateLimited({resetMs: resetMs}))
    | Source.SourceBehindHead({blockNumber, requestStats}) =>
      failed(~requestStats, BehindHead({blockNumber: blockNumber}))
    | Source.GetItemsError(UnsupportedSelection({message})) =>
      failed(~requestStats=[], UnsupportedSelection({message: message}))
    | Source.GetItemsError(FailedGettingFieldSelection({
        ?exn,
        message,
        blockNumber,
        requestStats,
      })) =>
      failed(~err=?exn, ~requestStats, FieldSelection({message, blockNumber}))
    | Source.GetItemsError(FailedGettingItems({?exn, attemptedToBlock, retry, requestStats})) =>
      failed(
        ~err=?exn,
        ~requestStats,
        switch retry {
        | WithSuggestedToBlock({toBlock}) => SuggestedToBlock({toBlock, attemptedToBlock})
        | ImpossibleForTheQuery({message}) => Impossible({message, attemptedToBlock})
        | WithBackoff({message, backoffMillis}) =>
          Backoff({message, backoffMillis, attemptedToBlock})
        },
      )
    | exn =>
      sm.native->Native.abandonRequest(id)
      sm.requests->Map.delete(id)->ignore
      request.reject(
        try exn->ErrorHandling.mkLogAndRaise(~logger, ~msg="Failed to fetch block Range") catch {
        | exn => exn
        },
      )
    }
    Promise.resolve()
  })
  ->Promise.ignore
}

and attemptHashes = (sm: t, ~id, ~hashes, ~source: Source.t, ~logger) => {
  let call = try source.getBlockHashes(~blockNumbers=hashes.blockNumbers, ~logger) catch {
  | exn => Promise.reject(exn)
  }
  let failed = (~requestStats, exn) =>
    sm->report(~err=exn, err => {
      let (rateLimitResetMs, behindHeadBlock) = switch exn {
      | Source.RateLimited({resetMs}) => (Nullable.Value(resetMs), Nullable.null)
      | Source.SourceBehindHead({blockNumber}) => (Nullable.null, Nullable.Value(blockNumber))
      | _ => (Nullable.null, Nullable.null)
      }
      sm.native->Native.hashesFailed(
        id,
        ~rateLimitResetMs,
        ~behindHeadBlock,
        requestStats,
        err->Nullable.fromOption,
        sm->now,
      )
    })
  call
  ->Promise.thenResolve(({result, requestStats}: Source.getBlockHashesResponse) =>
    switch result {
    | Ok(blockStore) =>
      hashes.blockStore = Some(blockStore)
      sm->report(_ => sm.native->Native.hashesAnswered(id, blockStore, requestStats, sm->now))
    | Error(exn) => failed(~requestStats, exn)
    }
  )
  // A call that rejects rather than resolving to an error made no requests it
  // could tell us about.
  ->Promise.catch(exn => {
    failed(~requestStats=[], exn)
    Promise.resolve()
  })
  ->Promise.ignore
}

let getActiveSource = (sm: t) => sm.sources->Array.getUnsafe(sm.native->Native.activeSource)

type requestStatSample = {
  sourceName: string,
  chainId: ChainId.t,
  method: string,
  count: int,
  seconds: float,
  responseBlocks: option<int>,
  emptyResponseCount: int,
}

let getRequestStatSamples = (sm: t) =>
  sm.native
  ->Native.requestStatSamples
  ->Array.map(({source, method, count, seconds, responseBlocks, emptyResponseCount}) => {
    let source = sm.sources->Array.getUnsafe(source)
    {
      sourceName: source.name,
      chainId: source.chainId,
      method,
      count,
      seconds,
      responseBlocks: responseBlocks->Null.toOption,
      emptyResponseCount,
    }
  })

type sourceHeightSample = {
  sourceName: string,
  chainId: ChainId.t,
  height: int,
}

let getSourceHeightSamples = (sm: t) =>
  sm.native
  ->Native.sourceHeightSamples
  ->Array.map(({source, height}) => {
    let source = sm.sources->Array.getUnsafe(source)
    {sourceName: source.name, chainId: source.chainId, height}
  })

type streamSample = {connectCount: int, disconnectsByReason: array<(string, int)>}

type heightStreamSample = {
  sourceName: string,
  chainId: ChainId.t,
  stream: streamSample,
}

let getHeightStreamSamples = (sm: t) =>
  sm.native
  ->Native.heightStreamSamples
  ->Array.map(({source, connectCount, disconnectReasons, disconnectCounts}) => {
    let source = sm.sources->Array.getUnsafe(source)
    {
      sourceName: source.name,
      chainId: source.chainId,
      stream: {
        connectCount,
        disconnectsByReason: disconnectReasons->Array.mapWithIndex((reason, index) => (
          reason,
          disconnectCounts->Array.getUnsafe(index),
        )),
      },
    }
  })

let idleSeconds = (sm: t) => sm.native->Native.idleSeconds
let waitingForNewBlockSeconds = (sm: t) => sm.native->Native.waitingForNewBlockSeconds
let queryingSeconds = (sm: t) => sm.native->Native.queryingSeconds
let inFlightCount = (sm: t) => sm.native->Native.inFlight
let getRateLimitTimeMs = (sm: t) => sm.native->Native.rateLimitTimeMs(sm->now)
let getRateLimitResetInMs = (sm: t) =>
  sm.native->Native.rateLimitResetInMs(sm->now)->Nullable.toOption

let onReorg = (sm: t) =>
  sm.sources->Array.forEach(source => source.onReorg->Option.forEach(cb => cb()))

let waitForNewBlock = (sm: t, ~knownHeight, ~isRealtime, ~reducedPolling) =>
  Promise.make((resolve, _reject) =>
    sm->report(_ => {
      let wait =
        sm.native->Native.waitForNewBlock(~knownHeight, ~isRealtime, ~reducedPolling, ~now=sm->now)
      sm.waits->Map.set(wait, resolve)
    })
  )

let executeQuery = (sm: t, ~query: FetchState.query, ~knownHeight, ~isRealtime, ~reorgableFrom) =>
  Promise.make((resolve, reject) =>
    sm->report(_ => {
      let id =
        sm.native->Native.startItemsQuery(
          ~fromBlock=query.fromBlock,
          ~toBlock=query.toBlock->Nullable.fromOption,
          ~partitionId=query.partitionId,
          ~addresses=query.addresses->AddressSet.size,
          ~isRealtime,
          ~now=sm->now,
        )
      sm.requests->Map.set(
        id,
        {
          kind: Items({query, knownHeight, reorgableFrom, resolveItems: resolve, response: None}),
          reject,
        },
      )
    })
  )

let getBlockHashes = (sm: t, ~blockNumbers, ~isRealtime) =>
  Promise.make((resolve, reject) =>
    sm->report(_ => {
      let id = sm.native->Native.startBlockHashes(blockNumbers, isRealtime, sm->now)
      sm.requests->Map.set(
        id,
        {
          kind: Hashes({blockNumbers, resolveHashes: resolve, blockStore: None}),
          reject,
        },
      )
    })
  )

// Carries out the fetch decision CrossChainState.checkAndFetch made: dispatch
// the admitted queries or start waiting for a new block.
let dispatch = async (
  sm: t,
  ~fetchState: FetchState.t,
  ~executeQuery,
  ~waitForNewBlock,
  ~onNewBlock,
  ~action: FetchState.nextQuery,
  ~stateId,
) =>
  switch action {
  | NothingToQuery => ()
  | WaitingForNewBlock =>
    if sm.native->Native.beginWaiting(stateId) {
      let knownHeight = await waitForNewBlock(~knownHeight=fetchState.knownHeight)
      if sm.native->Native.finishWaiting(stateId) {
        onNewBlock(~knownHeight)
      }
    }
  | Ready(queries) =>
    // Already marked in flight by ChainState.startFetchingQueries when they were
    // admitted; here they are only executed.
    sm.native->Native.queriesStarted(queries->Array.length)
    let _ = await queries
    ->Array.map(query => {
      let promise = query->executeQuery
      promise->Promise.thenResolve(_ => sm.native->Native.queryFinished)->Promise.ignore
      promise
    })
    ->Promise.all
  }
