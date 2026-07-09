type chainRegistrations = {
  onEventRegistrations: array<Internal.onEventRegistration>,
  onBlockRegistrations: array<Internal.onBlockRegistration>,
}
type registrationsByChainId = dict<chainRegistrations>

let startRegistration: (~config: Config.t) => unit
let withConfig: (Config.t => unit) => unit
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

let registerOnBlock: (
  ~name: string,
  ~chainId: int,
  ~interval: int,
  ~startBlock: option<int>,
  ~endBlock: option<int>,
  ~handler: Internal.onBlockArgs => promise<unit>,
) => unit
