open Belt

exception EventDuplicate
exception WildcardCollision

module Group = {
  type t<'a> = {
    mutable wildcard: option<'a>,
    byContractName: dict<'a>,
  }

  let empty = () => {
    wildcard: None,
    byContractName: Js.Dict.empty(),
  }

  let addOrThrow = (group: t<'a>, event, ~contractName, ~isWildcard) => {
    let {byContractName, wildcard} = group
    switch byContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
    | Some(_) => raise(EventDuplicate)
    | None =>
      if isWildcard && wildcard->Option.isSome {
        raise(WildcardCollision)
      } else {
        if isWildcard {
          group.wildcard = Some(event)
        }
        byContractName->Js.Dict.set(contractName, event)
      }
    }
  }

  let get = (
    group: t<'a>,
    ~contractAddress,
    ~blockNumber,
    ~indexingContracts: dict<FetchState.indexingContract>,
  ) =>
    switch group {
    | {wildcard, byContractName} =>
      switch indexingContracts->Utils.Dict.dangerouslyGetNonOption(
        contractAddress->Address.toString,
      ) {
      | Some(indexingContract) =>
        if indexingContract.startBlock <= blockNumber {
          byContractName->Utils.Dict.dangerouslyGetNonOption(indexingContract.contractName)
        } else {
          None
        }
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

let get = (router: t<'a>, ~tag, ~contractAddress, ~blockNumber, ~indexingContracts) => {
  switch router->Utils.Dict.dangerouslyGetNonOption(tag) {
  | None => None
  | Some(group) => group->Group.get(~contractAddress, ~blockNumber, ~indexingContracts)
  }
}

let getEvmEventId = (~sighash, ~topicCount) => {
  sighash ++ "_" ++ topicCount->Belt.Int.toString
}

let fromEvmEventModsOrThrow = (events: array<Internal.evmEventConfig>, ~chain): t<
  Internal.evmEventConfig,
> => {
  let router = empty()
  events->Belt.Array.forEach(config => {
    router->addOrThrow(
      config.id,
      config,
      ~contractName=config.contractName,
      ~eventName=config.name,
      ~chain,
      ~isWildcard=config.isWildcard,
    )
  })
  router
}
