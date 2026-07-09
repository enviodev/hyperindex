type eventRegistration = {
  handler: option<Internal.handler>,
  contractRegister: option<Internal.contractRegister>,
  eventOptions: option<Internal.eventOptions<JSON.t>>,
}

let empty = {
  handler: None,
  contractRegister: None,
  eventOptions: None,
}

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

// Incrementally built during registration: every `indexer.onEvent` /
// `.contractRegister` call resolves its `where` per chain right away and
// stores the resulting registration here, keyed by "Contract.Event", so
// invalid configuration throws at the user's registration call site.
type pendingChainRegistrations = {
  onEventRegistrations: dict<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}

type activeRegistration = {
  config: Config.t,
  registrationsByChainId: dict<pendingChainRegistrations>,
  mutable finished: bool,
}

// Stashed on `globalThis` so a duplicate envio module instance — e.g. when the
// CLI's `bin.mjs` resolves envio from one path but the user's handlers resolve
// it from `node_modules/envio` — shares one registry. Without this, each copy
// keeps its own dict and `finishRegistration` reads empty state.
//
// Version-gated: the record shapes below can evolve between envio versions,
// so the guard uses strict full-version equality. On mismatch we throw with
// a deduplication hint instead of silently mixing shapes across builds.
type registryShape = {
  version: string,
  eventRegistrations: dict<eventRegistration>,
  activeRegistration: ref<option<activeRegistration>>,
  preRegistered: array<activeRegistration => unit>,
}

// Record type with `mutable` so assignment typechecks; ReScript keeps the
// field name verbatim in the generated JS so the globalThis slot is
// `__envioRegistry`.
type globalThis = {mutable __envioRegistry: Nullable.t<registryShape>}
@val external globalThis: globalThis = "globalThis"

%%private(
  let registry: registryShape = {
    let version = Utils.EnvioPackage.value.version
    switch globalThis.__envioRegistry->Nullable.toOption {
    | Some(existing) if existing.version === version => existing
    | Some(existing) =>
      JsError.throwWithMessage(
        `Multiple incompatible envio versions loaded in the same process: ${existing.version} and ${version}. Deduplicate the 'envio' dependency in your project.`,
      )
    | None =>
      let fresh = {
        version,
        eventRegistrations: Dict.make(),
        activeRegistration: ref(None),
        preRegistered: [],
      }
      globalThis.__envioRegistry = Nullable.make(fresh)
      fresh
    }
  }
)

let eventRegistrations = registry.eventRegistrations

let getKey = (~contractName, ~eventName) => contractName ++ "." ++ eventName

let get = (~contractName, ~eventName) => {
  switch eventRegistrations->Utils.Dict.dangerouslyGetNonOption(getKey(~contractName, ~eventName)) {
  | Some(existing) => existing
  | None => empty
  }
}

let set = (~contractName, ~eventName, registration) => {
  eventRegistrations->Dict.set(getKey(~contractName, ~eventName), registration)
}

let activeRegistration = registry.activeRegistration

// Might happen for tests when the handler file
// is imported by a non-envio process (eg mocha)
// and initialized before we started registration.
// So we track them here to register when the startRegistration is called.
// Theoretically we could keep preRegistration without an explicit start
// but I want it to be this way, so for the actual indexer run
// an error is thrown with the exact stack trace where the handler was registered.
let preRegistered = registry.preRegistered

let withRegistration = (fn: activeRegistration => unit) => {
  switch activeRegistration.contents {
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

// Defer a callback until registration is active so it sees the registration's
// config, which may be a narrowed version of the generated one (TestIndexer
// runs with a per-test chain subset).
let withConfig = (fn: Config.t => unit) => withRegistration(r => fn(r.config))

let startRegistration = (~config: Config.t) => {
  let r = {
    config,
    registrationsByChainId: Dict.make(),
    finished: false,
  }
  activeRegistration.contents = Some(r)
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
      onEventRegistrations: Dict.make(),
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

// Enrich one event definition into its (event, chain) registration using
// whatever handler/contractRegister/where the user registered for it. Shared
// by the incremental per-chain sync below, `simulate`, and test helpers so
// they stay in sync instead of re-deriving the per-ecosystem dispatch each
// place.
let buildOnEventRegistration = (
  ~config: Config.t,
  ~chainId: int,
  ~eventConfig: Internal.eventConfig,
  ~startBlock=?,
): Internal.onEventRegistration => {
  let t = get(~contractName=eventConfig.contractName, ~eventName=eventConfig.name)
  buildOnEventRegistrationWith(
    ~config,
    ~chainId,
    ~eventConfig,
    ~isWildcard=t.eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false),
    ~handler=t.handler,
    ~contractRegister=t.contractRegister,
    ~where=t.eventOptions->Option.flatMap(v => v.where),
    ~startBlock?,
  )
}

let getHandler = (~contractName, ~eventName) => get(~contractName, ~eventName).handler

let getContractRegister = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).contractRegister

let isWildcard = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).eventOptions
  ->Option.flatMap(value => value.wildcard)
  ->Option.getOr(false)

