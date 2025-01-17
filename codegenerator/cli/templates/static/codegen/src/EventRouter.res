open Belt

exception EventDuplicate
exception WildcardCollision

module Group = {
  type t<'a> = {
    mutable wildcard: option<'a>,
    all: array<'a>,
    byContractName: dict<'a>,
  }

  let empty = () => {
    wildcard: None,
    all: [],
    byContractName: Js.Dict.empty(),
  }

  let addOrThrow = (group: t<'a>, event, ~contractName, ~isWildcard) => {
    let {all, byContractName, wildcard} = group
    switch byContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
    | Some(_) => raise(EventDuplicate)
    | None =>
      if isWildcard && wildcard->Option.isSome {
        raise(WildcardCollision)
      } else {
        if isWildcard {
          group.wildcard = Some(event)
        }
        all->Js.Array2.push(event)->ignore
        byContractName->Js.Dict.set(contractName, event)
      }
    }
  }

  let get = (group: t<'a>, ~contractAddress, ~contractAddressMapping) =>
    switch group {
    | {all: [event]} => Some(event)
    | {wildcard, byContractName} =>
      switch contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(
        ~contractAddress,
      ) {
      | Some(contractName) => byContractName->Utils.Dict.dangerouslyGetNonOption(contractName)
      | None => wildcard
      }
    }
}

type t<'a> = dict<Group.t<'a>>

let empty = () => Js.Dict.empty()

let addOrThrow = (
  router: t<'a>,
  eventId,
  event,
  ~contractName,
  ~isWildcard,
  ~eventName,
  ~chain,
) => {
  let group = switch router->Utils.Dict.dangerouslyGetNonOption(eventId) {
  | None =>
    let group = Group.empty()
    router->Js.Dict.set(eventId, group)
    group
  | Some(group) => group
  }
  try group->Group.addOrThrow(event, ~contractName, ~isWildcard) catch {
  | EventDuplicate =>
    Js.Exn.raiseError(
      `Duplicate event detected: ${eventName} for contract ${contractName} on chain ${chain->ChainMap.Chain.toString}`,
    )
  | WildcardCollision =>
    Js.Exn.raiseError(
      `Another event is already registered with the same signature that would interfer with wildcard filtering: ${eventName} for contract ${contractName} on chain ${chain->ChainMap.Chain.toString}`,
    )
  }
}

let get = (router: t<'a>, ~tag, ~contractAddress, ~contractAddressMapping) => {
  switch router->Utils.Dict.dangerouslyGetNonOption(tag) {
  | None => None
  | Some(group) => group->Group.get(~contractAddress, ~contractAddressMapping)
  }
}

let getEvmEventId = (~sighash, ~topicCount) => {
  sighash ++ "_" ++ topicCount->Belt.Int.toString
}

let fromEvmEventModsOrThrow = (eventMods: array<module(Types.Event)>, ~chain): t<
  module(Types.InternalEvent),
> => {
  let router = empty()
  eventMods->Belt.Array.forEach(eventMod => {
    let eventMod = eventMod->(Utils.magic: module(Types.Event) => module(Types.InternalEvent))
    let module(Event) = eventMod
    router->addOrThrow(
      Event.id,
      eventMod,
      ~contractName=Event.contractName,
      ~eventName=Event.name,
      ~chain,
      ~isWildcard=(Event.handlerRegister->Types.HandlerTypes.Register.getEventOptions).isWildcard,
    )
  })
  router
}
