type eventRegistration = {
  handler: option<Internal.handler>,
  contractRegister: option<Internal.contractRegister>,
  eventOptions: option<Internal.eventOptions<Js.Json.t>>,
}

type registrations = {
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
}

let startRegistration: (~ecosystem: Ecosystem.t, ~multichain: Config.multichain) => unit
let isPendingRegistration: unit => bool
let finishRegistration: unit => registrations

let get: (~contractName: string, ~eventName: string) => eventRegistration
let set: (~contractName: string, ~eventName: string, eventRegistration) => unit

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

let onBlock: (unknown, Internal.onBlockArgs => promise<unit>) => unit

let applyRegistrations: (~config: Config.t, ~ecosystem: Ecosystem.t) => unit
