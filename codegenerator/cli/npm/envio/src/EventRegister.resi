type eventHandlerRegistration = {
  eventConfigId: string,
  handler: option<Internal.handler>,
  contractRegister: option<Internal.contractRegister>,
  isWildcard: bool,
  filterByAddresses: bool,
  dependsOnAddresses: bool,
}

type registrations = {
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
  eventHandlerRegistrations: dict<eventHandlerRegistration>,
  mutable hasEvents: bool,
}

let startRegistration: (~ecosystem: Ecosystem.t, ~multichain: Config.multichain) => unit
let isPendingRegistration: unit => bool
let finishRegistration: unit => registrations

// Get an event registration by eventConfigId
let getEventRegistration: (registrations, ~eventConfigId: string) => option<eventHandlerRegistration>

// Check if an event has a contractRegister
let hasContractRegister: (registrations, ~eventConfigId: string) => bool

type t
let make: (~contractName: string, ~eventName: string, ~eventConfigId: string) => t
let setHandler: (
  t,
  Internal.genericHandler<Internal.genericHandlerArgs<'event, Internal.handlerContext>>,
  ~eventOptions: option<Internal.eventOptions<'eventFilters>>,
  ~logger: Pino.t=?,
) => unit
let setContractRegister: (
  t,
  Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, 'context>>,
  ~eventOptions: option<Internal.eventOptions<'eventFilters>>,
  ~logger: Pino.t=?,
) => unit
let getHandler: t => option<Internal.handler>
let getContractRegister: t => option<Internal.contractRegister>
let getEventFilters: t => option<Js.Json.t>
let isWildcard: t => bool
let hasRegistration: t => bool

let onBlock: (unknown, Internal.onBlockArgs => promise<unit>) => unit
