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

// The finished registration state returned by `finishRegistration`: per-chain
// onEventRegistrations built from the event definitions in `Config.t` plus
// whatever handler/contractRegister/eventOptions got registered for them, and
// the onBlock configs collected during registration.
type registrations = {
  onEventRegistrationsByChainId: dict<array<Internal.onEventRegistration>>,
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
}

type pendingRegistrations = {onBlockByChainId: dict<array<Internal.onBlockConfig>>}

type activeRegistration = {
  ecosystem: Ecosystem.t,
  registrations: pendingRegistrations,
  mutable finished: bool,
}

// Stashed on `globalThis` so a duplicate envio module instance — e.g. when the
// CLI's `bin.mjs` resolves envio from one path but the user's handlers resolve
// it from `node_modules/envio` — shares one registry. Without this, each copy
// keeps its own dict and `applyRegistrations` reads empty state.
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

let startRegistration = (~ecosystem) => {
  let r = {
    ecosystem,
    registrations: {
      onBlockByChainId: Dict.make(),
    },
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

// Enrich a chain's static event definitions with the registered
// handler/contractRegister/where (validating them along the way) to produce
// the onEventRegistrations ChainState indexes off. Runs once per chain when
// registration finishes, so a bad `where`/duplicate event throws during
// startup with a stack trace pointing here instead of surfacing later from
// inside ChainState's construction.
let buildOnEventRegistrations = (~chainConfig: Config.chain, ~config: Config.t): array<
  Internal.onEventRegistration,
> => {
  // We don't need the router itself, but only validation logic,
  // since now event router is created for selection of events
  // and validation doesn't work correctly in routers.
  // Ideally to split it into two different parts.
  let eventRouter = EventRouter.empty()

  let onEventRegistrations: array<Internal.onEventRegistration> = []
  let notRegisteredEvents = []

  chainConfig.contracts->Array.forEach(contract => {
    let contractName = contract.name

    contract.events->Array.forEach(eventConfig => {
      let eventName = eventConfig.name
      let t = get(~contractName, ~eventName)
      let isWildcard = t.eventOptions->Option.flatMap(v => v.wildcard)->Option.getOr(false)
      let handler = t.handler
      let contractRegister = t.contractRegister

      let onEventRegistration = switch config.ecosystem.name {
      | Fuel =>
        (EventConfigBuilder.buildFuelOnEventRegistration(
          ~eventConfig=eventConfig->(Utils.magic: Internal.eventConfig => Internal.fuelEventConfig),
          ~isWildcard,
          ~handler,
          ~contractRegister,
          ~startBlock=?contract.startBlock,
        ) :> Internal.onEventRegistration)
      | Svm =>
        (EventConfigBuilder.buildSvmOnEventRegistration(
          ~eventConfig=eventConfig->(
            Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig
          ),
          ~isWildcard,
          ~handler,
          ~contractRegister,
          ~startBlock=?contract.startBlock,
        ) :> Internal.onEventRegistration)
      | Evm =>
        (EventConfigBuilder.buildEvmOnEventRegistration(
          ~eventConfig=eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig),
          ~isWildcard,
          ~handler,
          ~contractRegister,
          ~eventFilters=t.eventOptions->Option.flatMap(v => v.where),
          ~probeChainId=chainConfig.id,
          ~onEventBlockFilterSchema=config.ecosystem.onEventBlockFilterSchema,
          ~startBlock=?contract.startBlock,
        ) :> Internal.onEventRegistration)
      }

      // Should validate the events
      eventRouter->EventRouter.addOrThrow(
        eventConfig.id,
        (),
        ~contractName,
        ~chain=ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id),
        ~eventName,
        ~isWildcard,
      )

      // Filter out events without a handler/contractRegister so they aren't
      // fetched or dispatched (unless raw events are enabled).
      let shouldBeIncluded = if config.enableRawEvents {
        true
      } else {
        let isRegistered = contractRegister->Option.isSome || handler->Option.isSome
        if !isRegistered {
          notRegisteredEvents->Array.push(onEventRegistration)
        }
        isRegistered
      }

      // Check if event has Static([]) filters (from a dynamic where
      // callback returning `false` / SkipAll for this chain).
      // If so, skip it entirely - it should never be fetched
      let shouldSkip = try {
        let getEventFiltersOrThrow = (
          onEventRegistration->(
            Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration
          )
        ).getEventFiltersOrThrow

        // Check for non-evm chains
        if (
          getEventFiltersOrThrow->(Utils.magic: (ChainMap.Chain.t => Internal.eventFilters) => bool)
        ) {
          switch getEventFiltersOrThrow(ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)) {
          | Static([]) => true
          | _ => false
          }
        } else {
          false
        }
      } catch {
      // Can throw when filter is invalid
      // Don't skip an event in this case. Let it throw in a better place - source code
      | _ => false
      }

      if shouldBeIncluded && !shouldSkip {
        onEventRegistrations->Array.push(onEventRegistration)
      }
    })
  })

  if notRegisteredEvents->Utils.Array.notEmpty {
    let logger = Logging.createChild(~params={"chainId": chainConfig.id})
    logger->Logging.childInfo(
      `The event${if notRegisteredEvents->Array.length > 1 {
          "s"
        } else {
          ""
        }} ${notRegisteredEvents
        ->Array.map(reg => `${reg.eventConfig.contractName}.${reg.eventConfig.name}`)
        ->Array.joinUnsafe(", ")} don't have an event handler and skipped for indexing.`,
    )
  }

  onEventRegistrations
}

