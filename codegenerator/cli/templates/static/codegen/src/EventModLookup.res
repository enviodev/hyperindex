open Belt
type eventMod = module(Types.InternalEvent)

type errorKind = WildcardSighashCollision | Duplicate
type eventError = {eventMod: eventMod, errorKind: errorKind}
module ContractEventMods = {
  type t = {
    mutable wildcard: option<eventMod>,
    all: array<eventMod>,
    byContractName: dict<eventMod>,
  }

  let empty = () => {
    wildcard: None,
    all: [],
    byContractName: Js.Dict.empty(),
  }

  let isWildcard = (eventMod: eventMod) => {
    let module(Event) = eventMod
    Event.handlerRegister
    ->Types.HandlerTypes.Register.getEventOptions
    ->(v => v.Types.HandlerTypes.wildcard)
  }

  let set = (t: t, eventMod: eventMod) => {
    let {all, byContractName} = t
    let module(Event) = eventMod
    switch byContractName->Utils.Dict.dangerouslyGetNonOption(Event.contractName) {
    | Some(_) => Error({eventMod, errorKind: Duplicate})
    | None =>
      let isWildcard = eventMod->isWildcard
      if isWildcard && t.wildcard->Option.isSome {
        Error({eventMod, errorKind: WildcardSighashCollision})
      } else {
        if isWildcard {
          t.wildcard = Some(eventMod)
        }
        all->Js.Array2.push(eventMod)->ignore
        byContractName->Js.Dict.set(Event.contractName, eventMod)
        Ok()
      }
    }
  }

  let get = (t: t, ~contractAddress, ~contractAddressMapping) =>
    switch t {
    | {all: [eventMod]} => Some(eventMod)
    | {wildcard, byContractName} =>
      switch contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(
        ~contractAddress,
      ) {
      | Some(contractName) => byContractName->Utils.Dict.dangerouslyGetNonOption(contractName)
      | None => wildcard
      }
    }

  let getByContractName = ({byContractName}, ~contractName) => {
    byContractName->Utils.Dict.dangerouslyGetNonOption(contractName)
  }
}
type t = dict<ContractEventMods.t>

let empty = () => Js.Dict.empty()

let set = (eventModLookup: t, eventMod: module(Types.Event)) => {
  let module(Event) = eventMod
  let events = switch eventModLookup->Utils.Dict.dangerouslyGetNonOption(Event.sighash) {
  | None =>
    let events = ContractEventMods.empty()
    eventModLookup->Js.Dict.set(Event.sighash, events)
    events
  | Some(events) => events
  }
  events->ContractEventMods.set(
    eventMod->(Utils.magic: module(Types.Event) => module(Types.InternalEvent)),
  )
}

let get = (eventModLookup: t, ~sighash, ~contractAddress, ~contractAddressMapping) =>
  eventModLookup
  ->Utils.Dict.dangerouslyGetNonOption(sighash)
  ->Option.flatMap(ContractEventMods.get(_, ~contractAddress, ~contractAddressMapping))

let getByKey = (eventModLookup: t, ~sighash, ~contractName) =>
  eventModLookup
  ->Utils.Dict.dangerouslyGetNonOption(sighash)
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
    ->set(eventMod)
    ->unwrapAddEventResponse(~chain)
  })
  t
}
