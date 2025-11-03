type registrations = {
  onBlockByChainId: dict<array<Internal.onBlockConfig>>,
  mutable hasEvents: bool,
}

let startRegistration: (
  ~ecosystem: Config.ecosystem,
  ~multichain: Config.multichain,
  ~preloadHandlers: bool,
) => unit
let finishRegistration: unit => registrations

let autoLoadHandlersFromSrc: (~srcPattern: string) => promise<unit>

type t
let make: (~contractName: string, ~eventName: string) => t
let setHandler: (
  t,
  Internal.genericHandler<
    Internal.genericHandlerArgs<'event, Internal.handlerContext, 'loaderReturn>,
  >,
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
