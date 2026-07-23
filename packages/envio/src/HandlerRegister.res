// Per-chain onEventRegistrations built from the event definitions in
// `Config.t` plus whatever handler/contractRegister/eventOptions got
// registered for them, and the onBlock registrations collected during
// registration.
type chainRegistrations = {
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

// The finished registration state returned by `finishRegistration`.
type registrationsByChainId = dict<chainRegistrations>

// onBlock registrations collected per chain while registration is active.
// onEvent intents are chain-independent and resolved per config at
// `finishRegistration`, so nothing for them lives here.
type pendingChainRegistrations = {
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

type activeRegistration = {
  config: Config.t,
  registrationsByChainId: dict<pendingChainRegistrations>,
  mutable finished: bool,
}

// One `indexer.onEvent` / `.contractRegister` call as a chain-independent
// intent: the handler (xor contractRegister) plus its raw `where`/wildcard
// options. Resolved into per-chain `Internal.onEventRegistration`s at
// `finishRegistration`. Chain-independent so a single isolate can materialize
// registrations for different configs (TestIndexer narrows `chainMap` per
// `process()` call, and handler modules — import-cached — register only once).
type pendingOnEventRegistration = {
  contractName: string,
  eventName: string,
  handler: option<Internal.handler>,
  contractRegister: option<Internal.contractRegister>,
  eventOptions: option<Internal.eventOptions<JSON.t>>,
}

// Registration intents live in the process-wide `EnvioGlobal` record so they
// survive an import-cached re-registration cycle (handler modules run once;
// `finishRegistration` may run many times, per config).
let pendingOnEventRegistrations =
  EnvioGlobal.value.pendingOnEventRegistrations->(
    Utils.magic: array<unknown> => array<pendingOnEventRegistration>
  )

let getKey = (~contractName, ~eventName) => contractName ++ "." ++ eventName

// Test-only: reset to fresh-import state so a new registration cycle starts
// empty — clear the intent store and the active registration (production starts
// each isolate empty and registers once).
let resetOnEventRegistrations = () => {
  pendingOnEventRegistrations->Array.splice(
    ~start=0,
    ~remove=pendingOnEventRegistrations->Array.length,
    ~insert=[],
  )
  EnvioGlobal.value.activeRegistration = None
}

let getActiveRegistration = () =>
  EnvioGlobal.value.activeRegistration->(Utils.magic: option<unknown> => option<activeRegistration>)

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

let startRegistration = (~config: Config.t) => {
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

let getPendingChainRegistrations = (r: activeRegistration, ~chainId: int) => {
  let key = chainId->Int.toString
  switch r.registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(pending) => pending
  | None =>
    let fresh = {
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

// Resolve the chain-independent intents into this chain's registrations, then
// merge each contractRegister into a matching handler registration (either
// registration order; the merged registration takes the handler's slot so
// dispatch order follows handler registration order). Two handlers (or two
// contractRegisters) for one event never merge. Shared by `finishRegistration`
// and simulate so both see the same registrations.
let resolveChainRegistrations = (~config: Config.t, ~chainConfig: Config.chain): array<
  Internal.onEventRegistration,
> => {
  let chainId = chainConfig.id
  let resolved: array<Internal.onEventRegistration> = []
  pendingOnEventRegistrations->Array.forEach(intent => {
    chainConfig.contracts->Array.forEach(contract => {
      if contract.name === intent.contractName {
        switch contract.events->Array.find(e => e.name === intent.eventName) {
        | None => ()
        | Some(eventConfig) =>
          let isWildcard = intent.eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false)
          let where = intent.eventOptions->Option.flatMap(v => v.where)
          resolved
          ->Array.push(
            buildOnEventRegistrationWith(
              ~config,
              ~chainId,
              ~eventConfig,
              ~isWildcard,
              ~handler=intent.handler,
              ~contractRegister=intent.contractRegister,
              ~where,
              ~startBlock=?contract.startBlock,
            ),
          )
          ->ignore
        }
      }
    })
  })

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

// Resolve the intent against every chain that defines its event and discard the
// results, so a broken `where` (bad filter, unknown indexed param) throws at the
// user's registration call site instead of being deferred to
// `finishRegistration` — even when only a later chain's resolution is invalid.
// `config` may be a narrowed TestIndexer chain subset; if no chain defines the
// event there's nothing to validate.
let validateIntentWhere = (~config: Config.t, intent: pendingOnEventRegistration) => {
  let isWildcard = intent.eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false)
  let where = intent.eventOptions->Option.flatMap(v => v.where)
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig =>
    chainConfig.contracts->Array.forEach(contract =>
      if contract.name === intent.contractName {
        switch contract.events->Array.find(e => e.name === intent.eventName) {
        | Some(eventConfig) =>
          let _ = buildOnEventRegistrationWith(
            ~config,
            ~chainId=chainConfig.id,
            ~eventConfig,
            ~isWildcard,
            ~handler=intent.handler,
            ~contractRegister=intent.contractRegister,
            ~where,
            ~startBlock=?contract.startBlock,
          )
        | None => ()
        }
      }
    )
  )
}

let addIntent = (registration: activeRegistration, intent: pendingOnEventRegistration) => {
  // Validate before storing so a broken `where` never leaves a poisoned intent
  // in the global store.
  validateIntentWhere(~config=registration.config, intent)
  pendingOnEventRegistrations->Array.push(intent)->ignore
}

let setHandler = (~contractName, ~eventName, handler, ~eventOptions) => {
  withRegistration(registration => {
    let newHandler = handler->(Utils.magic: Internal.genericHandler<'args> => Internal.handler)
    let eventOptions =
      eventOptions->Option.map(v =>
        v->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
      )
    registration->addIntent({
      contractName,
      eventName,
      handler: Some(newHandler),
      contractRegister: None,
      eventOptions,
    })
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
    registration->addIntent({
      contractName,
      eventName,
      handler: None,
      contractRegister: Some(newContractRegister),
      eventOptions,
    })
  })
}

// True when any registration for the event is a wildcard. Used by simulate to
// decide whether a src address needs deriving.
let isWildcard = (~contractName, ~eventName) =>
  pendingOnEventRegistrations->Array.some(p =>
    p.contractName === contractName &&
    p.eventName === eventName &&
    p.eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false)
  )

// Every registration for one event on a chain, so simulate fans a simulated
// event out to each the way real routing does. Falls back to a bare
// registration when the event has no handler/contractRegister, so a simulated
// item still produces an item to run.
let getSimulateOnEventRegistrations = (
  ~config: Config.t,
  ~chainId: int,
  ~eventConfig: Internal.eventConfig,
): array<Internal.onEventRegistration> => {
  let chainConfig = config.chainMap->ChainMap.get(ChainMap.Chain.makeUnsafe(~chainId))
  let matching =
    resolveChainRegistrations(~config, ~chainConfig)->Array.filter(reg =>
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

let finishRegistration = (~config: Config.t): registrationsByChainId => {
  switch getActiveRegistration() {
  | Some(r) => {
      r.finished = true
      let notRegisteredEventsByContract: dict<Utils.Set.t<string>> = Dict.make()
      let registrationsByChainId: registrationsByChainId = Dict.make()
      config.chainMap
      ->ChainMap.values
      ->Array.forEach(chainConfig => {
        let chainId = chainConfig.id
        let key = chainId->Int.toString

        let builtRegs = resolveChainRegistrations(~config, ~chainConfig)
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
            onBlockRegistrations: switch r.registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(
              key,
            ) {
            | Some(pending) => pending.onBlockRegistrations
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
        let pending = registration->getPendingChainRegistrations(~chainId)
        pending.onBlockRegistrations
        ->Array.push(
          (
            {
              index: pending.onBlockRegistrations->Array.length,
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
