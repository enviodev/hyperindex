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
// onEvent registrations are resolved eagerly into the process-global store
// below, so nothing for them lives here.
type pendingChainRegistrations = {
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

type activeRegistration = {
  config: Config.t,
  registrationsByChainId: dict<pendingChainRegistrations>,
  mutable finished: bool,
}

// Resolved onEvent registrations keyed by chain id, appended (and merged)
// eagerly as each `indexer.onEvent` / `.contractRegister` runs. Lives in the
// process-global `EnvioGlobal` record so it survives an import-cached
// re-registration cycle (handler modules register once per isolate, and there
// is one config per isolate, so a surviving store is only ever reused for the
// same config). `index` is -1 here; `finishRegistration` assigns the final
// chain-scoped index from array position.
let onEventRegistrationsByChainId =
  EnvioGlobal.value.onEventRegistrationsByChainId->(
    Utils.magic: dict<unknown> => dict<array<Internal.onEventRegistration>>
  )

let getKey = (~contractName, ~eventName) => contractName ++ "." ++ eventName

let getChainOnEventRegistrations = (~chainId: int): array<Internal.onEventRegistration> =>
  switch onEventRegistrationsByChainId->Utils.Dict.dangerouslyGetNonOption(chainId->Int.toString) {
  | Some(regs) => regs
  | None => []
  }

let setChainOnEventRegistrations = (~chainId: int, regs) =>
  onEventRegistrationsByChainId->Dict.set(chainId->Int.toString, regs)

// Test-only: clear the process-global store so a fresh registration cycle
// starts empty (production starts each isolate empty and registers once).
let resetOnEventRegistrations = () =>
  onEventRegistrationsByChainId
  ->Dict.keysToArray
  ->Array.forEach(key => onEventRegistrationsByChainId->Dict.set(key, []))

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
  while preRegistered->Array.length > 0 {
    // Loop + cleanup in one go
    switch preRegistered->Array.pop {
    | Some(fn) => fn(r)
    | None => ()
    }
  }
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

// Resolve one `indexer.onEvent` / `.contractRegister` call into a registration
// per configured chain that defines the event, and append it to that chain's
// store. A handler and a contractRegister for the same event and filter merge
// into a single registration; two handlers (or two contractRegisters) never
// merge and each become their own registration. A merge always lands on the
// handler registration's slot so dispatch order follows handler registration
// order.
let addOnEventRegistration = (
  registration: activeRegistration,
  ~contractName,
  ~eventName,
  ~handler: option<Internal.handler>,
  ~contractRegister: option<Internal.contractRegister>,
  ~eventOptions: option<Internal.eventOptions<JSON.t>>,
) => {
  let config = registration.config
  let isWildcard = eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false)
  let where = eventOptions->Option.flatMap(v => v.where)

  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    chainConfig.contracts->Array.forEach(contract => {
      if contract.name === contractName {
        switch contract.events->Array.find(e => e.name === eventName) {
        | None => ()
        | Some(eventConfig) =>
          let chainId = chainConfig.id
          let incoming = buildOnEventRegistrationWith(
            ~config,
            ~chainId,
            ~eventConfig,
            ~isWildcard,
            ~handler,
            ~contractRegister,
            ~where,
            ~startBlock=?contract.startBlock,
          )
          let regs = getChainOnEventRegistrations(~chainId)

          // A handler scans for a contractRegister-only sibling to absorb, a
          // contractRegister scans for a handler-only sibling to attach to.
          let mergeTargetIndex = regs->Array.findIndex(
            existing =>
              sameEventAndFilter(existing, incoming, ~config) &&
              switch (handler, contractRegister) {
              | (Some(_), None) =>
                existing.handler->Option.isNone && existing.contractRegister->Option.isSome
              | (None, Some(_)) =>
                existing.handler->Option.isSome && existing.contractRegister->Option.isNone
              | _ => false
              },
          )

          switch (handler, contractRegister) {
          // Handler absorbs the contractRegister-only registration: drop it and
          // append the merged registration so it takes the handler's slot.
          | (Some(_), None) if mergeTargetIndex >= 0 =>
            let target = regs->Array.getUnsafe(mergeTargetIndex)
            let merged = {...incoming, contractRegister: target.contractRegister}
            let next = regs->Array.filterWithIndex((_, i) => i !== mergeTargetIndex)
            next->Array.push(merged)->ignore
            setChainOnEventRegistrations(~chainId, next)
          // ContractRegister merges into the handler registration, keeping its slot.
          | (None, Some(_)) if mergeTargetIndex >= 0 =>
            let target = regs->Array.getUnsafe(mergeTargetIndex)
            let merged = {...target, contractRegister}
            let next = regs->Array.mapWithIndex((r, i) => i === mergeTargetIndex ? merged : r)
            setChainOnEventRegistrations(~chainId, next)
          | _ => setChainOnEventRegistrations(~chainId, regs->Array.concat([incoming]))
          }
        }
      }
    })
  })
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

// True when any registration for the event is a wildcard. Used by simulate to
// decide whether a src address needs deriving.
let isWildcard = (~contractName, ~eventName) =>
  onEventRegistrationsByChainId
  ->Dict.valuesToArray
  ->Array.some(regs =>
    regs->Array.some(reg =>
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
  ~config: Config.t,
  ~chainId: int,
  ~eventConfig: Internal.eventConfig,
): array<Internal.onEventRegistration> => {
  let matching =
    getChainOnEventRegistrations(~chainId)->Array.filter(reg =>
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

        let builtRegs = getChainOnEventRegistrations(~chainId)
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
        // added to fetch them. Otherwise they're reported once below.
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

        // A `where` that resolved to no topic selections (`false` for this
        // chain) drops the chain's registration entirely — the event should
        // never be fetched here. Each survivor is assigned its chain-scoped
        // index by position.
        let onEventRegistrations: array<Internal.onEventRegistration> = []
        builtRegs
        ->Array.concat(rawEventRegs)
        ->Array.forEach(reg => {
          let isDroppedByWhere =
            config.ecosystem.name === Evm &&
              (reg->getResolvedWhere).topicSelections->Utils.Array.isEmpty
          if !isDroppedByWhere {
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
