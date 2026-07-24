// Per-chain onEvent + onBlock registrations. Used both as the live registration
// store (`activeRegistration`, where onEvent regs are raw: registration order,
// unmerged, unindexed, `where:false` ones kept) and as the finished output of
// `finishRegistration` (merged, backfilled, indexed).
type chainRegistrations = {
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

// The finished registration state returned by `finishRegistration`.
type registrationsByChainId = dict<chainRegistrations>

// The one registration, resolved once and reused. Handlers register into it at
// `onEvent`/`onBlock` call time (resolving for every chain in `config`, which is
// the full chain set), and it persists in `EnvioGlobal` across the many
// `finishRegistration` calls a single isolate makes (handler modules are
// import-cached and register only once). `finishRegistration` reads it and
// builds a fresh per-config output, never mutating the store.
type activeRegistration = {
  config: Config.t,
  registrationsByChainId: dict<chainRegistrations>,
  mutable finished: bool,
}

let getKey = (~contractName, ~eventName) => contractName ++ "." ++ eventName

// Test-only: reset to fresh-import state so a new registration cycle starts
// empty (production starts each isolate empty and registers once).
let resetOnEventRegistrations = () => {
  EnvioGlobal.value.activeRegistration = None
}

// A registration record detached from the global registry. The internal test
// indexer builds one per instance so handler sets stay isolated across configs.
let make = (~config: Config.t): activeRegistration => {
  config,
  registrationsByChainId: Dict.make(),
  finished: false,
}

// A scope override, when set, wins over the global `activeRegistration` so
// `indexer.onEvent`/`.onBlock` (and the `indexer` getters) resolve against the
// instance registration during a scoped handler import.
let getActiveRegistration = () =>
  switch EnvioGlobal.value.registrationScopeOverride->(
    Utils.magic: option<unknown> => option<activeRegistration>
  ) {
  | Some(_) as override => override
  | None =>
    EnvioGlobal.value.activeRegistration->(
      Utils.magic: option<unknown> => option<activeRegistration>
    )
  }

let getActiveConfig = (): option<Config.t> => getActiveRegistration()->Option.map(r => r.config)

// Serializes overlapping `withScope` calls: the override is a single global
// slot, so a second import must wait for the first to restore it, else its
// registrations would land under the wrong (or no) scope.
let scopeLock = ref(Promise.resolve())

// Run `fn` (typically a dynamic handler-module import) with `r` installed as
// the active registration scope, restoring the previous state afterwards even
// on failure. Serialized against other `withScope` calls.
let withScope = (r: activeRegistration, fn: unit => promise<unit>): promise<unit> => {
  let run = async () => {
    let prev = EnvioGlobal.value.registrationScopeOverride
    EnvioGlobal.value.registrationScopeOverride = Some(
      r->(Utils.magic: activeRegistration => unknown),
    )
    let result = try Ok(await fn()) catch {
    | exn => Error(exn)
    }
    EnvioGlobal.value.registrationScopeOverride = prev
    switch result {
    | Ok() => ()
    | Error(exn) => throw(exn)
    }
  }
  let next = scopeLock.contents->Promise.then(run)
  // Keep the lock chain alive even if this run rejects, so a later scoped
  // import isn't blocked forever behind a failed one.
  scopeLock := next->Promise.catch(_ => Promise.resolve())
  next
}

// Might happen for tests when the handler file
// is imported by a non-envio process (eg mocha)
// and initialized before we started registration.
// So we track them here to register when the startRegistration is called.
// Theoretically we could keep preRegistration without an explicit start
// but I want it to be this way, so for the actual indexer run
// an error is thrown with the exact stack trace where the handler was registered.
let preRegistered =
  EnvioGlobal.value.preRegistered->(
    Utils.magic: array<unknown> => array<activeRegistration => unit>
  )

let hasPreRegistered = () => preRegistered->Array.length > 0

let withRegistration = (fn: activeRegistration => unit) => {
  switch getActiveRegistration() {
  | None => preRegistered->Array.push(fn)
  | Some(r) =>
    if r.finished {
      JsError.throwWithMessage(
        "The indexer finished initializing, so no more handlers can be registered. Make sure the handlers are registered on the top level of the file.",
      )
    } else {
      fn(r)
    }
  }
}

// Idempotent: handlers register once (import-cached), so the first call builds
// the registration and every later call reuses it. `config` must be the full
// chain set — registrations resolve for all its chains here, and
// `finishRegistration` later narrows to whatever config it's given.
let startRegistration = (~config: Config.t) => {
  switch getActiveRegistration() {
  | Some(_) => ()
  | None =>
    let r = {
      config,
      registrationsByChainId: Dict.make(),
      finished: false,
    }
    EnvioGlobal.value.activeRegistration = Some(r->(Utils.magic: activeRegistration => unknown))
    // Replay pre-registered callbacks in source (FIFO) order, then clear. For
    // multiple handlers on one event this replay order is the dispatch order, so
    // it must not reverse (which `Array.pop` would).
    let queued = preRegistered->Array.copy
    preRegistered->Array.splice(~start=0, ~remove=preRegistered->Array.length, ~insert=[])
    queued->Array.forEach(fn => fn(r))
  }
}

let getChainRegistrations = (r: activeRegistration, ~chainId: int): chainRegistrations => {
  let key = chainId->Int.toString
  switch r.registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(existing) => existing
  | None =>
    let fresh: chainRegistrations = {
      onEventRegistrations: [],
      onBlockRegistrations: [],
    }
    r.registrationsByChainId->Dict.set(key, fresh)
    fresh
  }
}

