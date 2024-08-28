open Belt
type eventMod = module(Types.InternalEvent)

type errorKind = WildcardSighashCollision | Duplicate
type eventError = {eventMod: eventMod, errorKind: errorKind}
module ContractEventMods = {
  type t = {
    all: array<eventMod>,
    byContractName: dict<eventMod>,
  }

  let empty = () => {
    all: [],
    byContractName: Js.Dict.empty(),
  }

  let isWildcard = (eventMod: eventMod) => {
    let module(Event) = eventMod
    Event.handlerRegister->Types.Handlers.Register.getEventOptions->(v => v.Types.Handlers.wildcard)
  }

  let hasWildcardCollision = (eventModA, eventModB) => {
    eventModA->isWildcard || eventModB->isWildcard
  }

  let set = ({all, byContractName}: t, eventMod: eventMod) => {
    let module(Event) = eventMod
    switch byContractName->Js.Dict.get(Event.contractName) {
    | Some(_) => Error({eventMod, errorKind: Duplicate})
    | None =>
      if all->Array.some(hasWildcardCollision(_, eventMod)) {
        Error({eventMod, errorKind: WildcardSighashCollision})
      } else {
        all->Js.Array2.push(eventMod)->ignore
        byContractName->Js.Dict.set(Event.contractName, eventMod)
        Ok()
      }
    }
  }

  let getByContractName = ({byContractName}, ~contractName) => {
    byContractName->Js.Dict.get(contractName)
  }

  let findWildcard = ({all}) => {
    all->Js.Array2.find(event => event->isWildcard)
  }
}
type t = dict<ContractEventMods.t>

let empty = () => Js.Dict.empty()

let set = (eventModLookup: t, eventMod: eventMod) => {
  let module(Event) = eventMod
  let events = switch eventModLookup->Js.Dict.get(Event.sighash) {
  | None =>
    let events = ContractEventMods.empty()
    eventModLookup->Js.Dict.set(Event.sighash, events)
    events
  | Some(events) => events
  }
  events->ContractEventMods.set(eventMod)
}

let get = (eventModLookup: t, ~sighash, ~contractAddress, ~contractAddressMapping) =>
  switch eventModLookup->Js.Dict.get(sighash) {
  | Some({all: [eventMod]}) => Some(eventMod)
  | Some({all: []}) | None => None
  | Some(eventsByContract) =>
    switch contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(
      ~contractAddress,
    ) {
    | Some(contractName) => eventsByContract->ContractEventMods.getByContractName(~contractName)
    | None => eventsByContract->ContractEventMods.findWildcard
    }
  }

let getByKey = (eventModLookup: t, ~sighash, ~contractName) =>
  eventModLookup
  ->Js.Dict.get(sighash)
  ->Option.flatMap(eventsByContractName =>
    eventsByContractName->ContractEventMods.getByContractName(~contractName)
  )

let unwrapAddEventResponse = (result: result<'a, eventError>, ~chain) => {
  switch result {
  | Error({eventMod, errorKind: Duplicate}) =>
    let module(Event) = eventMod
    Js.Exn.raiseError(
      `Duplicate event detected: ${Event.name} for contract ${Event.contractName} on chain ${chain->ChainMap.Chain.toString}`,
    )
  | Error({eventMod, errorKind: WildcardSighashCollision}) =>
    let module(Event) = eventMod
    Js.Exn.raiseError(
      `Another event is already registered with the same signature that would interfer with wildcard filtering: ${Event.name} for contract ${Event.contractName} on chain ${chain->ChainMap.Chain.toString}`,
    )
  | Ok(v) => v
  }
}

let fromArrayOrThrow = (eventMods: array<module(Types.Event)>, ~chain): t => {
  let t = empty()
  eventMods->Belt.Array.forEach(eventMod => {
    t
    ->set(eventMod->(Utils.magic: module(Types.Event) => module(Types.InternalEvent)))
    ->unwrapAddEventResponse(~chain)
  })
  t
}
