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
  loaderHandlers: Js.Dict.t<registeredLoaderHandler<unknown, unknown>>,
  contractRegisters: Js.Dict.t<contractRegister<unknown>>,
}

let make = () => {
  loaderHandlers: Js.Dict.empty(),
  contractRegisters: Js.Dict.empty(),
}

let addLoaderHandler = (
  registeredEvents: t,
  eventName: Types.eventName,
  args: registeredLoaderHandler<'eventArgs, 'loadReturn>,
) => {
  let key = (eventName :> string)

  if registeredEvents.loaderHandlers->Js.Dict.get(key)->Belt.Option.isSome {
    Js.Exn.raiseError(`[envio] The event ${key} is alredy registered.`)
  } else {
    registeredEvents.loaderHandlers->Js.Dict.set(
      key,
      args->(
        Obj.magic: registeredLoaderHandler<'eventArgs, 'loadReturn> => registeredLoaderHandler<
          unknown,
          unknown,
        >
      ),
    )
  }
}

let addContractRegister = (
  registeredEvents: t,
  eventName: Types.eventName,
  args: contractRegister<'eventArgs>,
) => {
  let key = (eventName :> string)

  if registeredEvents.contractRegisters->Js.Dict.get(key)->Belt.Option.isSome {
    Js.Exn.raiseError(`[envio] The event ${key} is alredy registered.`)
  } else {
    registeredEvents.contractRegisters->Js.Dict.set(
      key,
      args->(Obj.magic: contractRegister<'eventArgs> => contractRegister<unknown>),
    )
  }
}

// This set makes sure that the warning doesn't print for every event of a type, but rather only prints the first time.
let hasPrintedWarning = Set.make()

let get = (registeredEvents: t, eventName: Types.eventName) => {
  let registeredLoaderHandler =
    registeredEvents.loaderHandlers
    ->Js.Dict.unsafeGet((eventName :> string))
    ->(
      Obj.magic: registeredLoaderHandler<unknown, unknown> => option<
        registeredLoaderHandler<'eventArgs, 'loadReturn>,
      >
    )

  let contractRegister =
    registeredEvents.contractRegisters
    ->Js.Dict.unsafeGet((eventName :> string))
    ->(Obj.magic: contractRegister<unknown> => option<contractRegister<'eventArgs>>)

  switch (registeredLoaderHandler, contractRegister) {
  | (None, None) =>
    if !(hasPrintedWarning->Set.has((eventName :> string))) {
      // Here are docs on the 'terminal hyperlink' formatting that I use to link to the docs: https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda
      Logging.warn(
        `Skipped ${(eventName :> string)}, as there is no handler registered. You need to implement a ${(eventName :> string)} register method in your handler file or ignore this warning if you don't intend to implement it. Here are our docs on this topic: \n\n https://docs.envio.dev/docs/event-handlers`,
      )
      let _ = hasPrintedWarning->Set.add((eventName :> string))
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
  let handler = handler =>
    global->addLoaderHandler(
      Event.eventName,
      {
        loader: defaultAsyncFn,
        handler,
      },
    )

  let contractRegister: contractRegister<Event.eventArgs> => unit = contractRegister =>
    global->addContractRegister(Event.eventName, contractRegister)

  let handlerWithLoader: registeredLoaderHandler<Event.eventArgs, 'loaderReturn> => unit = args =>
    global->addLoaderHandler(Event.eventName, args)
}
