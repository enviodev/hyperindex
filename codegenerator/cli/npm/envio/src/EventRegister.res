type registrations = {
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
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

let finishRegistration = () => {
  switch activeRegistration.contents {
  | Some(r) => {
      r.finished = true
      r.registrations
    }
  | None =>
    Js.Exn.raiseError("The indexer has not started registering handlers, so can't finish it.")
  }
}

let getRegistrations = () => {
  switch activeRegistration.contents {
  | Some(r) if r.finished => r.registrations
  | Some(_) =>
    Js.Exn.raiseError("The indexer has not finished registering handlers yet.")
  | None =>
    Js.Exn.raiseError("The indexer has not started registering handlers.")
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

type t = {
  contractName: string,
  eventName: string,
  mutable handler: option<Internal.handler>,
  mutable contractRegister: option<Internal.contractRegister>,
  mutable eventOptions: option<Internal.eventOptions<Js.Json.t>>,
}

let getHandler = (t: t) => t.handler

let getContractRegister = (t: t) => t.contractRegister

let getEventFilters = (t: t) => t.eventOptions->Belt.Option.flatMap(value => value.eventFilters)

let isWildcard = (t: t) =>
  t.eventOptions->Belt.Option.flatMap(value => value.wildcard)->Belt.Option.getWithDefault(false)

let hasRegistration = ({handler, contractRegister}) =>
  handler->Belt.Option.isSome || contractRegister->Belt.Option.isSome

let make = (~contractName, ~eventName) => {
  contractName,
  eventName,
  handler: None,
  contractRegister: None,
  eventOptions: None,
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
