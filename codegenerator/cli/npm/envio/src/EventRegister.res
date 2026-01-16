type eventHandlerRegistration = {
  eventConfigId: string,
  handler: option<Internal.handler>,
  contractRegister: option<Internal.contractRegister>,
  isWildcard: bool,
  filterByAddresses: bool,
  dependsOnAddresses: bool,
}

type registrations = {
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
  eventHandlerRegistrations: dict<eventHandlerRegistration>,
  mutable hasEvents: bool,
}

type activeRegistration = {
  ecosystem: Ecosystem.t,
  multichain: Config.multichain,
  registrations: registrations,
  mutable finished: bool,
}

let activeRegistration = ref(None)

// Might happen for tests when the handler file
// is imported by a non-envio process (eg mocha)
// and initialized before we started registration.
// So we track them here to register when the startRegistration is called.
// Theoretically we could keep preRegistration without an explicit start
// but I want it to be this way, so for the actual indexer run
// an error is thrown with the exact stack trace where the handler was registered.
let preRegistered = []

type t = {
  eventConfigId: string,
  contractName: string,
  eventName: string,
  mutable handler: option<Internal.handler>,
  mutable contractRegister: option<Internal.contractRegister>,
  mutable eventOptions: option<Internal.eventOptions<Js.Json.t>>,
}

// Track all EventRegister.t instances created during registration
let allEventRegisters: ref<array<t>> = ref([])

let isWildcard = (t: t) =>
  t.eventOptions->Belt.Option.flatMap(value => value.wildcard)->Belt.Option.getWithDefault(false)

let withRegistration = (fn: activeRegistration => unit) => {
  switch activeRegistration.contents {
  | None => preRegistered->Belt.Array.push(fn)
  | Some(r) =>
    if r.finished {
      Js.Exn.raiseError(
        "The indexer finished initializing, so no more handlers can be registered. Make sure the handlers are registered on the top level of the file.",
      )
    } else {
      fn(r)
    }
  }
}

let startRegistration = (~ecosystem, ~multichain) => {
  let r = {
    ecosystem,
    multichain,
    registrations: {
      onBlockByChainId: Js.Dict.empty(),
      eventHandlerRegistrations: Js.Dict.empty(),
      hasEvents: false,
    },
    finished: false,
  }
  activeRegistration.contents = Some(r)
  while preRegistered->Js.Array2.length > 0 {
    // Loop + cleanup in one go
    switch preRegistered->Js.Array2.pop {
    | Some(fn) => fn(r)
    | None => ()
    }
  }
}

// Compute filterByAddresses by checking if eventFilters function accesses addresses
let computeFilterByAddresses = (eventFilters: option<Js.Json.t>) => {
  switch eventFilters {
  | None => false
  | Some(eventFilters) =>
    if Js.typeof(eventFilters) === "function" {
      let filterByAddresses = ref(false)
      let fn = eventFilters->(Utils.magic: Js.Json.t => Internal.eventFiltersArgs => Js.Json.t)
      try {
        let args =
          ({chainId: 0, addresses: []}: Internal.eventFiltersArgs)->Utils.Object.defineProperty(
            "addresses",
            {
              get: () => {
                filterByAddresses := true
                []
              },
            },
          )
        let _ = fn(args)
      } catch {
      | _ => ()
      }
      filterByAddresses.contents
    } else {
      false
    }
  }
}

let finishRegistration = () => {
  switch activeRegistration.contents {
  | Some(r) => {
      // Finalize all event registrations
      allEventRegisters.contents->Belt.Array.forEach(t => {
        let isWildcard = t->isWildcard
        let filterByAddresses = t.eventOptions
          ->Belt.Option.flatMap(o => o.eventFilters)
          ->computeFilterByAddresses
        let dependsOnAddresses = !isWildcard || filterByAddresses

        r.registrations.eventHandlerRegistrations->Js.Dict.set(
          t.eventConfigId,
          {
            eventConfigId: t.eventConfigId,
            handler: t.handler,
            contractRegister: t.contractRegister,
            isWildcard,
            filterByAddresses,
            dependsOnAddresses,
          },
        )
      })

      // Reset the tracked instances
      allEventRegisters := []

      r.finished = true
      r.registrations
    }
  | None =>
    Js.Exn.raiseError("The indexer has not started registering handlers, so can't finish it.")
  }
}

// Get an event registration by eventConfigId
let getEventRegistration = (registrations: registrations, ~eventConfigId: string) => {
  registrations.eventHandlerRegistrations->Js.Dict.get(eventConfigId)
}

// Check if an event has a contractRegister
let hasContractRegister = (registrations: registrations, ~eventConfigId: string) => {
  switch registrations->getEventRegistration(~eventConfigId) {
  | Some({contractRegister: Some(_)}) => true
  | Some({contractRegister: None}) | None => false
  }
}

// Check if an event has a handler
let hasHandler = (registrations: registrations, ~eventConfigId: string) => {
  switch registrations->getEventRegistration(~eventConfigId) {
  | Some({handler: Some(_)}) => true
  | Some({handler: None}) | None => false
  }
}

// Get isWildcard for an event (defaults to false if not found)
let getIsWildcard = (registrations: registrations, ~eventConfigId: string) => {
  switch registrations->getEventRegistration(~eventConfigId) {
  | Some({isWildcard}) => isWildcard
  | None => false
  }
}

// Get filterByAddresses for an event (defaults to false if not found)
let getFilterByAddresses = (registrations: registrations, ~eventConfigId: string) => {
  switch registrations->getEventRegistration(~eventConfigId) {
  | Some({filterByAddresses}) => filterByAddresses
  | None => false
  }
}

