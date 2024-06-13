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
type loaderFnArgs<'eventArgs> = fnArgs<'eventArgs, Types.loaderContext>
@genType
type loaderFn<'eventArgs, 'loaderReturn> = loaderFnArgs<'eventArgs> => promise<
  'loaderReturn,
>

@genType
type handlerFnArgs<'eventArgs, 'loaderReturn> = {
  event: Types.eventLog<'eventArgs>,
  context: Types.handlerContext,
  loaderReturn: 'loaderReturn,
}

@genType
type handlerFn<'eventArgs, 'loaderReturn> = handlerFnArgs<
  'eventArgs,
  'loaderReturn,
> => promise<unit>

@genType
type registerArgsWithLoader<'eventArgs, 'loaderReturn> = {
  handler: handlerFn<'eventArgs, 'loaderReturn>,
  loader: loaderFn<'eventArgs, 'loaderReturn>,
  contractRegister?: contractRegisterFn<'eventArgs>,
}

type t

let get: (t, Types.eventName) => option<registerArgsWithLoader<'eventArgs, 'loadReturn>>

let global: t

module MakeRegister: (E: Types.Event) =>
{
  let register: registerArgsWithLoader<E.eventArgs, 'b> => unit
  let handler: handlerFn<E.eventArgs, unit> => unit
}
