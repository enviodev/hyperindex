type args<'eventArgs, 'context> = {
  event: Types.eventLog<'eventArgs>,
  context: 'context,
}

type contractRegisterArgs<'eventArgs> = args<'eventArgs, Types.contractRegistrations>
type contractRegister<'eventArgs> = contractRegisterArgs<'eventArgs> => unit

type loaderArgs<'eventArgs> = args<'eventArgs, Types.loaderContext>
type loader<'eventArgs, 'loaderReturn> = loaderArgs<'eventArgs> => promise<'loaderReturn>

type handlerArgs<'eventArgs, 'loaderReturn> = {
  event: Types.eventLog<'eventArgs>,
  context: Types.handlerContext,
  loaderReturn: 'loaderReturn,
}

type handler<'eventArgs, 'loaderReturn> = handlerArgs<'eventArgs, 'loaderReturn> => promise<unit>

type registeredLoaderHandler<'eventArgs, 'loaderReturn> = {
  loader: loader<'eventArgs, 'loaderReturn>,
  handler: handler<'eventArgs, 'loaderReturn>,
}

type registeredEvent<'eventArgs, 'loaderReturn> = {
  loaderHandler?: registeredLoaderHandler<'eventArgs, 'loaderReturn>,
  contractRegister?: contractRegister<'eventArgs>,
}

type t = {
  loaderHandlers: dict<registeredLoaderHandler<unknown, unknown>>,
  contractRegisters: dict<contractRegister<unknown>>,
}

let make = () => {
  loaderHandlers: Js.Dict.empty(),
  contractRegisters: Js.Dict.empty(),
}

let addLoaderHandler = (
  registeredEvents: t,
  eventMod,
  args: registeredLoaderHandler<'eventArgs, 'loadReturn>,
) => {
  let module(Event: Types.InternalEvent) = eventMod
  let key = Event.key

  if registeredEvents.loaderHandlers->Js.Dict.get(key)->Belt.Option.isSome {
    Js.Exn.raiseError(
      `[envio] The event "${Event.name}" on contract "${Event.contractName}" is already registered.`,
    )
  } else {
    registeredEvents.loaderHandlers->Js.Dict.set(
      key,
      args->(
        Utils.magic: registeredLoaderHandler<'eventArgs, 'loadReturn> => registeredLoaderHandler<
          unknown,
          unknown,
        >
      ),
    )
  }
}

let addContractRegister = (registeredEvents: t, eventMod, args: contractRegister<'eventArgs>) => {
  let module(Event: Types.InternalEvent) = eventMod
  let key = Event.key

  if registeredEvents.contractRegisters->Js.Dict.get(key)->Belt.Option.isSome {
    Js.Exn.raiseError(
      `[envio] The event "${Event.name}" on contract "${Event.contractName}" is alredy registered.`,
    )
  } else {
    registeredEvents.contractRegisters->Js.Dict.set(
      key,
      args->(Utils.magic: contractRegister<'eventArgs> => contractRegister<unknown>),
    )
  }
}

// This set makes sure that the warning doesn't print for every event of a type, but rather only prints the first time.
let hasPrintedWarning = Set.make()

let get = (registeredEvents: t, eventMod) => {
  let module(Event: Types.InternalEvent) = eventMod

  let registeredLoaderHandler =
    registeredEvents.loaderHandlers
    ->Js.Dict.unsafeGet(Event.key)
    ->(
      Utils.magic: registeredLoaderHandler<unknown, unknown> => option<
        registeredLoaderHandler<'eventArgs, 'loadReturn>,
      >
    )

  let contractRegister =
    registeredEvents.contractRegisters
    ->Js.Dict.unsafeGet(Event.key)
    ->(Utils.magic: contractRegister<unknown> => option<contractRegister<'eventArgs>>)

  switch (registeredLoaderHandler, contractRegister) {
  | (None, None) =>
    if !(hasPrintedWarning->Set.has(Event.key)) {
      // Here are docs on the 'terminal hyperlink' formatting that I use to link to the docs: https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda
      Logging.warn(
        `Skipped "${Event.name}" on contract "${Event.contractName}", as there is no handler registered. You need to implement the event "${Event.name}" register method in your handler file or ignore this warning if you don't intend to implement it. Here are our docs on this topic: \n\n https://docs.envio.dev/docs/event-handlers`,
      )
      let _ = hasPrintedWarning->Set.add(Event.key)
    }
    None
  | (loaderHandler, contractRegister) =>
    Some({
      ?loaderHandler,
      ?contractRegister,
    })
  }
}

let global = make()

let defaultAsyncFn = _ => Promise.resolve()

module MakeRegister = (Event: Types.Event) => {
  let eventMod = module(Event)->Types.eventModToInternal

  let handler = handler =>
    global->addLoaderHandler(
      eventMod,
      {
        loader: defaultAsyncFn,
        handler,
      },
    )

  let contractRegister: contractRegister<Event.eventArgs> => unit = contractRegister =>
    global->addContractRegister(eventMod, contractRegister)

  let handlerWithLoader: registeredLoaderHandler<Event.eventArgs, 'loaderReturn> => unit = args =>
    global->addLoaderHandler(eventMod, args)
}
