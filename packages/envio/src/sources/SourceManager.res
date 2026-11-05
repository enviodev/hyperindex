// Rust decides which source answers, how a failure is retried and when a wait
// for a new block is over, and runs its own timers (`source_manager/`). This
// side makes the calls it asks for and tells it how each one went.

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
        errMessage?: string,
      })
    | Defer({token: int})
    | RequestHeight({request: int, source: int})
    | SubscribeStream({source: int})
    | CloseStream({source: int})
    | ResolveWait({wait: int, height: int})
    | Reorg({source: int})
    | Attempt({request: int, source: int, toBlock?: int, retry: int, fieldsJson: string})
    | Resolve({request: int, nativeSource?: int})
    | Reject({request: int, message: string, cause?: string})

  type requestStatSample = {
    source: int,
    method: string,
    count: int,
    seconds: float,
    responseBlocks?: int,
    emptyResponseCount: int,
  }
  type sourceHeightSample = {source: int, height: int}
  type heightStreamSample = {
    source: int,
    connectCount: int,
    disconnectReasons: array<string>,
    disconnectCounts: array<int>,
  }

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
  }

  @send
  external make: (
    Core.sourceManagerCtor,
    array<sourceSpec>,
    bool,
    timing,
    Nullable.t<Clock.native>,
    unit => unit,
  ) => t = "make"
  @send external takeEffect: t => Nullable.t<effect> = "takeEffect"
  @send external attachSource: (t, int, NativeSource.t) => unit = "attachSource"
  @send external takeItemsPage: (t, int) => NativeSource.page = "takeItemsPage"
  @send external takeHashesPage: (t, int) => BlockStore.t = "takeHashesPage"
  @send external timerFired: (t, int) => unit = "timerFired"
  @send
  external waitForNewBlock: (
    t,
    ~knownHeight: int,
    ~isRealtime: bool,
    ~reducedPolling: bool,
  ) => int = "waitForNewBlock"
  @send
  external heightAnswered: (t, int, int, array<Source.requestStat>) => unit = "heightAnswered"
  @send external heightCallThrew: (t, int, Nullable.t<int>) => unit = "heightCallThrew"
  @send
  external heightFailed: (t, int, array<Source.requestStat>, Nullable.t<int>) => unit =
    "heightFailed"
  @send external streamHeight: (t, int, int) => unit = "streamHeight"
  @send external streamLive: (t, int) => unit = "streamLive"
  @send external streamDown: (t, int, string, Nullable.t<string>) => unit = "streamDown"
  @send
  external startItemsQuery: (t, Source.nativeItemsQuery, AddressSet.t, ~isRealtime: bool) => int =
    "startItemsQuery"
  @send
  external itemsAnswered: (t, int, BlockStore.t, int, array<Source.requestStat>) => unit =
    "itemsAnswered"
  @send
  external itemsFailed: (
    t,
    int,
    Source.ItemsFailure.t,
    array<Source.requestStat>,
    Nullable.t<int>,
  ) => unit = "itemsFailed"
  @send
  external startBlockHashes: (t, array<int>, ~isRealtime: bool) => int = "startBlockHashes"
  @send
  external hashesAnswered: (t, int, BlockStore.t, array<int>, array<Source.requestStat>) => unit =
    "hashesAnswered"
  @send
  external hashesFailed: (
    t,
    int,
    ~rateLimitResetMs: Nullable.t<int>,
    ~behindHeadBlock: Nullable.t<int>,
    array<Source.requestStat>,
    Nullable.t<int>,
  ) => unit = "hashesFailed"
  @send external abandonRequest: (t, int) => unit = "abandonRequest"
  @send external beginWaiting: (t, int) => bool = "beginWaiting"
  @send external finishWaiting: (t, int) => bool = "finishWaiting"
  @send external queriesStarted: (t, int) => unit = "queriesStarted"
  @send external queryFinished: t => unit = "queryFinished"
  @send external shutdown: t => unit = "shutdown"
  @send external activeSource: t => int = "activeSource"
  @send external inFlight: t => int = "inFlight"
  @send external idleSeconds: t => float = "idleSeconds"
  @send external waitingForNewBlockSeconds: t => float = "waitingForNewBlockSeconds"
  @send external queryingSeconds: t => float = "queryingSeconds"
  @send external rateLimitTimeMs: t => float = "rateLimitTimeMs"
  @send external rateLimitResetInMs: t => Nullable.t<float> = "rateLimitResetInMs"
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