let hasRegistration = (~contractName, ~eventName) => {
  let r = get(~contractName, ~eventName)
  r.handler->Option.isSome || r.contractRegister->Option.isSome
}

type eventNamespace = {contractName: string, eventName: string}

let raiseDuplicateRegistration = (~contractName, ~eventName, ~msg, ~logger) => {
  let fullMsg = msg ++ " for " ++ contractName ++ "." ++ eventName
  Logging.createChildFrom(~logger, ~params={contractName, eventName})->Logging.childError(fullMsg)
  JsError.throwWithMessage(fullMsg)
}

// `where` equality is checked per chain on the resolved structure (see
// `syncOnEventRegistrations`), so registration options only need to agree on
// `wildcard` here — two callbacks that resolve to identical filters count as
// identical options even when the function references differ.
let eventOptionsMatch = (
  existing: option<Internal.eventOptions<JSON.t>>,
  incoming: option<Internal.eventOptions<JSON.t>>,
) => {
  switch (existing, incoming) {
  | (None, None) => true
  | (Some(a), Some(b)) => a.wildcard === b.wildcard
  | _ => false
  }
}

let getResolvedWhere = (reg: Internal.onEventRegistration) =>
  (
    reg->(Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration)
  ).resolvedWhere

// Resolve the registration for every configured chain that defines the event
// and store it in the pending per-chain registry. When the chain already
// holds a registration for this event, the resolved `where` structures must
// deep-compare equal (`Values` by hex arrays, `ContractAddresses` by contract
// name, plus `startBlock`) — otherwise it's a conflicting duplicate
// registration. Both live registrations and `preRegistered` callbacks
// replayed by `startRegistration` run through this single code path.
let syncOnEventRegistrations = (
  r: activeRegistration,
  ~contractName,
  ~eventName,
  ~where: option<JSON.t>,
  ~duplicateMsg,
  ~logger,
) => {
  let config = r.config
  let t = get(~contractName, ~eventName)
  let isWildcard = t.eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false)
  let key = getKey(~contractName, ~eventName)

  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    chainConfig.contracts->Array.forEach(contract => {
      if contract.name === contractName {
        switch contract.events->Array.find(e => e.name === eventName) {
        | None => ()
        | Some(eventConfig) =>
          let newRegistration = buildOnEventRegistrationWith(
            ~config,
            ~chainId=chainConfig.id,
            ~eventConfig,
            ~isWildcard,
            ~handler=t.handler,
            ~contractRegister=t.contractRegister,
            ~where,
            ~startBlock=?contract.startBlock,
          )
          let pending = r->getPendingChainRegistrations(~chainId=chainConfig.id)
          switch pending.onEventRegistrations->Utils.Dict.dangerouslyGetNonOption(key) {
          | Some(existing) if config.ecosystem.name === Evm =>
            if !(existing->getResolvedWhere == newRegistration->getResolvedWhere) {
              raiseDuplicateRegistration(~contractName, ~eventName, ~msg=duplicateMsg, ~logger)
            }
          | _ => ()
          }
          pending.onEventRegistrations->Dict.set(key, newRegistration)
        }
      }
    })
  })
}

let setEventOptions = (~contractName, ~eventName, ~eventOptions, ~logger=Logging.getLogger()) => {
  switch eventOptions {
  | Some(value) =>
    let value = value->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
    let t = get(~contractName, ~eventName)
    switch t.eventOptions {
    | None => set(~contractName, ~eventName, {...t, eventOptions: Some(value)})
    | Some(existingValue) =>
      if !eventOptionsMatch(Some(existingValue), Some(value)) {
        raiseDuplicateRegistration(
          ~contractName,
          ~eventName,
          ~msg="Cannot register handler with different options. Make sure all handlers for the same event use identical options (wildcard, where)",
          ~logger,
        )
      }
    }
  | None => ()
  }
}

