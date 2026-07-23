type chainRegistrations = {
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}
type registrationsByChainId = dict<chainRegistrations>

let startRegistration: (~config: Config.t) => unit
let resetOnEventRegistrations: unit => unit
let isPendingRegistration: unit => bool
let finishRegistration: (~config: Config.t) => registrationsByChainId
let throwIfFinishedRegistration: (~methodName: string) => unit

let setHandler: (
  ~contractName: string,
  ~eventName: string,
  Internal.genericHandler<Internal.genericHandlerArgs<'event, Internal.handlerContext>>,
  ~eventOptions: option<Internal.eventOptions<'where>>,
) => unit
let setContractRegister: (
  ~contractName: string,
  ~eventName: string,
  Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, 'context>>,
  ~eventOptions: option<Internal.eventOptions<'where>>,
) => unit
let isWildcard: (~contractName: string, ~eventName: string) => bool
let isDroppedByWhere: (~config: Config.t, Internal.onEventRegistration) => bool
let getSimulateOnEventRegistrations: (
  ~config: Config.t,
  ~chainId: int,
  ~eventConfig: Internal.eventConfig,
) => array<Internal.onEventRegistration>

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