let buildOnEventRegistrationWith = (
  ~config: Config.t,
  ~chainId: int,
  ~eventConfig: Internal.eventConfig,
  ~isWildcard: bool,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~where: option<JSON.t>,
  ~startBlock=?,
): Internal.onEventRegistration => {
  switch config.ecosystem.name {
  | Fuel =>
    (EventConfigBuilder.buildFuelOnEventRegistration(
      ~eventConfig=eventConfig->(Utils.magic: Internal.eventConfig => Internal.fuelEventConfig),
      ~isWildcard,
      ~handler,
      ~contractRegister,
      ~startBlock?,
    ) :> Internal.onEventRegistration)
  | Svm =>
    (EventConfigBuilder.buildSvmOnEventRegistration(
      ~eventConfig=eventConfig->(
        Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig
      ),
      ~isWildcard,
      ~handler,
      ~contractRegister,
      ~startBlock?,
    ) :> Internal.onEventRegistration)
  | Evm =>
    (EventConfigBuilder.buildEvmOnEventRegistration(
      ~eventConfig=eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig),
      ~isWildcard,
      ~handler,
      ~contractRegister,
      ~where,
      ~chainId,
      ~onEventBlockFilterSchema=config.ecosystem.onEventBlockFilterSchema,
      ~startBlock?,
    ) :> Internal.onEventRegistration)
  }
}

let getResolvedWhere = (reg: Internal.onEventRegistration) =>
  (
    reg->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration)
  ).resolvedWhere

// Two chain registrations target the same fetched log when they share the
// event, the wildcard flag, and (on EVM) the resolved `where` — a handler and
// a contractRegister that agree on all three can be merged into one
// registration (so one item per log runs both). `where` is compared on the
// resolved structure (`Values` by hex arrays, `ContractAddresses` by contract
// name, plus `startBlock`); differing filters stay separate registrations.
let sameEventAndFilter = (
  a: Internal.onEventRegistration,
  b: Internal.onEventRegistration,
  ~config: Config.t,
) =>
  a.eventConfig.contractName === b.eventConfig.contractName &&
  a.eventConfig.name === b.eventConfig.name &&
  a.isWildcard === b.isWildcard &&
  switch config.ecosystem.name {
  | Evm => getResolvedWhere(a) == getResolvedWhere(b)
  | Fuel | Svm => true
  }

// Merge each contractRegister into a matching handler registration (either
// registration order; the merged registration takes the handler's slot so
// dispatch order follows handler registration order). Two handlers (or two
// contractRegisters) for one event never merge. Operates on the raw per-chain
// registrations stored at `onEvent` time; shared by `finishRegistration` and
// simulate so both see the same registrations.
let mergeRegistrations = (resolved: array<Internal.onEventRegistration>, ~config: Config.t): array<
  Internal.onEventRegistration,
