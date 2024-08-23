open Belt
type eventMod = module(Types.InternalEvent)

type eventError = WildcardEventCollision | DuplicateEvent
type eventKey = {topic0: string, contractName: string}
module EventsByContract = {
  type contract = {
    name: string,
    chains: array<ChainMap.Chain.t>,
  }
  type registeredEvent<'a> = {contract: contract, event: 'a, mutable isWildcard: bool}
  type t<'a> = {
    allEvents: array<registeredEvent<'a>>,
    eventsByContractName: dict<registeredEvent<'a>>,
  }

  let empty = () => {
    allEvents: [],
    eventsByContractName: Js.Dict.empty(),
  }

  let hasWildcardNetworkCollision = (eventA, eventB) => {
    (eventA.isWildcard || eventB.isWildcard) &&
      eventA.contract.chains->Array.some(chain =>
        eventB.contract.chains->Utils.Array.includes(chain)
      )
  }

  let insertEvent = (
    {allEvents, eventsByContractName}: t<_>,
    ~event,
    ~eventMod: eventMod,
    ~isWildcard,
  ) => {
    let module(Event) = eventMod
    let event = {contract: {name: Event.contractName, chains: Event.chains}, event, isWildcard}
    switch eventsByContractName->Js.Dict.get(event.contract.name) {
    | Some(_) => Error(DuplicateEvent)
    | None =>
      if allEvents->Array.some(existingEvent => hasWildcardNetworkCollision(existingEvent, event)) {
        Error(WildcardEventCollision)
      } else {
        allEvents->Js.Array2.push(event)->ignore
        eventsByContractName->Js.Dict.set(event.contract.name, event)
        Ok()
      }
    }
  }

  let getByContractName = ({eventsByContractName}, ~contractName) => {
    eventsByContractName->Js.Dict.get(contractName)->Option.map(v => v.event)
  }

  let findWildcard = ({allEvents}, ~chain) => {
    allEvents
    ->Js.Array2.find(event =>
      event.isWildcard && event.contract.chains->Utils.Array.includes(chain)
    )
    ->Option.map(v => v.event)
  }

  let getWildcardEventKeys = ({allEvents}: t<'a>, ~topic0): array<eventKey> => {
    allEvents->Array.keepMap(({contract, isWildcard}) =>
      isWildcard ? Some({topic0, contractName: contract.name}) : None
    )
  }

  let setEventToWildcard = ({allEvents, eventsByContractName}: t<'a>, ~contractName) => {
    switch eventsByContractName->Js.Dict.get(contractName) {
    | Some(event) =>
      event.isWildcard = true
      if (
        allEvents->Array.some(existing =>
          existing.contract.name != contractName && hasWildcardNetworkCollision(existing, event)
        )
      ) {
        event.isWildcard = false
        Error(WildcardEventCollision)
      } else {
        switch allEvents->Js.Array2.find(event => event.contract.name == contractName) {
        | Some(event) => event.isWildcard = true
        | None => ()
        }
        Ok()
      }
    | None => Ok() //ignore undefined event
    }
  }
}
type t<'a> = dict<EventsByContract.t<'a>>

let empty = () => Js.Dict.empty()

let addEvent = (eventLookup: t<'a>, event: 'a, ~eventMod: eventMod, ~isWildcard=false) => {
  let module(Event) = eventMod
  let events = switch eventLookup->Js.Dict.get(Event.topic0) {
  | None =>
    let events = EventsByContract.empty()
    eventLookup->Js.Dict.set(Event.topic0, events)
    events
  | Some(events) => events
  }
  events->EventsByContract.insertEvent(~event, ~eventMod, ~isWildcard)
}

let getEvent = (eventLookup: t<'a>, ~topic0, ~contractAddress, ~contractAddressMapping, ~chain) =>
  switch eventLookup->Js.Dict.get(topic0) {
  | Some({allEvents: [{event}]}) => Some(event)
  | Some({allEvents: []}) | None => None
  | Some(eventsByContract) =>
    switch contractAddressMapping->ContractAddressingMap.getContractNameFromAddress(
      ~contractAddress,
    ) {
    | Some(contractName) => eventsByContract->EventsByContract.getByContractName(~contractName)
    | None => eventsByContract->EventsByContract.findWildcard(~chain)
    }
  }

let getEventByKey = (eventLookup: t<'a>, ~topic0, ~contractName) =>
  eventLookup
  ->Js.Dict.get(topic0)
  ->Option.flatMap(eventsByContractName =>
    eventsByContractName->EventsByContract.getByContractName(~contractName)
  )

let getWildcardEventKeys = (eventLookup: t<'a>): array<eventKey> => {
  eventLookup
  ->Js.Dict.entries
  ->Array.flatMap(((topic0, eventsByContract)) => {
    eventsByContract->EventsByContract.getWildcardEventKeys(~topic0)
  })
}

let setEventToWildcard = (eventLookup: t<'a>, ~topic0, ~contractName) => {
  switch eventLookup->Js.Dict.get(topic0) {
  | Some(eventsByContractName) =>
    eventsByContractName->EventsByContract.setEventToWildcard(~contractName)
  | None => Ok() //ignore undefined event
  }
}

exception WildcardEventCollision
exception DuplicateEvent
let unwrapAddEventResponse = (
  result: result<unit, eventError>,
  ~context,
  ~eventName,
  ~contractName,
) => {
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
  | Ok() => ()
  }
}
