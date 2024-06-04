type functionRegister = Loader | Handler

let mapFunctionRegisterName = (functionRegister: functionRegister) => {
  switch functionRegister {
  | Loader => "Loader"
  | Handler => "Handler"
  }
}

// This set makes sure that the warning doesn't print for every event of a type, but rather only prints the first time.
let hasPrintedWarning = Set.make()

@genType
type handlerArgs<'event, 'context> = {
  event: Types.eventLog<'event>,
  context: 'context,
}

@genType
type handlerFunction<'eventArgs, 'context, 'returned> = handlerArgs<
  'eventArgs,
  'context,
> => 'returned

@genType.opaque
type contextGetter = Context.t

@genType
type handlerWithContextGetter<'eventArgs, 'context, 'returned> = {
  handler: handlerFunction<'eventArgs, 'context, 'returned>,
  contextGetter: contextGetter => 'context,
}

@genType
type handlerWithContextGetterSyncAsync<'eventArgs> = SyncAsync.t<
  handlerWithContextGetter<'eventArgs, Types.handlerContext, unit>,
  handlerWithContextGetter<'eventArgs, Types.handlerContextAsync, promise<unit>>,
>

@genType
type loader<'eventArgs> = handlerArgs<'eventArgs, Types.loaderContext> => unit

let getDefaultLoaderHandler: (
  ~functionRegister: functionRegister,
  ~eventName: Types.eventName,
  handlerArgs<'eventArgs, 'loaderContext>,
) => unit = (~functionRegister, ~eventName, _loaderArgs) => {
  let functionName = mapFunctionRegisterName(functionRegister)

  // Here we use this key to prevent flooding the users terminal with
  let repeatKey = `${(eventName :> string)}-${functionName}`
  if !(hasPrintedWarning->Set.has(repeatKey)) {
    // Here are docs on the 'terminal hyperlink' formatting that I use to link to the docs: https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda
    Logging.warn(
      `Skipped ${(eventName :> string)} in the ${functionName}, as there is no ${functionName} registered. You need to implement a ${(eventName :> string)}${functionName} method in your handler file or ignore this warning if you don't intend to implement it. Here are our docs on this topic: \n\n https://docs.envio.dev/docs/event-handlers`,
    )
    let _ = hasPrintedWarning->Set.add(repeatKey)
  }
}

let getDefaultLoaderHandlerWithContextGetter = (~functionRegister, ~eventName) => SyncAsync.Sync({
  handler: getDefaultLoaderHandler(~functionRegister, ~eventName),
  contextGetter: ctx => ctx->Context.getHandlerContextSync,
})

@genType
type t<'eventArgs> = {
  eventName: Types.eventName,
  mutable loader: option<loader<'eventArgs>>,
  mutable handler: option<handlerWithContextGetterSyncAsync<'eventArgs>>,
}

let make = (~eventName) => {
  eventName,
  loader: None,
  handler: None,
}

let setLoader = (eventHandler: t<'eventArgs>, loader) => {
  eventHandler.loader = Some(loader)
}

let setHandlerSync = (eventHandler: t<'eventArgs>, handler) => {
  eventHandler.handler = Some(
    Sync({handler, contextGetter: ctx => ctx->Context.getHandlerContextSync}),
  )
}

let setHandlerAsync = (eventHandler: t<'eventArgs>, handler) => {
  //Note: not adding previous raise error since this will be refactored away soon
  eventHandler.handler = Some(
    Async({handler, contextGetter: ctx => ctx->Context.getHandlerContextAsync}),
  )
}

let getLoader = ({loader, eventName}: t<'eventArgs>) =>
  switch loader {
  | Some(registered) => registered
  | None => getDefaultLoaderHandler(~eventName, ~functionRegister=Loader)
  }

let getHandler = ({handler, eventName}: t<'eventArgs>) =>
  switch handler {
  | Some(registered) => registered
  | None => getDefaultLoaderHandlerWithContextGetter(~eventName, ~functionRegister=Handler)
  }

module MakeRegister = (
  Event: {
    type eventArgs
    let eventName: Types.eventName
  },
) => {
  let register: t<Event.eventArgs> = make(~eventName=Event.eventName)
  let loader = setLoader(register)
  let handler = setHandlerSync(register)
  let handlerAsync = setHandlerAsync(register)
}
