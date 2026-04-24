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

// Stashed on `globalThis` so a duplicate envio module instance — e.g. when the
// CLI's `bin.mjs` resolves envio from one path but the user's handlers resolve
// it from `node_modules/envio` — shares one registry. Without this, each copy
// keeps its own dict and `applyRegistrations` reads empty state.
let eventRegistrations: dict<
  eventRegistration,
> = %raw(`globalThis.__envioHandlerRegistrations ??= {}`)

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

type registrations = {onBlockByChainId: dict<array<Internal.onBlockConfig>>}

type activeRegistration = {
  ecosystem: Ecosystem.t,
  multichain: Internal.multichain,
  registrations: registrations,
  mutable finished: bool,
}

let activeRegistration: ref<
  option<activeRegistration>,
> = %raw(`globalThis.__envioActiveRegistration ??= { contents: undefined }`)

// Might happen for tests when the handler file
// is imported by a non-envio process (eg mocha)
// and initialized before we started registration.
// So we track them here to register when the startRegistration is called.
// Theoretically we could keep preRegistration without an explicit start
// but I want it to be this way, so for the actual indexer run
// an error is thrown with the exact stack trace where the handler was registered.
let preRegistered: array<
  activeRegistration => unit,
> = %raw(`globalThis.__envioPreRegistered ??= []`)

let withRegistration = (fn: activeRegistration => unit) => {
  switch activeRegistration.contents {
  | None => preRegistered->Belt.Array.push(fn)
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

let startRegistration = (~ecosystem, ~multichain) => {
  let r = {
    ecosystem,
    multichain,
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

let finishRegistration = () => {
  switch activeRegistration.contents {
  | Some(r) => {
      r.finished = true
      r.registrations
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
    // We need to get timestamp for ordered multichain mode
    switch registration.multichain {
    | Unordered => ()
    | Ordered =>
      JsError.throwWithMessage(
        "Block Handlers are not supported for ordered multichain mode. Please reach out to the Envio team if you need this feature. Or enable unordered multichain mode by removing `multichain: ordered` from the config.yaml file.",
      )
    }

    let onBlockByChainId = registration.registrations.onBlockByChainId
    let key = chainId->Belt.Int.toString
    let index =
      onBlockByChainId
      ->Utils.Dict.dangerouslyGetNonOption(key)
      ->Belt.Option.mapWithDefault(0, configs => configs->Belt.Array.length)
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
  get(~contractName, ~eventName).eventOptions->Belt.Option.flatMap(value => value.where)

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
        eventOptions->Belt.Option.map(v =>
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
        eventOptions->Belt.Option.map(v =>
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
