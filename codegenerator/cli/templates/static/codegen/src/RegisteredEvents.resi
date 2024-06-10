@genType
type fnArgs<'eventArgs, 'context> = {
  event: Types.eventLog<'eventArgs>,
  context: 'context,
}

@genType
type contractRegisterFnArgs<'eventArgs> = fnArgs<'eventArgs, Types.contractRegistrations>
@genType
type contractRegisterFn<'eventArgs> = contractRegisterFnArgs<'eventArgs> => unit

@genType
type preLoaderFnArgs<'eventArgs> = fnArgs<'eventArgs, Types.loaderContext>
@genType
type preLoaderFn<'eventArgs, 'preLoaderReturn> = preLoaderFnArgs<'eventArgs> => promise<
  'preLoaderReturn,
>

@genType
type handlerFnArgs<'eventArgs, 'preLoaderReturn> = {
  event: Types.eventLog<'eventArgs>,
  context: Types.handlerContext,
  preLoaderReturn: 'preLoaderReturn,
}

@genType
type handlerFn<'eventArgs, 'preLoaderReturn> = handlerFnArgs<
  'eventArgs,
  'preLoaderReturn,
> => promise<unit>

@genType
type registerArgsWithPreLoader<'eventArgs, 'preLoaderReturn> = {
  handler: handlerFn<'eventArgs, 'preLoaderReturn>,
  preLoader: preLoaderFn<'eventArgs, 'preLoaderReturn>,
  contractRegister?: contractRegisterFn<'eventArgs>,
}

type t

let get: (t, Types.eventName) => option<registerArgsWithPreLoader<'eventArgs, 'preLoadReturn>>

let global: t

module MakeRegister: (E: Types.Event) =>
{
  let register: registerArgsWithPreLoader<E.eventArgs, 'b> => unit
  let handler: handlerFn<E.eventArgs, unit> => unit
}
