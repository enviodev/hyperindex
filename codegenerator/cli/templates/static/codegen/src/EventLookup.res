open Belt
type eventMod = module(Types.InternalEvent)
type contract = {
  name: string,
  chains: array<ChainMap.Chain.t>,
}
type registeredEvent<'a> = {contract: contract, event: 'a, mutable isWildcard: bool}
type eventsAtTopic0<'a> = Single(registeredEvent<'a>) | Multiple(dict<registeredEvent<'a>>)

type t<'a> = dict<eventsAtTopic0<'a>>

let empty = () => Js.Dict.empty()

exception WildcardEventCollision
exception DuplicateEvent

let hasWildcardNetworkCollision = (eventA, eventB) => {
  (eventA.isWildcard || eventB.isWildcard) &&
    eventA.contract.chains->Array.some(chain => eventB.contract.chains->Utils.Array.includes(chain))
}

let addEvent = (eventLookup: t<'a>, event: 'a, ~eventMod: eventMod, ~isWildcard=false) => {
  let module(Event) = eventMod
  let event = {contract: {name: Event.contractName, chains: Event.chains}, event, isWildcard}
  switch eventLookup->Js.Dict.get(Event.sighash) {
  | None =>
    eventLookup->Js.Dict.set(Event.sighash, Single(event))
    Ok()
  //Overwrite single if it has a matching contractName
  | Some(Single(existing)) if existing.contract.name == Event.contractName => Error(DuplicateEvent)
  | Some(Single(existing)) =>
    //Wildcard events cannot have collisions with other networks
    if hasWildcardNetworkCollision(existing, event) {
      Error(WildcardEventCollision)
    } else {
      let values =
        [(existing.contract.name, existing), (Event.contractName, event)]->Js.Dict.fromArray
      eventLookup->Js.Dict.set(Event.sighash, Multiple(values))
      Ok()
    }
  | Some(Multiple(values)) =>
    if values->Js.Dict.get(Event.contractName)->Option.isSome {
      Error(DuplicateEvent)
    } else if (
      values
      ->Js.Dict.values
      ->Array.some(existing => hasWildcardNetworkCollision(existing, event))
    ) {
      Error(WildcardEventCollision)
    } else {
      values->Js.Dict.set(Event.contractName, event)
      Ok()
    }
  }
}

let getEvent = (eventLookup: t<'a>, ~topic0, ~contractAddress, ~contractAddressMapping, ~chain) =>
  switch eventLookup->Js.Dict.get(topic0) {
  | Some(Single({event})) => Some(event)
  | Some(Multiple(events)) =>
    switch contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(
      ~contractAddress,
    ) {
    | Some(contractName) => events->Js.Dict.get(contractName)->Option.map(v => v.event)
    | None =>
      events
      ->Js.Dict.values
      ->Js.Array2.find(event =>
        event.isWildcard && event.contract.chains->Utils.Array.includes(chain)
      )
      ->Option.map(v => v.event)
    }
  | None => None
  }

let getEventByKey = (eventLookup: t<'a>, ~topic0, ~contractName) =>
  switch eventLookup->Js.Dict.get(topic0) {
  | Some(Single({event, contract})) if contractName == contract.name => Some(event)
  | Some(Multiple(values)) => values->Js.Dict.get(contractName)->Option.map(v => v.event)
  | Some(Single(_)) | None => None
  }

type eventKey = {topic0: string, contractName: string}
let getWildcardEventKeys = (eventLookup: t<'a>) => {
  eventLookup
  ->Js.Dict.entries
  ->Array.flatMap(((topic0, registeredEvent)) => {
    switch registeredEvent {
    | Single({contract, isWildcard}) => isWildcard ? [{topic0, contractName: contract.name}] : []
    | Multiple(dict) =>
      dict
      ->Js.Dict.values
      ->Array.keepMap(({contract, isWildcard}) =>
        isWildcard ? Some({topic0, contractName: contract.name}) : None
      )
    }
  })
}

let setEventToWildcard = (eventLookup: t<'a>, ~topic0, ~contractName) => {
  switch eventLookup->Js.Dict.get(topic0) {
  | Some(Single(event)) if event.contract.name == contractName =>
    event.isWildcard = true
    Ok()
  | Some(Multiple(events)) =>
    switch events->Js.Dict.get(contractName) {
    | Some(event) =>
      event.isWildcard = true
      if (
        events
        ->Js.Dict.values
        ->Array.some(existing =>
          existing.contract.name != contractName && hasWildcardNetworkCollision(existing, event)
        )
      ) {
        event.isWildcard = false
        Error(WildcardEventCollision)
      } else {
        Ok()
      }
    | None => Ok() //ignore undefined event
    }
  | Some(Single(_)) | None => Ok() //ignore undefined event
  }
}

let unwrapAddEventResponse = (result, ~context, ~eventName, ~contractName) => {
  let logger = Logging.createChild(
    ~params={
      "context": context,
      "contractName": contractName,
      "eventName": eventName,
    },
  )
  switch result {
  | Error(DuplicateEvent) =>
    DuplicateEvent->ErrorHandling.mkLogAndRaise(
      ~logger,
      ~msg="Duplicate registration of event detected",
    )
  | Error(WildcardEventCollision) =>
    WildcardEventCollision->ErrorHandling.mkLogAndRaise(
      ~logger,
      ~msg="Another event is already registered with the same signature that would interfer with wildcard filtering.",
    )
  | Error(exn) => exn->ErrorHandling.mkLogAndRaise(~msg="Unexpected error occurred")
  | Ok() => ()
  }
}