let setHandler = (
  ~contractName,
  ~eventName,
  handler,
  ~eventOptions,
  ~logger=Logging.getLogger(),
) => {
  withRegistration(registration => {
    let t = get(~contractName, ~eventName)
    let newHandler = handler->(Utils.magic: Internal.genericHandler<'args> => Internal.handler)
    let incomingEventOptions =
      eventOptions->Option.map(v =>
        v->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
      )
    switch t.handler {
    | None =>
      setEventOptions(~contractName, ~eventName, ~eventOptions, ~logger)
      let t = get(~contractName, ~eventName)
      set(
        ~contractName,
        ~eventName,
        {
          ...t,
          handler: Some(newHandler),
        },
      )
    | Some(prevHandler) =>
      if eventOptionsMatch(t.eventOptions, incomingEventOptions) {
        let composedHandler: Internal.handler = async args => {
          await prevHandler(args)
          await newHandler(args)
        }
        set(
          ~contractName,
          ~eventName,
          {
            ...t,
            handler: Some(composedHandler),
          },
        )
      } else {
        raiseDuplicateRegistration(
          ~contractName,
          ~eventName,
          ~msg="Cannot register a second handler with different options. Make sure all handlers for the same event use identical options (wildcard, where)",
          ~logger,
        )
      }
    }
    registration->syncOnEventRegistrations(
      ~contractName,
      ~eventName,
      ~where=incomingEventOptions->Option.flatMap(v => v.where),
      ~duplicateMsg="Cannot register a second handler with different options. Make sure all handlers for the same event use identical options (wildcard, where)",
      ~logger,
    )
  })
}

let setContractRegister = (
  ~contractName,
  ~eventName,
  contractRegister,
  ~eventOptions,
  ~logger=Logging.getLogger(),
) => {
  withRegistration(registration => {
    let t = get(~contractName, ~eventName)
    let newContractRegister =
      contractRegister->(
        Utils.magic: Internal.genericContractRegister<
          Internal.genericContractRegisterArgs<'event, 'context>,
        > => Internal.contractRegister
      )
    let incomingEventOptions =
      eventOptions->Option.map(v =>
        v->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
      )
    switch t.contractRegister {
    | None =>
      setEventOptions(~contractName, ~eventName, ~eventOptions, ~logger)
      let t = get(~contractName, ~eventName)
      set(
        ~contractName,
        ~eventName,
        {
          ...t,
          contractRegister: Some(newContractRegister),
        },
      )
    | Some(prevContractRegister) =>
      if eventOptionsMatch(t.eventOptions, incomingEventOptions) {
        let composedContractRegister: Internal.contractRegister = async args => {
          await prevContractRegister(args)
          await newContractRegister(args)
        }
        set(
          ~contractName,
          ~eventName,
          {
            ...t,
            contractRegister: Some(composedContractRegister),
          },
        )
      } else {
        raiseDuplicateRegistration(
          ~contractName,
          ~eventName,
          ~msg="Cannot register a second contractRegister with different options. Make sure all handlers for the same event use identical options (wildcard, where)",
          ~logger,
        )
      }
    }
    registration->syncOnEventRegistrations(
      ~contractName,
      ~eventName,
      ~where=incomingEventOptions->Option.flatMap(v => v.where),
      ~duplicateMsg="Cannot register a second contractRegister with different options. Make sure all handlers for the same event use identical options (wildcard, where)",
      ~logger,
    )
  })
}

let registerOnBlock = (
  ~name,
  ~chainId,
  ~interval,
  ~startBlock,
  ~endBlock,
  ~handler: Internal.onBlockArgs => promise<unit>,
) => {
  withRegistration(registration => {
    let chainConfig =
      registration.config.chainMap
      ->ChainMap.values
      ->Array.find(chainConfig => chainConfig.id === chainId)
    switch chainConfig {
    | None =>
      JsError.throwWithMessage(
        `The onBlock handler "${name}" is registered for chain ${chainId->Int.toString} which is not in the config.`,
      )
    | Some(chainConfig) =>
      if startBlock->Option.getOr(chainConfig.startBlock) < chainConfig.startBlock {
        JsError.throwWithMessage(
          `The start block for onBlock handler "${name}" is less than the chain start block (${chainConfig.startBlock->Int.toString}). This is not supported yet.`,
        )
      }
      switch chainConfig.endBlock {
      | Some(chainEndBlock) =>
        if endBlock->Option.getOr(chainEndBlock) > chainEndBlock {
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
            startBlock,
            endBlock,
            interval,
            chainId,
            handler,
          }: Internal.onBlockRegistration
        ),
      )
      ->ignore
    }
  })
}

