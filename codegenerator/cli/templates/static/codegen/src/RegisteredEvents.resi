@genType
type args<'eventArgs, 'context> = {
  event: Types.eventLog<'eventArgs>,
  context: 'context,
}

@genType
type contractRegisterArgs<'eventArgs> = args<'eventArgs, Types.contractRegistrations>
@genType
type contractRegister<'eventArgs> = contractRegisterArgs<'eventArgs> => unit

@genType
type loaderArgs<'eventArgs> = args<'eventArgs, Types.loaderContext>
@genType
type loader<'eventArgs, 'loaderReturn> = loaderArgs<'eventArgs> => promise<'loaderReturn>

@genType
type handlerArgs<'eventArgs, 'loaderReturn> = {
  event: Types.eventLog<'eventArgs>,
  context: Types.handlerContext,
  loaderReturn: 'loaderReturn,
}

@genType
type handler<'eventArgs, 'loaderReturn> = handlerArgs<'eventArgs, 'loaderReturn> => promise<unit>

@genType
type registeredLoaderHandler<'eventArgs, 'loaderReturn> = {
  loader: loader<'eventArgs, 'loaderReturn>,
  handler: handler<'eventArgs, 'loaderReturn>,
}

@genType
type registeredEvent<'eventArgs, 'loaderReturn> = {
  loaderHandler?: registeredLoaderHandler<'eventArgs, 'loaderReturn>,
  contractRegister?: contractRegister<'eventArgs>,
}

type t

let make: unit => t

let get: (t, module(Types.InternalEvent)) => option<registeredEvent<'eventArgs, 'loadReturn>>

let global: t

module MakeRegister: (E: Types.Event) =>
{
  let handler: handler<E.eventArgs, unit> => unit
  let contractRegister: contractRegister<E.eventArgs> => unit
  let handlerWithLoader: registeredLoaderHandler<E.eventArgs, 'loaderReturn> => unit
}
