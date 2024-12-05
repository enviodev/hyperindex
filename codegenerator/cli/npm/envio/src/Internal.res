type eventParams
type eventBlock
type eventTransaction

@genType
type genericEvent<'params, 'transaction, 'block> = {
  params: 'params,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction: 'transaction,
  block: 'block,
}

type event = genericEvent<eventParams, eventTransaction, eventBlock>

external fromGenericEvent: genericEvent<'a, 'b, 'c> => event = "%identity"

type loaderReturn

@genType
type genericLoaderArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
@genType
type genericLoader<'args, 'loaderReturn> = 'args => promise<'loaderReturn>

type loaderContext
type loaderArgs = genericLoaderArgs<event, loaderContext>
type loader = genericLoader<loaderArgs, loaderReturn>

@genType
type genericContractRegisterArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
@genType
type genericContractRegister<'args> = 'args => unit

type contractRegisterContext
type contractRegisterArgs = genericContractRegisterArgs<event, contractRegisterContext>
type contractRegister = genericContractRegister<contractRegisterArgs>

@genType
type genericHandlerArgs<'event, 'context, 'loaderReturn> = {
  event: 'event,
  context: 'context,
  loaderReturn: 'loaderReturn,
}
@genType
type genericHandler<'args> = 'args => promise<unit>

type handlerContext
type handlerArgs = genericHandlerArgs<event, handlerContext, loaderReturn>
type handler = genericHandler<handlerArgs>

type eventItem = {
  eventName: string,
  contractName: string,
  loader: option<loader>,
  handler: option<handler>,
  contractRegister: option<contractRegister>,
  timestamp: int,
  chain: ChainMap.Chain.t,
  blockNumber: int,
  logIndex: int,
  event: event,
  paramsRawEventSchema: S.schema<eventParams>,
  //Default to false, if an event needs to
  //be reprocessed after it has loaded dynamic contracts
  //This gets set to true and does not try and reload events
  hasRegisteredDynamicContracts?: bool,
}