let finishRegistration = (~config: Config.t): registrationsByChainId => {
  switch activeRegistration.contents {
  | Some(r) => {
      r.finished = true
      let notRegisteredEventsByContract: dict<Utils.Set.t<string>> = Dict.make()
      let registrationsByChainId: registrationsByChainId = Dict.make()
      config.chainMap
      ->ChainMap.values
      ->Array.forEach(chainConfig => {
        let key = chainConfig.id->Int.toString
        let pending = r.registrationsByChainId->Utils.Dict.dangerouslyGetNonOption(key)

        // We don't need the router itself, but only validation logic,
        // since now event router is created for selection of events
        // and validation doesn't work correctly in routers.
        // Ideally to split it into two different parts.
        let eventRouter = EventRouter.empty()

        let onEventRegistrations: array<Internal.onEventRegistration> = []

        chainConfig.contracts->Array.forEach(contract => {
          let contractName = contract.name

          contract.events->Array.forEach(
            eventConfig => {
              let eventName = eventConfig.name
              let registration =
                pending->Option.flatMap(
                  pending =>
                    pending.onEventRegistrations->Utils.Dict.dangerouslyGetNonOption(
                      getKey(~contractName, ~eventName),
                    ),
                )

              // Should validate the events
              eventRouter->EventRouter.addOrThrow(
                eventConfig.id,
                (),
                ~contractName,
                ~chain=ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id),
                ~eventName,
                ~isWildcard=switch registration {
                | Some(registration) => registration.isWildcard
                | None => isWildcard(~contractName, ~eventName)
                },
              )

              let registration = switch registration {
              | Some(_) as registration => registration
              | None =>
                // No entry in the incremental store, but the persistent dict
                // may still hold a handler: handler modules are import-cached,
                // so a repeated registration cycle in the same process (tests
                // restarting the indexer) never re-runs the `indexer.onEvent`
                // calls. Rebuild from the dict in that case. Events without a
                // handler/contractRegister aren't fetched or dispatched
                // (unless raw events are enabled).
                if hasRegistration(~contractName, ~eventName) || config.enableRawEvents {
                  Some(
                    buildOnEventRegistration(
                      ~config,
                      ~chainId=chainConfig.id,
                      ~eventConfig,
                      ~startBlock=?contract.startBlock,
                    ),
                  )
                } else {
                  let eventNames = switch notRegisteredEventsByContract->Utils.Dict.dangerouslyGetNonOption(
                    contractName,
                  ) {
                  | Some(set) => set
                  | None => {
                      let set = Utils.Set.make()
                      notRegisteredEventsByContract->Dict.set(contractName, set)
                      set
                    }
                  }
                  eventNames->Utils.Set.add(eventName)->ignore
                  None
                }
              }

              switch registration {
              | Some(registration) =>
                // A `where` that resolved to no topic selections (`false` for
                // this chain) drops the chain's registration entirely — the
                // event should never be fetched here.
                let isDroppedByWhere =
                  config.ecosystem.name === Evm &&
                    (registration->getResolvedWhere).topicSelections->Utils.Array.isEmpty
                if !isDroppedByWhere {
                  onEventRegistrations->Array.push(registration)
                }
              | None => ()
              }
            },
          )
        })

        registrationsByChainId->Dict.set(
          key,
          {
            onEventRegistrations,
            onBlockRegistrations: switch pending {
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
  switch activeRegistration.contents {
  | Some(r) => !r.finished
  | None => false
  }
}

// Early guard called from `indexer.onEvent` / `.contractRegister` / `.onBlock` /
// `.onSlot` so the user sees a method-specific error at the call site, instead
// of hitting the generic `withRegistration` throw deep inside `setHandler` etc.
let throwIfFinishedRegistration = (~methodName) => {
  switch activeRegistration.contents {
  | Some({finished: true}) =>
    JsError.throwWithMessage(
      `Cannot call \`indexer.${methodName}\` after the indexer has started. Make sure all handlers are registered at the top level of your handler module.`,
    )
  | _ => ()
  }
}
