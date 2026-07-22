type chainRegistrations = {
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}
type registrationsByChainId = dict<chainRegistrations>

let startRegistration: (~config: Config.t) => unit
let isPendingRegistration: unit => bool
let finishRegistration: (~config: Config.t) => registrationsByChainId
let throwIfFinishedRegistration: (~methodName: string) => unit

let buildOnEventRegistration: (
  ~config: Config.t,
  ~chainId: int,
  ~eventConfig: Internal.eventConfig,
  ~startBlock: int=?,
) => Internal.onEventRegistration

let setHandler: (
  ~contractName: string,
  ~eventName: string,
  Internal.genericHandler<Internal.genericHandlerArgs<'event, Internal.handlerContext>>,
  ~eventOptions: option<Internal.eventOptions<'where>>,
  ~logger: Pino.t=?,
) => unit
let setContractRegister: (
  ~contractName: string,
  ~eventName: string,
  Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, 'context>>,
  ~eventOptions: option<Internal.eventOptions<'where>>,
  ~logger: Pino.t=?,
) => unit
let getHandler: (~contractName: string, ~eventName: string) => option<Internal.handler>
let getContractRegister: (
  ~contractName: string,
  ~eventName: string,
) => option<Internal.contractRegister>
let isWildcard: (~contractName: string, ~eventName: string) => bool
let hasRegistration: (~contractName: string, ~eventName: string) => bool

type blockRange = {
  _gte: option<int>,
  _lte: option<int>,
  _every: int,
}
let blockRangeSchema: S.t<blockRange>
let defaultBlockRange: blockRange

let registerOnBlock: (
  ~name: string,
  ~where: unknown,
  ~handler: Internal.onBlockArgs => promise<unit>,
  ~getChainsObject: Config.t => dict<unknown>,
) => unit
