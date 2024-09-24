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
    (Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions).isWildcard
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
let getEvmEventTag = (~sighash, ~topicCount) => {
  sighash ++ "_" ++ topicCount->Belt.Int.toString
}
type t = dict<ContractEventMods.t>

let empty = () => Js.Dict.empty()

let set = (eventRouter: t, eventTag, eventMod: module(Types.Event)) => {
  let events = switch eventRouter->Utils.Dict.dangerouslyGetNonOption(eventTag) {
  | None =>
    let events = ContractEventMods.empty()
    eventRouter->Js.Dict.set(eventTag, events)
    events
  | Some(events) => events
  }
  events->ContractEventMods.set(
    eventMod->(Utils.magic: module(Types.Event) => module(Types.InternalEvent)),
  )
}

let get = (eventRouter: t, ~tag, ~contractAddress, ~contractAddressMapping) => {
  switch eventRouter->Utils.Dict.dangerouslyGetNonOption(tag) {
  | None => None
  | Some(events) => events->ContractEventMods.get(~contractAddress, ~contractAddressMapping)
  }
}

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
    let module(Event) = eventMod
    t
    ->set(getEvmEventTag(~sighash=Event.sighash, ~topicCount=Event.topicCount), eventMod)
    ->unwrapAddEventResponse(~chain)
  })
  t
}
