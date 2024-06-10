type fnArgs<'eventArgs, 'context> = {
  event: Types.eventLog<'eventArgs>,
  context: 'context,
}

type contractRegisterFnArgs<'eventArgs> = fnArgs<'eventArgs, Types.contractRegistrations>
type contractRegisterFn<'eventArgs> = contractRegisterFnArgs<'eventArgs> => unit

type preLoaderFnArgs<'eventArgs> = fnArgs<'eventArgs, Types.loaderContext>
type preLoaderFn<'eventArgs, 'preLoaderReturn> = preLoaderFnArgs<'eventArgs> => promise<
  'preLoaderReturn,
>

type handlerFnArgs<'eventArgs, 'preLoaderReturn> = {
  event: Types.eventLog<'eventArgs>,
  context: Types.handlerContext,
  preLoaderReturn: 'preLoaderReturn,
}

type handlerFn<'eventArgs, 'preLoaderReturn> = handlerFnArgs<
  'eventArgs,
  'preLoaderReturn,
> => promise<unit>

type registerArgsWithPreLoader<'eventArgs, 'preLoaderReturn> = {
  handler: handlerFn<'eventArgs, 'preLoaderReturn>,
  preLoader: preLoaderFn<'eventArgs, 'preLoaderReturn>,
  contractRegister?: contractRegisterFn<'eventArgs>,
}

type t = Js.Dict.t<registerArgsWithPreLoader<unknown, unknown>>

let add = (registeredEvents, eventName: Types.eventName, args) => {
  let key = (eventName :> string)
  if registeredEvents->Js.Dict.get(key)->Belt.Option.isSome {
    Js.Exn.raiseError(`[envio] The event ${key} is alredy registered.`)
  } else {
    registeredEvents->Js.Dict.set(
      key,
      args->(
        Obj.magic: registerArgsWithPreLoader<
          'eventArgs,
          'preLoadReturn,
        > => registerArgsWithPreLoader<unknown, unknown>
      ),
    )
  }
}

// This set makes sure that the warning doesn't print for every event of a type, but rather only prints the first time.
let hasPrintedWarning = Set.make()

let get = (registeredEvents, eventName: Types.eventName) => {
  let registeredEvent =
    registeredEvents
    ->Js.Dict.unsafeGet((eventName :> string))
    ->(
      Obj.magic: registerArgsWithPreLoader<unknown, unknown> => option<
        registerArgsWithPreLoader<'eventArgs, 'preLoadReturn>,
      >
    )
  if registeredEvent->Belt.Option.isNone {
    if !(hasPrintedWarning->Set.has((eventName :> string))) {
      // Here are docs on the 'terminal hyperlink' formatting that I use to link to the docs: https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda
      Logging.warn(
        `Skipped ${(eventName :> string)}, as there is no handler registered. You need to implement a ${(eventName :> string)} register method in your handler file or ignore this warning if you don't intend to implement it. Here are our docs on this topic: \n\n https://docs.envio.dev/docs/event-handlers`,
      )
      let _ = hasPrintedWarning->Set.add((eventName :> string))
    }
  }
  registeredEvent
}

let global = Js.Dict.empty()

module MakeRegister = (Event: Types.Event) => {
  let register = args => global->add(Event.eventName, args)
  let handler = handler =>
    global->add(
      Event.eventName,
      {
        preLoader: _ => Promise.resolve(),
        handler,
      },
    )
}