let holdError = (sm: t, exn) => {
  sm.nextErrorId = sm.nextErrorId + 1
  let id = sm.nextErrorId
  sm.errors->Map.set(id, exn)
  id
}

let logEffect = (sm: t, ~fieldsJson, ~level, ~message, ~paramsJson, ~err, ~errMessage) => {
  let logger = switch fieldsJson {
  | Some(fieldsJson) => sm.logger->Logger.withFieldsJson(fieldsJson)
  | None => sm.logger
  }
  let exn = switch errMessage {
  | Some(message) => Some(JsError.make(message)->JsExn.anyToExnInternal)
  | None => err->Option.flatMap(id => sm.errors->Map.get(id))
  }
  switch exn {
  | Some(exn) =>
    let params =
      paramsJson->Option.mapOr(Dict.make(), json =>
        json->JSON.parseOrThrow->(Utils.magic: JSON.t => dict<unknown>)
      )
    params->Dict.set("err", exn->Utils.prettifyExn->(Utils.magic: exn => unknown))
    logger->Logger.logAt(level, message, ~params)
  | _ => logger->Logger.logAtJson(level, message, ~paramsJson)
  }
}

// Rust names only requests it was handed and has not settled.
let requestOf = (sm: t, id) => sm.requests->Map.get(id)->Option.getUnsafe

// Rust carries out every call to a source built in Rust itself.
let callsOf = (sm: t, source) =>
  switch (sm.sources->Array.getUnsafe(source)).implementation {
  | ReScript(calls) => calls
  | Rust(_) => JsError.throwWithMessage("A source built in Rust was handed to ReScript to call.")
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
  | Log({?fieldsJson, level, message, ?paramsJson, ?err, ?errMessage}) =>
    sm->logEffect(~fieldsJson, ~level, ~message, ~paramsJson, ~err, ~errMessage)
  | Defer({token}) =>
    Promise.resolve()
    ->Promise.thenResolve(() => sm->report(_ => sm.native->Native.timerFired(token)))
    ->Promise.ignore
  | RequestHeight({request, source}) => sm->requestHeight(~request, ~source)
  | SubscribeStream({source}) => sm->subscribeStream(~source)
  // Rust closes only a stream it opened, and resolves only a wait it was asked
  // for, each once.
  | CloseStream({source}) =>
    let close = sm.closeStreams->Map.get(source)->Option.getUnsafe
    sm.closeStreams->Map.delete(source)->ignore
    close()
  | ResolveWait({wait, height}) =>
    let resolve = sm.waits->Map.get(wait)->Option.getUnsafe
    sm.waits->Map.delete(wait)->ignore
    resolve(height)
  | Reorg({source}) => (sm->callsOf(source)).onReorg->Option.forEach(cb => cb())
  | Attempt({request, source, ?toBlock, retry, fieldsJson}) =>
    sm->attempt(~id=request, ~calls=sm->callsOf(source), ~toBlock, ~retry, ~fieldsJson)
  | Resolve({request, ?nativeSource}) =>
    let {kind} = sm->requestOf(request)
    sm.requests->Map.delete(request)->ignore
    // Resolved only after the answer it accepted was reported.
    switch (kind, nativeSource) {
    | (Items({resolveItems, knownHeight}), Some(source)) =>
      switch (sm.sources->Array.getUnsafe(source)).implementation {
      | Rust({decodeItemsPage}) =>
        resolveItems(sm.native->Native.takeItemsPage(request)->decodeItemsPage(~knownHeight))
      | ReScript(_) => JsError.throwWithMessage("A page came from a source built in ReScript.")
      }
    | (Items({resolveItems, response}), None) => resolveItems(response->Option.getUnsafe)
    | (Hashes({resolveHashes}), Some(_)) => resolveHashes(sm.native->Native.takeHashesPage(request))
    | (Hashes({resolveHashes, blockStore}), None) => resolveHashes(blockStore->Option.getUnsafe)
    }
  | Reject({request, message, ?cause}) =>
    let {reject} = sm->requestOf(request)
    sm.requests->Map.delete(request)->ignore
    let exn = switch cause {
    | Some(cause) => JsError.make(cause)->(Utils.magic: JsError.t => exn)
    | None => %raw(`null`)
    }
    reject(
      try exn->ErrorHandling.mkLogAndRaise(~logger=sm.logger, ~msg=message) catch {
      | exn => exn
      },
    )
  }

