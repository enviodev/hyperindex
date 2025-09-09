type registrations = {onBlockByChainId: dict<array<Internal.onBlockConfig>>}

type activeRegistration = {
  ecosystem: InternalConfig.ecosystem,
  multichain: InternalConfig.multichain,
  preloadHandlers: bool,
  registrations: registrations,
}

let activeRegistration = ref(None)

let getRegistration = () => {
  switch activeRegistration.contents {
  | None =>
    Js.Exn.raiseError(
      "The indexer finished initializing, so no more handlers can be registered. Make sure the handlers are registered on the top level of the file.",
    )
  | Some(r) => r
  }
}

let startRegistration = (~ecosystem, ~multichain, ~preloadHandlers) => {
  activeRegistration.contents = Some({
    ecosystem,
    multichain,
    preloadHandlers,
    registrations: {
      onBlockByChainId: Js.Dict.empty(),
    },
  })
}

let finishRegistration = () => {
  let r = getRegistration()
  activeRegistration.contents = None
  r.registrations
}

let onBlockOptionsSchema = S.schema((s): Envio.onBlockOptions => {
  name: s.matches(S.string),
  chain: Id(s.matches(S.int)),
})

let onBlock = (options: Envio.onBlockOptions, handler: Internal.onBlockArgs => promise<unit>) => {
  let registration = getRegistration()

  // There's no big reason for this. It's just more work
  switch registration.ecosystem {
  | Evm => ()
  | Fuel =>
    Js.Exn.raiseError(
      "Block Handlers are not supported for non-EVM ecosystems. Please reach out to the Envio team if you need this feature.",
    )
  }
  // We need to get timestamp for ordered multichain mode
  switch registration.multichain {
  | Unordered => ()
  | Ordered =>
    Js.Exn.raiseError(
      "Block Handlers are not supported for ordered multichain mode. Please reach out to the Envio team if you need this feature or enable unordered multichain mode with `unordered_multichain_mode: true` in your config.",
    )
  }
  // So we encourage users to upgrade to preload optimization
  // otherwise block handlers will be extremely slow
  switch registration.preloadHandlers {
  | false => ()
  | true =>
    Js.Exn.raiseError(
      "Block Handlers require the Preload Optimization feature. Enable it by setting the `preload_handlers` option to `true` in your config.",
    )
  }

  options->S.assertOrThrow(onBlockOptionsSchema)
  let chainId = switch options.chain {
  | Id(chainId) => chainId
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
            name: options.name,
            chainId,
            handler,
          }: Internal.onBlockConfig
        ),
      ],
    )
  | Some(_) => Js.Exn.raiseError("Currently only one onBlock handler per chain is supported")
  }
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
  let _ = getRegistration()
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
}

let setContractRegister = (t: t, contractRegister, ~eventOptions, ~logger=Logging.getLogger()) => {
  let _ = getRegistration()
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
}