> => {
  let merged: ref<array<Internal.onEventRegistration>> = ref([])
  resolved->Array.forEach((reg: Internal.onEventRegistration) => {
    if reg.handler->Option.isSome {
      // A handler absorbs a matching contractRegister-only registration,
      // dropping it and taking its own (handler) slot.
      switch merged.contents->Array.findIndex(m =>
        m.handler->Option.isNone &&
        m.contractRegister->Option.isSome &&
        sameEventAndFilter(m, reg, ~config)
      ) {
      | -1 => merged := merged.contents->Array.concat([reg])
      | i =>
        let target = merged.contents->Array.getUnsafe(i)
        merged :=
          merged.contents
          ->Array.filterWithIndex((_, j) => j !== i)
          ->Array.concat([{...reg, contractRegister: target.contractRegister}])
      }
    } else {
      // A contractRegister merges into a matching handler registration,
      // keeping the handler's slot.
      switch merged.contents->Array.findIndex(m =>
        m.handler->Option.isSome &&
        m.contractRegister->Option.isNone &&
        sameEventAndFilter(m, reg, ~config)
      ) {
      | -1 => merged := merged.contents->Array.concat([reg])
      | i =>
        let target = merged.contents->Array.getUnsafe(i)
        let next = merged.contents->Array.copy
        next->Array.setUnsafe(i, {...target, contractRegister: reg.contractRegister})
        merged := next
      }
    }
  })
  merged.contents
}

// A `where` that resolved to no topic selections (`false` for this chain)
// should never be fetched or dispatched here — drop it. Only meaningful on EVM.
let isDroppedByWhere = (~config: Config.t, reg: Internal.onEventRegistration) =>
  config.ecosystem.name === Evm && (reg->getResolvedWhere).topicSelections->Utils.Array.isEmpty

// Resolve one `onEvent`/`contractRegister` call into a registration for every
// chain in the config (the full chain set) and store it in registration order.
// Building runs the user's `where` callback here — once per chain — so a broken
// filter throws at the call site. A chain that doesn't define the event is
// skipped.
let addOnEventRegistration = (
  registration: activeRegistration,
  ~contractName,
  ~eventName,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~eventOptions: option<Internal.eventOptions<JSON.t>>,
) => {
  let isWildcard = eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false)
  let where = eventOptions->Option.flatMap(v => v.where)
  let matched = ref(false)
  registration.config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig =>
    switch chainConfig.contracts->Array.find(c => c.name === contractName) {
    | None => ()
    | Some(contract) =>
      switch contract.events->Array.find(e => e.name === eventName) {
      | None => ()
      | Some(eventConfig) =>
        matched := true
        let reg = buildOnEventRegistrationWith(
          ~config=registration.config,
          ~chainId=chainConfig.id,
          ~eventConfig,
          ~isWildcard,
          ~handler,
          ~contractRegister,
          ~where,
          ~startBlock=?contract.startBlock,
        )
        (registration->getChainRegistrations(~chainId=chainConfig.id)).onEventRegistrations
        ->Array.push(reg)
        ->ignore
      }
    }
  )

  // A scoped registration (internal test indexer) that matches no configured
  // contract/event is almost always a typo — the handler would silently never
  // run. The global path stays lenient (a shared contract may legitimately be
  // absent from a narrowed config).
  if !matched.contents && EnvioGlobal.value.registrationScopeOverride->Option.isSome {
    JsError.throwWithMessage(
      `No event "${eventName}" is configured on contract "${contractName}", so the handler would never run. Check the contract and event names against your config.`,
    )
  }
}