and requestHeight = (sm: t, ~request, ~source) =>
  switch (sm->callsOf(source)).getHeightOrThrow() {
  | call => sm->awaitHeight(~request, call)
  // Heard after the turn it threw on, as a poll loop awaiting it would.
  | exception exn =>
    Promise.resolve()
    ->Promise.thenResolve(() =>
      sm->report(~err=exn, err =>
        sm.native->Native.heightCallThrew(request, err->Nullable.fromOption)
      )
    )
    ->Promise.ignore
  }

and awaitHeight = (sm: t, ~request, call: promise<Source.getHeightResponse>) => {
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
      sm->report(~err=exn, err =>
        sm.native->Native.heightFailed(request, [], err->Nullable.fromOption)
      )
    }
  reportOutcome()->Promise.ignore
}

// Rust subscribes only a source that can push heights.
and subscribeStream = (sm: t, ~source) => {
  let createSubscription = (sm->callsOf(source)).createHeightSubscription->Option.getUnsafe
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
}

and attempt = (sm: t, ~id, ~calls, ~toBlock, ~retry, ~fieldsJson) => {
  let request = sm->requestOf(id)
  let logger = sm.logger->Logger.withFieldsJson(fieldsJson)
  switch request.kind {
  | Items(items) => sm->attemptItems(~id, ~request, ~items, ~calls, ~toBlock, ~retry, ~logger)
  | Hashes(hashes) => sm->attemptHashes(~id, ~hashes, ~calls, ~logger)
  }
}

