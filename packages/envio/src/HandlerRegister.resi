type registrations = {
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
}

let startRegistration: (~ecosystem: Ecosystem.t, ~multichain: Config.multichain) => unit
let isPendingRegistration: unit => bool
let finishRegistration: unit => registrations

let setHandler: (
  ~contractName: string,
  ~eventName: string,
  Internal.genericHandler<Internal.genericHandlerArgs<'event, Internal.handlerContext>>,
  ~eventOptions: option<Internal.eventOptions<'eventFilters>>,
  ~logger: Pino.t=?,
) => unit
let setContractRegister: (
  ~contractName: string,
  ~eventName: string,
  Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, 'context>>,
  ~eventOptions: option<Internal.eventOptions<'eventFilters>>,
  ~logger: Pino.t=?,
) => unit
let getHandler: (~contractName: string, ~eventName: string) => option<Internal.handler>
let getContractRegister: (~contractName: string, ~eventName: string) => option<Internal.contractRegister>
let getEventFilters: (~contractName: string, ~eventName: string) => option<Js.Json.t>
let isWildcard: (~contractName: string, ~eventName: string) => bool
let hasRegistration: (~contractName: string, ~eventName: string) => bool

let onBlock: (unknown, Internal.onBlockArgs => promise<unit>) => unit
