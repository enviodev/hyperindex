type t = {
  contractName: string,
  eventName: string,
  mutable handler: option<Internal.handler>,
  mutable contractRegister: option<Internal.contractRegister>,
  mutable eventOptions: option<Internal.eventOptions<Js.Json.t>>,
}

let getHandler = (t: t) => t.handler

let getContractRegister = (t: t) => t.contractRegister

let getEventFilters = (t: t) => t.eventOptions->Belt.Option.flatMap(value => value.eventFilters)

let isWildcard = (t: t) =>
  t.eventOptions->Belt.Option.flatMap(value => value.wildcard)->Belt.Option.getWithDefault(false)

let hasRegistration = ({handler, contractRegister}) =>
  handler->Belt.Option.isSome || contractRegister->Belt.Option.isSome

let make = (~contractName, ~eventName) => {
  contractName,
  eventName,
  handler: None,
  contractRegister: None,
  eventOptions: None,
}

type eventNamespace = {contractName: string, eventName: string}
exception DuplicateEventRegistration(eventNamespace)

let setEventOptions = (t: t, ~eventOptions, ~logger=Logging.getLogger()) => {
  switch eventOptions {
  | Some(value) =>
    let value =
      value->(Utils.magic: Internal.eventOptions<'eventFilters> => Internal.eventOptions<Js.Json.t>)
    switch t.eventOptions {
    | None => t.eventOptions = Some(value)
    | Some(existingValue) =>
      if (
        existingValue.wildcard !== value.wildcard ||
          // TODO: Can improve the check by using deepEqual
          existingValue.eventFilters !== value.eventFilters
      ) {
        let eventNamespace = {contractName: t.contractName, eventName: t.eventName}
        DuplicateEventRegistration(eventNamespace)->ErrorHandling.mkLogAndRaise(
          ~logger=Logging.createChildFrom(~logger, ~params=eventNamespace),
          ~msg="Duplicate eventOptions in handlers not allowed",
        )
      }
    }
  | None => ()
  }
}

let setHandler = (t: t, handler, ~eventOptions, ~logger=Logging.getLogger()) => {
  switch t.handler {
  | None =>
    t.handler =
      handler
      ->(Utils.magic: Internal.genericHandler<'args> => Internal.handler)
      ->Some
  | Some(_) =>
    let eventNamespace = {contractName: t.contractName, eventName: t.eventName}
    DuplicateEventRegistration(eventNamespace)->ErrorHandling.mkLogAndRaise(
      ~logger=Logging.createChildFrom(~logger, ~params=eventNamespace),
      ~msg="Duplicate registration of event handlers not allowed",
    )
  }

  t->setEventOptions(~eventOptions, ~logger)
}

let setContractRegister = (t: t, contractRegister, ~eventOptions, ~logger=Logging.getLogger()) => {
  switch t.contractRegister {
  | None =>
    t.contractRegister = Some(
      contractRegister->(
        Utils.magic: Internal.genericContractRegister<
          Internal.genericContractRegisterArgs<'event, 'context>,
        > => Internal.contractRegister
      ),
    )
  | Some(_) =>
    let eventNamespace = {contractName: t.contractName, eventName: t.eventName}
    DuplicateEventRegistration(eventNamespace)->ErrorHandling.mkLogAndRaise(
      ~logger=Logging.createChildFrom(~logger, ~params=eventNamespace),
      ~msg="Duplicate contractRegister handlers not allowed",
    )
  }
  t->setEventOptions(~eventOptions, ~logger)
}