and attemptItems = (
  sm: t,
  ~id,
  ~request,
  ~items,
  ~calls: Source.calls,
  ~toBlock,
  ~retry,
  ~logger,
) => {
  let {query, knownHeight, reorgableFrom} = items
  let call = try calls.getItemsOrThrow(
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
      )
    )
  })
  ->Promise.catch(exn => {
    let failed = (~err=?, ~requestStats, failure) =>
      sm->report(~err?, err =>
        sm.native->Native.itemsFailed(id, failure, requestStats, err->Nullable.fromOption)
      )
    switch exn {
    | Source.RateLimited({resetMs, requestStats}) =>
      failed(~requestStats, RateLimited({resetMs: resetMs}))
    | Source.SourceBehindHead({blockNumber, requestStats}) =>
      failed(~requestStats, BehindHead({blockNumber: blockNumber}))
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

and attemptHashes = (sm: t, ~id, ~hashes, ~calls: Source.calls, ~logger) => {
  let call = try calls.getBlockHashes(~blockNumbers=hashes.blockNumbers, ~logger) catch {
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
      )
    })
  call
  ->Promise.thenResolve(({result, requestStats}: Source.getBlockHashesResponse) =>
    switch result {
    | Ok(blockStore) =>
      hashes.blockStore = Some(blockStore)
      sm->report(_ =>
        sm.native->Native.hashesAnswered(id, blockStore, hashes.blockNumbers, requestStats)
      )
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

let make = (~sources: array<Source.t>, ~logger: Logger.t, ~isRealtime, ~timing: timing={}) => {
  let clock = timing.clock->Option.getOr(Clock.real)
  if Clock.refuseReal.contents && clock.native->Option.isNone {
    JsError.throwWithMessage(
      "A source manager made on virtual time without the clock's native handle, so its timers would run on real time.",
    )
  }
  // Rust calls this when one of its timers leaves something to do here.
  let onEffects = ref(() => ())
  let native = Core.getAddon().sourceManager->Native.make(
    sources->Array.map((source): Native.sourceSpec => {
      name: source.name,
      sourceFor: source.sourceFor,
      pollingInterval: source.pollingInterval,
      canStream: source->Source.canStream,
    }),
    isRealtime,
    {
      newBlockStallTimeout: ?timing.newBlockStallTimeout,
      newBlockStallTimeoutRealtime: ?timing.newBlockStallTimeoutRealtime,
      stalledPollingInterval: ?timing.stalledPollingInterval,
      reducedPollingInterval: ?timing.reducedPollingInterval,
      recoveryTimeout: ?timing.recoveryTimeout,
      heightRetryInitialMillis: ?timing.heightRetryInitialMillis,
      heightRetryMultiplier: ?timing.heightRetryMultiplier,
      heightRetryMaxMillis: ?timing.heightRetryMaxMillis,
      heightPollTimeout: ?timing.heightPollTimeout,
    },
    clock.native->Nullable.fromOption,
    () => onEffects.contents(),
  )
  let sm = {
    native,
    sources,
    logger,
    clock,
    waits: Map.make(),
    requests: Map.make(),
    closeStreams: Map.make(),
    errors: Map.make(),
    nextErrorId: 0,
  }
  sources->Array.forEachWithIndex((source, index) =>
    switch source.implementation {
    | Rust({source}) => native->Native.attachSource(index, source)
    | ReScript(_) => ()
    }
  )
  onEffects := (() => sm->flush)
  sm
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
  ->Array.map(({source, method, count, seconds, ?responseBlocks, emptyResponseCount}) => {
    let source = sm.sources->Array.getUnsafe(source)
    {
      sourceName: source.name,
      chainId: source.chainId,
      method,
      count,
      seconds,
      responseBlocks,
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
let getRateLimitTimeMs = (sm: t) => sm.native->Native.rateLimitTimeMs
let getRateLimitResetInMs = (sm: t) => sm.native->Native.rateLimitResetInMs->Nullable.toOption

let shutdown = (sm: t) => sm->report(_ => sm.native->Native.shutdown)

let onReorg = (sm: t) => sm.sources->Array.forEach(Source.onReorg)

let waitForNewBlock = (sm: t, ~knownHeight, ~isRealtime, ~reducedPolling) =>
  Promise.make((resolve, _reject) =>
    sm->report(_ => {
      let wait = sm.native->Native.waitForNewBlock(~knownHeight, ~isRealtime, ~reducedPolling)
      sm.waits->Map.set(wait, resolve)
    })
  )

let executeQuery = (sm: t, ~query: FetchState.query, ~knownHeight, ~isRealtime, ~reorgableFrom) =>
  Promise.make((resolve, reject) =>
    sm->report(_ => {
      let id =
        sm.native->Native.startItemsQuery(
          Source.toNativeItemsQuery(
            ~fromBlock=query.fromBlock,
            ~toBlock=query.toBlock,
            ~partitionId=query.partitionId,
            ~knownHeight,
            ~reorgableFrom,
            ~itemsTarget=query.itemsTarget,
            ~selection=query.selection,
          ),
          query.addresses,
          ~isRealtime,
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
      let id = sm.native->Native.startBlockHashes(blockNumbers, ~isRealtime)
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
  ~action: FetchState.Dispatched.t,
  ~stateId,
) =>
  switch action {
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
