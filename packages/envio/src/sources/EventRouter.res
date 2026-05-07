exception EventDuplicate
exception WildcardCollision

module Group = {
  type t<'a> = {
    mutable wildcard: option<'a>,
    byContractName: dict<'a>,
  }

  let empty = () => {
    wildcard: None,
    byContractName: Dict.make(),
  }

  let addOrThrow = (group: t<'a>, event, ~contractName, ~isWildcard) => {
    let {byContractName, wildcard} = group
    switch byContractName->Utils.Dict.dangerouslyGetNonOption(contractName) {
    | Some(_) => throw(EventDuplicate)
    | None =>
      if isWildcard && wildcard->Option.isSome {
        throw(WildcardCollision)
      } else {
        if isWildcard {
          group.wildcard = Some(event)
        }
        byContractName->Dict.set(contractName, event)
      }
    }
  }

  let get = (
    group: t<'a>,
    ~contractAddress,
    ~blockNumber,
    ~indexingAddresses: dict<FetchState.indexingAddress>,
  ) =>
    switch group {
    | {wildcard, byContractName} =>
      switch indexingAddresses->Utils.Dict.dangerouslyGetNonOption(
        contractAddress->Address.toString,
      ) {
      | Some(indexingContract) =>
        if indexingContract.effectiveStartBlock <= blockNumber {
          switch byContractName->Utils.Dict.dangerouslyGetNonOption(indexingContract.contractName) {
          // Fall back to the wildcard handler when the indexed contract has no
          // matching event for this tag. This covers addresses registered for
          // contracts without events (persisted for future config changes) as
          // well as addresses whose contract has other events but not this one.
          | None => wildcard
          | Some(_) as event => event
          }
        } else {
          None
        }
      | None => wildcard
      }
    }
}

type t<'a> = dict<Group.t<'a>>

let empty = () => Dict.make()

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
    router->Dict.set(eventId, group)
    group
  | Some(group) => group
  }
  try group->Group.addOrThrow(event, ~contractName, ~isWildcard) catch {
  | EventDuplicate =>
    JsError.throwWithMessage(
      `Duplicate event detected: ${eventName} for contract ${contractName} on chain ${chain->ChainMap.Chain.toString}`,
    )
  | WildcardCollision =>
    JsError.throwWithMessage(
      `Another event is already registered with the same signature that would interfer with wildcard filtering: ${eventName} for contract ${contractName} on chain ${chain->ChainMap.Chain.toString}`,
    )
  }
}

let get = (router: t<'a>, ~tag, ~contractAddress, ~blockNumber, ~indexingAddresses) => {
  switch router->Utils.Dict.dangerouslyGetNonOption(tag) {
  | None => None
  | Some(group) => group->Group.get(~contractAddress, ~blockNumber, ~indexingAddresses)
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
