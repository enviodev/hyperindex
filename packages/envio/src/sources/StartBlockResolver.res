// Reads a `start_block: latest` chain's head, once, the first time that chain
// is built. Never runs again: the resolved block is written to
// `envio_chains.start_block` and read back verbatim from then on, so a "latest"
// deploy that goes down and comes back backfills the gap instead of skipping
// it. The CLI's `-r` (`--restart`) flag is the exception, because it wipes the
// database - that is a fresh deploy, and resolves against the head at that time.
//
// One height request at a time, and nothing registered anywhere: this asks the
// sources a question and returns the answer. The chain's own polling starts
// afterwards, when the indexer loop wants a height that moves.

type options = {
  // A source that accepts the request and then says nothing must not eat the
  // whole deadline: bounding each attempt is what lets the next source be tried.
  attemptTimeoutMs: int,
  retryIntervalMs: int,
  // Long enough to ride out a provider blip on a first deploy, short enough that
  // a misconfigured endpoint - the likeliest reason a first deploy can't read a
  // head - fails with an error instead of hanging.
  deadlineMs: int,
}

let defaultOptions = {
  attemptTimeoutMs: 30_000,
  retryIntervalMs: 1000,
  deadlineMs: 5 * 60 * 1000,
}

type attempt =
  | Answered(int)
  | Failed(exn)
  | TimedOut

// Never rejects: every way the request can end is a value, so the caller's loop
// can't be broken by one source misbehaving.
let attemptOrTimeout = (source: Source.t, ~timeoutMs): promise<attempt> => {
  let timeoutId = ref(None)
  Promise.race([
    source.getHeightOrThrow()
    ->Promise.thenResolve((res: Source.getHeightResponse) => Answered(res.height))
    ->Promise.catch(exn => Promise.resolve(Failed(exn))),
    Promise.make(
      (resolve, _reject) => timeoutId := Some(setTimeout(() => resolve(TimedOut), timeoutMs)),
    ),
  ])->Promise.thenResolve(outcome => {
    timeoutId->Utils.clearTimeoutRef
    outcome
  })
}

// Sources that can serve historical sync, primaries first - the same ordering
// the indexer itself would use for a backfill. A realtime-only source is left
// out: it isn't what this chain will read its history from.
let candidateSources = (sources: array<Source.t>) => {
  let hasRealtime = sources->Array.some(source => source.sourceFor === Realtime)
  let roleOf = (source: Source.t) =>
    SourceManager.getSourceRole(~sourceFor=source.sourceFor, ~isRealtime=false, ~hasRealtime)
  sources
  ->Array.filter(source => roleOf(source)->Option.isSome)
  ->Array.toSorted((a, b) =>
    switch (roleOf(a), roleOf(b)) {
    | (Some(Primary), Some(Secondary)) => Ordering.less
    | (Some(Secondary), Some(Primary)) => Ordering.greater
    | _ => Ordering.equal
    }
  )
}

let resolveOrThrow = async (
  ~chainId: ChainId.t,
  ~sources: array<Source.t>,
  ~logger: Pino.t,
  ~options=defaultOptions,
): int => {
  let {attemptTimeoutMs, retryIntervalMs, deadlineMs} = options
  let candidates = candidateSources(sources)
  if candidates->Utils.Array.isEmpty {
    JsError.throwWithMessage(
      `Chain ${chainId->ChainId.toString}: can't resolve the "latest" start block because the chain has no source to read a height from.`,
    )
  }

  let giveUpAt = Date.now() +. deadlineMs->Int.toFloat
  let resolved = ref(None)
  let attempt = ref(0)

  while resolved.contents->Option.isNone {
    let source = candidates->Array.getUnsafe(mod(attempt.contents, candidates->Array.length))
    switch await source->attemptOrTimeout(~timeoutMs=attemptTimeoutMs) {
    | Answered(height) => resolved := Some(height)
    | (Failed(_) | TimedOut) as outcome =>
      logger->Logging.childTrace({
        "msg": `Couldn't read the head from the ${source.name} source while resolving a "latest" start block. Trying again.`,
        "err": switch outcome {
        | Failed(exn) => Some(exn->Utils.prettifyExn)
        | _ => None
        },
      })
      if Date.now() > giveUpAt {
        JsError.throwWithMessage(
          `Chain ${chainId->ChainId.toString}: couldn't resolve the "latest" start block - no source answered a height request within ${(deadlineMs / 1000)
              ->Int.toString}s. Check the chain's RPC/HyperSync endpoints and ENVIO_API_TOKEN, then start again.`,
        )
      }
      // Only once every source has had a turn: a blip on the primary is worth
      // asking the secondary about straight away, not after a wait.
      if mod(attempt.contents + 1, candidates->Array.length) === 0 {
        await Utils.delay(retryIntervalMs)
      }
      attempt := attempt.contents + 1
    }
  }

  resolved.contents->Option.getUnsafe
}