let setHandler = (~contractName, ~eventName, handler, ~eventOptions) => {
  withRegistration(registration => {
    let newHandler = handler->(Utils.magic: Internal.genericHandler<'args> => Internal.handler)
    let eventOptions =
      eventOptions->Option.map(v =>
        v->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
      )
    registration->addOnEventRegistration(
      ~contractName,
      ~eventName,
      ~handler=Some(newHandler),
      ~contractRegister=None,
      ~eventOptions,
    )
  })
}

let setContractRegister = (~contractName, ~eventName, contractRegister, ~eventOptions) => {
  withRegistration(registration => {
    let newContractRegister =
      contractRegister->(
        Utils.magic: Internal.genericContractRegister<
          Internal.genericContractRegisterArgs<'event, 'context>,
        > => Internal.contractRegister
      )
    let eventOptions =
      eventOptions->Option.map(v =>
        v->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
      )
    registration->addOnEventRegistration(
      ~contractName,
      ~eventName,
      ~handler=None,
      ~contractRegister=Some(newContractRegister),
      ~eventOptions,
    )
  })
}

// Raw onEvent registrations stored for a chain (empty if the chain has none).
let storedOnEventRegistrations = (r: activeRegistration, ~chainId: int): array<
  Internal.onEventRegistration,
> =>
  switch r.registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(chainId->Int.toString) {
  | Some(chainRegs) => chainRegs.onEventRegistrations
  | None => []
  }

// True when any registration for the event is a wildcard. Used by simulate to
// decide whether a src address needs deriving.
let isWildcard = (~registration: activeRegistration, ~contractName, ~eventName) =>
  registration.registrationsByChainId
  ->Dict.valuesToArray
  ->Array.some(chainRegs =>
    chainRegs.onEventRegistrations->Array.some(reg =>
      reg.eventConfig.contractName === contractName &&
      reg.eventConfig.name === eventName &&
      reg.isWildcard
    )
  )

// Every registration for one event on a chain, so simulate fans a simulated
// event out to each the way real routing does. Falls back to a bare
// registration when the event has no handler/contractRegister, so a simulated
// item still produces an item to run.
let getSimulateOnEventRegistrations = (
  ~registration: activeRegistration,
  ~config: Config.t,
  ~chainId: int,
  ~eventConfig: Internal.eventConfig,
): array<Internal.onEventRegistration> => {
  let stored = registration->storedOnEventRegistrations(~chainId)
  let matching =
    mergeRegistrations(stored, ~config)->Array.filter(reg =>
      reg.eventConfig.contractName === eventConfig.contractName &&
        reg.eventConfig.name === eventConfig.name
    )
  if matching->Utils.Array.notEmpty {
    matching
  } else {
    [
      buildOnEventRegistrationWith(
        ~config,
        ~chainId,
        ~eventConfig,
        ~isWildcard=false,
        ~handler=None,
        ~contractRegister=None,
        ~where=None,
      ),
    ]
  }
}

let finish = (r: activeRegistration, ~config: Config.t): registrationsByChainId => {
  r.finished = true
  let notRegisteredEventsByContract: dict<Utils.Set.t<string>> = Dict.make()
  let registrationsByChainId: registrationsByChainId = Dict.make()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let chainId = chainConfig.id
    let key = chainId->Int.toString

    let builtRegs = mergeRegistrations(r->storedOnEventRegistrations(~chainId), ~config)
    let registeredKeys = Utils.Set.make()
    builtRegs->Array.forEach(reg =>
      registeredKeys
      ->Utils.Set.add(
        getKey(~contractName=reg.eventConfig.contractName, ~eventName=reg.eventConfig.name),
      )
      ->ignore
    )

    // Events with no handler/contractRegister aren't fetched or dispatched
    // unless raw events are enabled, in which case a bare registration is
    // added to fetch them. Otherwise they're reported once below. Keyed on
    // the resolved registrations (before the where-empty drop) so a
    // `where: false` event still counts as registered — its handler opted
    // out of this chain, so it gets no raw-event registration either.
    let rawEventRegs = []
    chainConfig.contracts->Array.forEach(contract => {
      contract.events->Array.forEach(
        eventConfig => {
          if (
            !(
              registeredKeys->Utils.Set.has(
                getKey(~contractName=contract.name, ~eventName=eventConfig.name),
              )
            )
          ) {
            if config.enableRawEvents {
              rawEventRegs
              ->Array.push(
                buildOnEventRegistrationWith(
                  ~config,
                  ~chainId,
                  ~eventConfig,
                  ~isWildcard=false,
                  ~handler=None,
                  ~contractRegister=None,
                  ~where=None,
                  ~startBlock=?contract.startBlock,
                ),
              )
              ->ignore
            } else {
              let eventNames = switch notRegisteredEventsByContract->Utils.Dict.dangerouslyGetNonOption(
                contract.name,
              ) {
              | Some(set) => set
              | None => {
                  let set = Utils.Set.make()
                  notRegisteredEventsByContract->Dict.set(contract.name, set)
                  set
                }
              }
              eventNames->Utils.Set.add(eventConfig.name)->ignore
            }
          }
        },
      )
    })

    // Drop registrations whose `where` opts out of this chain, then assign
    // each survivor its chain-scoped index by position.
    let onEventRegistrations: array<Internal.onEventRegistration> = []
    builtRegs
    ->Array.concat(rawEventRegs)
    ->Array.forEach(reg => {
      if !isDroppedByWhere(~config, reg) {
        onEventRegistrations
        ->Array.push({...reg, index: onEventRegistrations->Array.length})
        ->ignore
      }
    })

    registrationsByChainId->Dict.set(
      key,
      {
        onEventRegistrations,
        // Copy so a consumer appending to the output (e.g. simulate source
        // registration) never mutates the persistent store.
        onBlockRegistrations: switch r.registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(
          key,
        ) {
        | Some(chainRegs) => chainRegs.onBlockRegistrations->Array.copy
        | None => []
        },
      },
    )
  })

  // Reported once for the whole indexer (a shared contract on multiple
  // chains would otherwise repeat the same message per chain).
  let notRegisteredEntries = notRegisteredEventsByContract->Dict.toArray
  if notRegisteredEntries->Utils.Array.notEmpty {
    let groups =
      notRegisteredEntries
      ->Array.map(((contractName, eventNames)) =>
        `${contractName} (${eventNames->Utils.Set.toArray->Array.joinUnsafe(", ")})`
      )
      ->Array.joinUnsafe(", ")
    Logging.getLogger()->Logging.childInfo(
      `Events without a handler, skipped for indexing: ${groups}`,
    )
  }

  registrationsByChainId
}

