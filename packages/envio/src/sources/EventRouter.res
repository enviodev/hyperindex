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

/** Dispatch key for SVM instructions. `None` matches any instruction in the
 program (lowest priority). */
let getSvmEventId = (~programId: SvmTypes.Pubkey.t, ~discriminator: option<string>) =>
  switch discriminator {
  | None => (programId->SvmTypes.Pubkey.toString) ++ "_none"
  | Some(d) => (programId->SvmTypes.Pubkey.toString) ++ "_" ++ d
  }

/** Discriminator byte-lengths declared by a program, sorted descending. The
 source uses this to probe `(programId, dN)` keys longest-first when routing
 a returned instruction to a handler — matching the locked Q1 answer. */
type svmProgramOrdering = {
  programId: SvmTypes.Pubkey.t,
  /** Byte lengths in descending order, deduplicated. Includes `0` only when
   a handler is registered with no discriminator (program-wide match). */
  byteLengthsDesc: array<int>,
}

let fromSvmEventConfigsOrThrow = (
  events: array<Internal.svmInstructionEventConfig>,
  ~chain,
): (t<Internal.svmInstructionEventConfig>, array<svmProgramOrdering>) => {
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

  // Per-program list of declared discriminator byte lengths, sorted desc.
  let byProgram: dict<Utils.Set.t<int>> = Dict.make()
  events->Belt.Array.forEach(config => {
    let key = config.programId->SvmTypes.Pubkey.toString
    let set = switch byProgram->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(s) => s
    | None =>
      let s = Utils.Set.make()
      byProgram->Dict.set(key, s)
      s
    }
    let _ = set->Utils.Set.add(config.discriminatorByteLen)
  })
  let ordering =
    byProgram
    ->Dict.toArray
    ->Array.map(((programIdString, lens)) => {
      let sorted = lens->Utils.Set.toArray->Array.toSorted((a, b) => (b - a)->Int.toFloat)
      {
        programId: programIdString->SvmTypes.Pubkey.fromStringUnsafe,
        byteLengthsDesc: sorted,
      }
    })

  (router, ordering)
}