let finishRegistration = (~config: Config.t) => {
  switch activeRegistration.contents {
  | Some(r) => {
      r.finished = true
      let onEventRegistrationsByChainId = Dict.make()
      config.chainMap
      ->ChainMap.values
      ->Array.forEach(chainConfig => {
        onEventRegistrationsByChainId->Dict.set(
          chainConfig.id->Int.toString,
          buildOnEventRegistrations(~chainConfig, ~config),
        )
      })
      {
        onEventRegistrationsByChainId,
        onBlockByChainId: r.registrations.onBlockByChainId,
      }
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

let registerOnBlock = (
  ~name,
  ~chainId,
  ~interval,
  ~startBlock,
  ~endBlock,
  ~handler: Internal.onBlockArgs => promise<unit>,
) => {
  withRegistration(registration => {
    let onBlockByChainId = registration.registrations.onBlockByChainId
    let key = chainId->Int.toString
    let index =
      onBlockByChainId
      ->Utils.Dict.dangerouslyGetNonOption(key)
      ->Option.mapOr(0, configs => configs->Array.length)
    onBlockByChainId->Utils.Dict.push(
      key,
      (
        {
          index,
          name,
          startBlock,
          endBlock,
          interval,
          chainId,
          handler,
        }: Internal.onBlockConfig
      ),
    )
  })
}

let getHandler = (~contractName, ~eventName) => get(~contractName, ~eventName).handler

let getContractRegister = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).contractRegister

let getOnEventWhere = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).eventOptions->Option.flatMap(value => value.where)

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

// Compare two raw `where` configs as the user passed them (object/array/bool/function).
// At registration time we haven't parsed the config into `Internal.eventFilters` yet,
// so structural equality on the raw JSON shape is what users actually wrote. For a
// dynamic callback (a function value) structural equality is meaningless, so fall
// back to referential equality on the function reference.
let whereMatch = (a: option<JSON.t>, b: option<JSON.t>) => {
  switch (a, b) {
  | (None, None) => true
  | (Some(a), Some(b)) =>
    if typeof(a) === #function || typeof(b) === #function {
      a === b
    } else {
      a == b
    }
  | _ => false
  }
}

let eventOptionsMatch = (
  existing: option<Internal.eventOptions<JSON.t>>,
  incoming: option<Internal.eventOptions<JSON.t>>,
) => {
  switch (existing, incoming) {
  | (None, None) => true
  | (Some(a), Some(b)) => a.wildcard === b.wildcard && whereMatch(a.where, b.where)
  | _ => false
  }
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
  withRegistration(_registration => {
    let t = get(~contractName, ~eventName)
    let newHandler = handler->(Utils.magic: Internal.genericHandler<'args> => Internal.handler)
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
      let incomingEventOptions =
        eventOptions->Option.map(v =>
          v->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
        )
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
  })
}

let setContractRegister = (
  ~contractName,
  ~eventName,
  contractRegister,
  ~eventOptions,
  ~logger=Logging.getLogger(),
) => {
  withRegistration(_registration => {
    let t = get(~contractName, ~eventName)
    let newContractRegister =
      contractRegister->(
        Utils.magic: Internal.genericContractRegister<
          Internal.genericContractRegisterArgs<'event, 'context>,
        > => Internal.contractRegister
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
      let incomingEventOptions =
        eventOptions->Option.map(v =>
          v->(Utils.magic: Internal.eventOptions<'where> => Internal.eventOptions<JSON.t>)
        )
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
  })
}