let finishRegistration = (~config: Config.t): registrationsByChainId => {
  switch getActiveRegistration() {
  | Some(r) => r->finish(~config)
  | None =>
    JsError.throwWithMessage(
      "The indexer has not started registering handlers, so can't finish it.",
    )
  }
}

let isPendingRegistration = () => {
  switch getActiveRegistration() {
  | Some(r) => !r.finished
  | None => false
  }
}

// Early guard called from `indexer.onEvent` / `.contractRegister` / `.onBlock` /
// `.onSlot` so the user sees a method-specific error at the call site, instead
// of hitting the generic `withRegistration` throw deep inside `setHandler` etc.
let throwIfFinishedRegistration = (~methodName) => {
  switch getActiveRegistration() {
  | Some({finished: true}) =>
    JsError.throwWithMessage(
      `Cannot call \`indexer.${methodName}\` after the indexer has started. Make sure all handlers are registered at the top level of your handler module.`,
    )
  | _ => ()
  }
}

// Shape of the user-returned `{_gte?, _lte?, _every?}` filter chunk after
// the ecosystem-specific wrapper is stripped. Shared across all ecosystems —
// the outer `block.number` / `block.height` / `slot` unwrap lives on each
// ecosystem's `onBlockFilterSchema`, and the inner range fields are the
// same everywhere.
type blockRange = {
  _gte: option<int>,
  _lte: option<int>,
  _every: int,
}

// `S.strict` rejects unknown fields so typos like `_gt` / `_evry` surface
// with a readable schema error pointing at the offending key, instead of
// silently registering a broken filter. `_every` defaults to 1 inside the
// schema so the caller always sees a plain `int`, and `intMin(1)` rejects
// zero/negative strides — `(blockNumber - startBlock) % 0` would crash and
// any negative stride would never match.
let blockRangeSchema: S.t<blockRange> = S.object(s => {
  _gte: s.field("_gte", S.option(S.int)),
  _lte: s.field("_lte", S.option(S.int)),
  _every: s.field("_every", S.option(S.int->S.intMin(1))->S.Option.getOr(1)),
})->S.strict

let defaultBlockRange: blockRange = {_gte: None, _lte: None, _every: 1}

// Two-stage parse: first the ecosystem-specific outer schema unwraps the
// wrapper (`block.number` / `block.height` / `slot`) and surfaces the
// inner chunk as raw `unknown`; then the shared `blockRangeSchema`
// validates the `{_gte?, _lte?, _every?}` fields. Keeping the inner
// validation in one place means typos and shape mismatches surface with
// the same user-friendly error regardless of ecosystem.
let extractRange = (filter: unknown, ~name, ~ecosystem: Ecosystem.t): blockRange =>
  try {
    switch filter->S.parseOrThrow(ecosystem.onBlockFilterSchema) {
    | None => defaultBlockRange
    | Some(inner) => inner->S.parseOrThrow(blockRangeSchema)
    }
  } catch {
  | S.Raised(exn) =>
    JsError.throwWithMessage(
      `\`indexer.${ecosystem.onBlockMethodName}("${name}")\` \`where\` returned an invalid filter: ${exn
        ->Utils.prettifyExn
        ->(Utils.magic: exn => string)}`,
    )
  }

// Mirrors `Envio.onBlockWhereArgs` without depending on the module.
type onBlockWhereArgs = {chain: unknown}