// Get dependsOnAddresses for an event (defaults to false if not found)
let getDependsOnAddresses = (registrations: registrations, ~eventConfigId: string) => {
  switch registrations->getEventRegistration(~eventConfigId) {
  | Some({dependsOnAddresses}) => dependsOnAddresses
  | None => false
  }
}

let isPendingRegistration = () => {
  switch activeRegistration.contents {
  | Some(r) => !r.finished
  | None => false
  }
}

let onBlockOptionsSchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "chain": s.matches(S.int),
    "interval": s.matches(S.option(S.int->S.intMin(1))->S.Option.getOr(1)),
    "startBlock": s.matches(S.option(S.int)),
    "endBlock": s.matches(S.option(S.int)),
  }
)

let onBlock = (rawOptions: unknown, handler: Internal.onBlockArgs => promise<unit>) => {
  withRegistration(registration => {
    // We need to get timestamp for ordered multichain mode
    switch registration.multichain {
    | Unordered => ()
    | Ordered =>
      Js.Exn.raiseError(
        "Block Handlers are not supported for ordered multichain mode. Please reach out to the Envio team if you need this feature. Or enable unordered multichain mode by removing `multichain: ordered` from the config.yaml file.",
      )
    }

    let options = rawOptions->S.parseOrThrow(onBlockOptionsSchema)
    let chainId = switch options["chain"] {
    | chainId => chainId
    // Dmitry: I want to add names for chains in the future
    // and to be able to use them as a lookup.
    // To do so, we'll need to pass a config during reigstration
    // instead of isInitialized check.
    }

    let onBlockByChainId = registration.registrations.onBlockByChainId

    switch onBlockByChainId->Utils.Dict.dangerouslyGetNonOption(chainId->Belt.Int.toString) {
    | None =>
      onBlockByChainId->Utils.Dict.setByInt(
        chainId,
        [
          (
            {
              index: 0,
              name: options["name"],
              startBlock: options["startBlock"],
              endBlock: options["endBlock"],
              interval: options["interval"],
              chainId,
              handler,
            }: Internal.onBlockConfig
          ),
        ],
      )
    | Some(onBlockConfigs) =>
      onBlockConfigs->Belt.Array.push(
        (
          {
            index: onBlockConfigs->Belt.Array.length,
            name: options["name"],
            startBlock: options["startBlock"],
            endBlock: options["endBlock"],
            interval: options["interval"],
            chainId,
            handler,
          }: Internal.onBlockConfig
        ),
      )
    }
  })
}

let getHandler = (t: t) => t.handler

let getContractRegister = (t: t) => t.contractRegister

let getEventFilters = (t: t) => t.eventOptions->Belt.Option.flatMap(value => value.eventFilters)

let hasRegistration = ({handler, contractRegister}) =>
  handler->Belt.Option.isSome || contractRegister->Belt.Option.isSome

let make = (~contractName, ~eventName, ~eventConfigId) => {
  let t = {
    eventConfigId,
    contractName,
    eventName,
    handler: None,
    contractRegister: None,
    eventOptions: None,
  }
  // Track this instance so we can finalize registrations later
  allEventRegisters.contents->Belt.Array.push(t)
  t
}

type eventNamespace = {contractName: string, eventName: string}
exception DuplicateEventRegistration(eventNamespace)

let setEventOptions = (t: t, ~eventOptions, ~logger=Logging.getLogger()) => {
  switch eventOptions {
  | Some(value) =>
    let value =
      value->(Utils.magic: Internal.eventOptions<'eventFilters> => Internal.eventOptions<Js.Json.t>)
    switch t.eventOptions {
    | None => t.eventOptions = Some(value)
    | Some(existingValue) =>
      if (
        existingValue.wildcard !== value.wildcard ||
          // TODO: Can improve the check by using deepEqual
          existingValue.eventFilters !== value.eventFilters
      ) {
        let eventNamespace = {contractName: t.contractName, eventName: t.eventName}
        DuplicateEventRegistration(eventNamespace)->ErrorHandling.mkLogAndRaise(
          ~logger=Logging.createChildFrom(~logger, ~params=eventNamespace),
          ~msg="Duplicate eventOptions in handlers not allowed",
        )
      }
    }
  | None => ()
  }
}

let setHandler = (t: t, handler, ~eventOptions, ~logger=Logging.getLogger()) => {
  withRegistration(registration => {
    registration.registrations.hasEvents = true
    switch t.handler {
    | None =>
      t.handler =
        handler
        ->(Utils.magic: Internal.genericHandler<'args> => Internal.handler)
        ->Some
    | Some(_) =>
      let eventNamespace = {contractName: t.contractName, eventName: t.eventName}
      DuplicateEventRegistration(eventNamespace)->ErrorHandling.mkLogAndRaise(
        ~logger=Logging.createChildFrom(~logger, ~params=eventNamespace),
        ~msg="Duplicate registration of event handlers not allowed",
      )
    }

    t->setEventOptions(~eventOptions, ~logger)
  })
}

let setContractRegister = (t: t, contractRegister, ~eventOptions, ~logger=Logging.getLogger()) => {
  withRegistration(registration => {
    registration.registrations.hasEvents = true
    switch t.contractRegister {
    | None =>
      t.contractRegister = Some(
        contractRegister->(
          Utils.magic: Internal.genericContractRegister<
            Internal.genericContractRegisterArgs<'event, 'context>,
          > => Internal.contractRegister
        ),
      )
    | Some(_) =>
      let eventNamespace = {contractName: t.contractName, eventName: t.eventName}
      DuplicateEventRegistration(eventNamespace)->ErrorHandling.mkLogAndRaise(
        ~logger=Logging.createChildFrom(~logger, ~params=eventNamespace),
        ~msg="Duplicate contractRegister handlers not allowed",
      )
    }
    t->setEventOptions(~eventOptions, ~logger)
  })
}
