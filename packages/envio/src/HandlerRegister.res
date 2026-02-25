type eventRegistration = {
  handler: option<Internal.handler>,
  contractRegister: option<Internal.contractRegister>,
  eventOptions: option<Internal.eventOptions<Js.Json.t>>,
}

let empty = {
  handler: None,
  contractRegister: None,
  eventOptions: None,
}

let eventRegistrations: Js.Dict.t<eventRegistration> = Js.Dict.empty()

let getKey = (~contractName, ~eventName) => contractName ++ "." ++ eventName

let get = (~contractName, ~eventName) => {
  switch eventRegistrations->Utils.Dict.dangerouslyGetNonOption(getKey(~contractName, ~eventName)) {
  | Some(existing) => existing
  | None => empty
  }
}

let set = (~contractName, ~eventName, registration) => {
  eventRegistrations->Js.Dict.set(getKey(~contractName, ~eventName), registration)
}

type registrations = {
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
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

let getHandler = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).handler

let getContractRegister = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).contractRegister

let getEventFilters = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).eventOptions
  ->Belt.Option.flatMap(value => value.eventFilters)

let isWildcard = (~contractName, ~eventName) =>
  get(~contractName, ~eventName).eventOptions
  ->Belt.Option.flatMap(value => value.wildcard)
  ->Belt.Option.getWithDefault(false)

let hasRegistration = (~contractName, ~eventName) => {
  let r = get(~contractName, ~eventName)
  r.handler->Belt.Option.isSome || r.contractRegister->Belt.Option.isSome
}

type eventNamespace = {contractName: string, eventName: string}

let raiseDuplicateRegistration = (~contractName, ~eventName, ~msg, ~logger) => {
  let fullMsg = msg ++ " for " ++ contractName ++ "." ++ eventName
  Logging.createChildFrom(~logger, ~params={contractName, eventName})->Logging.childError(fullMsg)
  Js.Exn.raiseError(fullMsg)
}

let eventOptionsMatch = (
  existing: option<Internal.eventOptions<Js.Json.t>>,
  incoming: option<Internal.eventOptions<Js.Json.t>>,
) => {
  switch (existing, incoming) {
  | (None, None) => true
  | (Some(a), Some(b)) => a.wildcard === b.wildcard && a.eventFilters == b.eventFilters
  | _ => false
  }
}

let setEventOptions = (~contractName, ~eventName, ~eventOptions, ~logger=Logging.getLogger()) => {
  switch eventOptions {
  | Some(value) =>
    let value =
      value->(Utils.magic: Internal.eventOptions<'eventFilters> => Internal.eventOptions<Js.Json.t>)
    let t = get(~contractName, ~eventName)
    switch t.eventOptions {
    | None => set(~contractName, ~eventName, {...t, eventOptions: Some(value)})
    | Some(existingValue) =>
      if !eventOptionsMatch(Some(existingValue), Some(value)) {
        raiseDuplicateRegistration(
          ~contractName,
          ~eventName,
          ~msg="Cannot register handler with different options. Make sure all handlers for the same event use identical options (wildcard, eventFilters)",
          ~logger,
        )
      }
    }
  | None => ()
  }
}

let setHandler = (~contractName, ~eventName, handler, ~eventOptions, ~logger=Logging.getLogger()) => {
  withRegistration(_registration => {
    let t = get(~contractName, ~eventName)
    let newHandler = handler->(Utils.magic: Internal.genericHandler<'args> => Internal.handler)
    switch t.handler {
    | None =>
      set(~contractName, ~eventName, {
        ...t,
        handler: Some(newHandler),
      })
      setEventOptions(~contractName, ~eventName, ~eventOptions, ~logger)
    | Some(prevHandler) =>
      let incomingEventOptions =
        eventOptions->Belt.Option.map(v =>
          v->(Utils.magic: Internal.eventOptions<'eventFilters> => Internal.eventOptions<Js.Json.t>)
        )
      if eventOptionsMatch(t.eventOptions, incomingEventOptions) {
        let composedHandler: Internal.handler = async args => {
          await prevHandler(args)
          await newHandler(args)
        }
        set(~contractName, ~eventName, {
          ...t,
          handler: Some(composedHandler),
        })
      } else {
        raiseDuplicateRegistration(
          ~contractName,
          ~eventName,
          ~msg="Cannot register a second handler with different options. Make sure all handlers for the same event use identical options (wildcard, eventFilters)",
          ~logger,
        )
      }
    }
  })
}

let setContractRegister = (~contractName, ~eventName, contractRegister, ~eventOptions, ~logger=Logging.getLogger()) => {
  withRegistration(_registration => {
    let t = get(~contractName, ~eventName)
    let newContractRegister = contractRegister->(
      Utils.magic: Internal.genericContractRegister<
        Internal.genericContractRegisterArgs<'event, 'context>,
      > => Internal.contractRegister
    )
    switch t.contractRegister {
    | None =>
      set(~contractName, ~eventName, {
        ...t,
        contractRegister: Some(newContractRegister),
      })
      setEventOptions(~contractName, ~eventName, ~eventOptions, ~logger)
    | Some(prevContractRegister) =>
      let incomingEventOptions =
        eventOptions->Belt.Option.map(v =>
          v->(Utils.magic: Internal.eventOptions<'eventFilters> => Internal.eventOptions<Js.Json.t>)
        )
      if eventOptionsMatch(t.eventOptions, incomingEventOptions) {
        let composedContractRegister: Internal.contractRegister = async args => {
          await prevContractRegister(args)
          await newContractRegister(args)
        }
        set(~contractName, ~eventName, {
          ...t,
          contractRegister: Some(composedContractRegister),
        })
      } else {
        raiseDuplicateRegistration(
          ~contractName,
          ~eventName,
          ~msg="Cannot register a second contractRegister with different options. Make sure all handlers for the same event use identical options (wildcard, eventFilters)",
          ~logger,
        )
      }
    }
  })
}