// `where` is evaluated once per configured chain at registration time.
// Decoded ranges/stride feed directly into the per-chain registration store
// so the fetcher's `(blockNumber - handlerStartBlock) % interval === 0`
// math in `FetchState` stays untouched. Deferred via `withRegistration` so
// the per-chain loop sees the registration's config, which may be a narrowed
// version of the generated one (TestIndexer runs with a per-test chain
// subset). `where` arrives unvalidated (`unknown`) straight from the user's
// options object.
let registerOnBlock = (
  ~name: string,
  ~where: unknown,
  ~handler: Internal.onBlockArgs => promise<unit>,
  ~getChainsObject: Config.t => dict<unknown>,
) => {
  withRegistration(registration => {
    let config = registration.config
    let ecosystem = config.ecosystem
    let chainsDict = getChainsObject(config)
    let logger = Logging.createChild(~params={"onBlock": name})

    // `where` must be a function (unlike onEvent, which also accepts a static
    // value). A static value would have to be evaluated against every chain
    // independently, which has no useful semantic for block handlers.
    // Normalize undefined/null to None up front so the per-chain loop below
    // can't accidentally call `null` as a predicate.
    let where = switch where {
    | w if w === %raw(`undefined`) || w === %raw(`null`) => None
    | w if typeof(w) === #function => Some(w->(Utils.magic: unknown => onBlockWhereArgs => unknown))
    | w =>
      JsError.throwWithMessage(
        `\`indexer.${ecosystem.onBlockMethodName}("${name}")\` expected \`where\` to be a function or omitted, but got ${(typeof(
            w,
          ) :> string)}.`,
      )
    }

    let matchedAny = ref(false)

    config.chainMap
    ->ChainMap.values
    ->Array.forEach(chainConfig => {
      let chainId = chainConfig.id
      let chainObj = chainsDict->Dict.getUnsafe(chainId->Int.toString)

      // Predicate returns `true` → match with no filter; `false` → skip;
      // any plain object → structured filter. `undefined`/`null` returns
      // are rejected — the TS type excludes `void`, so a missing return is
      // a user bug we surface early rather than silently match-all.
      let result = switch where {
      | None => %raw(`true`)
      | Some(predicate) => predicate({chain: chainObj})
      }

      let (shouldRegister, range) = if result === %raw(`true`) {
        (true, defaultBlockRange)
      } else if result === %raw(`false`) {
        (false, defaultBlockRange)
      } else if typeof(result) === #object && !(result->Array.isArray) && result !== %raw(`null`) {
        (true, extractRange(result, ~name, ~ecosystem))
      } else {
        // Reject numbers, strings, functions, arrays, undefined, null —
        // anything that isn't bool or a plain object would silently
        // misregister.
        JsError.throwWithMessage(
          `\`indexer.${ecosystem.onBlockMethodName}("${name}")\` \`where\` predicate returned an invalid value of type ${(typeof(
              result,
            ) :> string)}. Expected boolean or a filter object.`,
        )
      }

      if shouldRegister {
        matchedAny := true
        if range._gte->Option.getOr(chainConfig.startBlock) < chainConfig.startBlock {
          JsError.throwWithMessage(
            `The start block for onBlock handler "${name}" is less than the chain start block (${chainConfig.startBlock->Int.toString}). This is not supported yet.`,
          )
        }
        switch chainConfig.endBlock {
        | Some(chainEndBlock) =>
          if range._lte->Option.getOr(chainEndBlock) > chainEndBlock {
            JsError.throwWithMessage(
              `The end block for onBlock handler "${name}" is greater than the chain end block (${chainEndBlock->Int.toString}). This is not supported yet.`,
            )
          }
        | None => ()
        }
        let chainRegs = registration->getChainRegistrations(~chainId)
        chainRegs.onBlockRegistrations
        ->Array.push(
          (
            {
              index: chainRegs.onBlockRegistrations->Array.length,
              name,
              startBlock: range._gte,
              endBlock: range._lte,
              interval: range._every,
              chainId,
              handler,
            }: Internal.onBlockRegistration
          ),
        )
        ->ignore
      }
    })

    // Catches misconfigured `where` predicates that return `false` for every
    // configured chain — the handler would otherwise never fire with no hint.
    // Includes the ecosystem-specific method name so SVM users see "onSlot"
    // and don't get confused looking for a "Block handler" they never wrote.
    if !matchedAny.contents {
      logger->Logging.childWarn(
        `\`indexer.${ecosystem.onBlockMethodName}\` matched 0 chains. Check the \`where\` predicate.`,
      )
    }
  })
}
