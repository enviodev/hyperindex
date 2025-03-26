type eventParams
type eventBlock
type eventTransaction

@genType
type genericEvent<'params, 'block, 'transaction> = {
  params: 'params,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction: 'transaction,
  block: 'block,
}

type event = genericEvent<eventParams, eventBlock, eventTransaction>

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

@genType
type genericHandlerWithLoader<'loader, 'handler, 'eventFilters> = {
  loader: 'loader,
  handler: 'handler,
  wildcard?: bool,
  eventFilters?: 'eventFilters,
  preRegisterDynamicContracts?: bool,
}

type baseEventConfig = {
  id: string,
  name: string,
  contractName: string,
  isWildcard: bool,
  preRegisterDynamicContracts: bool,
  loader: option<loader>,
  handler: option<handler>,
  contractRegister: option<contractRegister>,
  paramsRawEventSchema: S.schema<eventParams>,
}

type fuelEventKind =
  | LogData({logId: string, decode: string => eventParams})
  | Mint
  | Burn
  | Transfer
  | Call
type fuelEventConfig = {
  ...baseEventConfig,
  kind: fuelEventKind,
}
type fuelContractConfig = {
  name: string,
  events: array<fuelEventConfig>,
}

type topicSelection = {
  topic0: array<EvmTypes.Hex.t>,
  topic1: array<EvmTypes.Hex.t>,
  topic2: array<EvmTypes.Hex.t>,
  topic3: array<EvmTypes.Hex.t>,
}

type evmEventConfig = {
  ...baseEventConfig,
  getTopicSelectionsOrThrow: (~chain: ChainMap.Chain.t) => array<topicSelection>,
  blockSchema: S.schema<eventBlock>,
  transactionSchema: S.schema<eventTransaction>,
  convertHyperSyncEventArgs: HyperSyncClient.Decoder.decodedEvent => eventParams,
}
type evmContractConfig = {
  name: string,
  abi: Ethers.abi,
  events: array<evmEventConfig>,
}

type eventItem = {
  eventConfig: baseEventConfig,
  timestamp: int,
  chain: ChainMap.Chain.t,
  blockNumber: int,
  logIndex: int,
  event: event,
  //Default to false, if an event needs to
  //be reprocessed after it has loaded dynamic contracts
  //This gets set to true and does not try and reload events
  hasRegisteredDynamicContracts?: bool,
}

@genType
type fuelSupplyParams = {
  subId: string,
  amount: bigint,
}
let fuelSupplyParamsSchema = S.schema(s => {
  subId: s.matches(S.string),
  amount: s.matches(BigInt.schema),
})
@genType
type fuelTransferParams = {
  to: Address.t,
  assetId: string,
  amount: bigint,
}
let fuelTransferParamsSchema = S.schema(s => {
  to: s.matches(Address.schema),
  assetId: s.matches(S.string),
  amount: s.matches(BigInt.schema),
})

type entity = private {id: string}

@genType.import(("./bindings/OpaqueTypes.ts", "invalid"))
type noEventFilters
type eventFilters
type eventFiltersArgs = {chainId: int}
