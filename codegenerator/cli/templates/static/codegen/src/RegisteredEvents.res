type args<'eventArgs, 'context> = {
  event: Types.eventLog<'eventArgs>,
  context: 'context,
}

type contractRegisterArgs<'eventArgs> = args<'eventArgs, Types.contractRegistrations>
type contractRegister<'eventArgs> = contractRegisterArgs<'eventArgs> => unit

type loaderArgs<'eventArgs> = args<'eventArgs, Types.loaderContext>
type loader<'eventArgs, 'loaderReturn> = loaderArgs<'eventArgs> => promise<'loaderReturn>

type handlerArgs<'eventArgs, 'loaderReturn> = {
  event: Types.eventLog<'eventArgs>,
  context: Types.handlerContext,
  loaderReturn: 'loaderReturn,
}

type handler<'eventArgs, 'loaderReturn> = handlerArgs<'eventArgs, 'loaderReturn> => promise<unit>

type loaderHandler<'eventArgs, 'loaderReturn> = {
  loader: loader<'eventArgs, 'loaderReturn>,
  handler: handler<'eventArgs, 'loaderReturn>,
}

type eventOptions = {
  wildcard: bool,
  topicSelections: array<LogSelection.topicSelection>,
}

type registeredEvent<'eventArgs, 'loaderReturn> = {
  loaderHandler?: loaderHandler<'eventArgs, 'loaderReturn>,
  contractRegister?: contractRegister<'eventArgs>,
  eventOptions: eventOptions,
}

type t = {
  loaderHandlers: EventLookup.t<loaderHandler<unknown, unknown>>,
  contractRegisters: EventLookup.t<contractRegister<unknown>>,
  eventOptionsMap: EventLookup.t<eventOptions>,
}

let make = () => {
  loaderHandlers: EventLookup.empty(),
  contractRegisters: EventLookup.empty(),
  eventOptionsMap: EventLookup.empty(),
}

let unwrapAddEventResponse = EventLookup.unwrapAddEventResponse
let registerEventFunction = (
  args,
  ~context,
  ~handlerMap,
  ~eventOptionsMap,
  ~eventMod,
  ~eventOptions: option<eventOptions>,
) => {
  let module(Event: Types.InternalEvent) = eventMod

  let handleAddEventResponse = unwrapAddEventResponse(
    _,
    ~context,
    ~eventName=Event.name,
    ~contractName=Event.contractName,
  )

  switch eventOptions {
  | Some(eventOptions) =>
    //add options to the event options map
    //and handle failures for collisions
    eventOptionsMap
    ->EventLookup.addEvent(eventOptions, ~eventMod, ~isWildcard=eventOptions.wildcard)
    ->handleAddEventResponse

    //Once the option is added, get all the wildcard event keys from the mapping
    //and update the handlerLoader map to handle any new wildcards that have been
    //registered here or elsewhere
    eventOptionsMap
    ->EventLookup.getWildcardEventKeys
    ->Belt.Array.forEach(({contractName, topic0}) => {
      handlerMap
      ->EventLookup.setEventToWildcard(~contractName, ~topic0)
      ->handleAddEventResponse
    })

  | None => ()
  }

  //Add loaderHandlers
  handlerMap
  ->EventLookup.addEvent(
    args,
    ~eventMod,
    ~isWildcard=?eventOptions->Belt.Option.map(opts => opts.wildcard),
  )
  ->handleAddEventResponse
}

let addLoaderHandler = (
  {loaderHandlers, eventOptionsMap}: t,
  eventMod,
  args: loaderHandler<'eventArgs, 'loadReturn>,
  ~eventOptions: option<eventOptions>,
) => {
  args
  ->(Utils.magic: loaderHandler<'eventArgs, 'loadReturn> => loaderHandler<unknown, unknown>)
  ->registerEventFunction(
    ~handlerMap=loaderHandlers,
    ~context="Add handler function",
    ~eventOptionsMap,
    ~eventOptions,
    ~eventMod,
  )
}

let addContractRegister = (
  {contractRegisters, eventOptionsMap}: t,
  eventMod,
  args: contractRegister<'eventArgs>,
  ~eventOptions: option<eventOptions>,
) => {
  args
  ->(Utils.magic: contractRegister<'eventArgs> => contractRegister<unknown>)
  ->registerEventFunction(
    ~handlerMap=contractRegisters,
    ~context="Add contractRegister function",
    ~eventOptionsMap,
    ~eventOptions,
    ~eventMod,
  )
}

// This set makes sure that the warning doesn't print for every event of a type, but rather only prints the first time.
let hasPrintedWarning = Set.make()

let getEventKey = eventMod => {
  let module(Event: Types.InternalEvent) = eventMod
  Event.contractName ++ "_" ++ Event.topic0
}

let getDefaultEventOptions = (eventMod): eventOptions => {
  let module(Event: Types.InternalEvent) = eventMod
  let topicSelection =
    LogSelection.makeTopicSelection(~topic0=[Event.topic0])->Utils.unwrapResultExn
  {
    wildcard: false,
    topicSelections: [topicSelection],
  }
}

let get = (registeredEvents: t, eventMod) => {
  let module(Event: Types.InternalEvent) = eventMod

  let get = EventLookup.getEventByKey(_, ~topic0=Event.topic0, ~contractName=Event.contractName)

  let registeredLoaderHandler =
    registeredEvents.loaderHandlers
    ->get
    ->(
      Utils.magic: option<loaderHandler<unknown, unknown>> => option<
        loaderHandler<'eventArgs, 'loadReturn>,
      >
    )

  let contractRegister =
    registeredEvents.contractRegisters
    ->get
    ->(Utils.magic: option<contractRegister<unknown>> => option<contractRegister<'eventArgs>>)

  switch (registeredLoaderHandler, contractRegister) {
  | (None, None) =>
    let eventKey = eventMod->getEventKey
    if !(hasPrintedWarning->Set.has(eventKey)) {
      // Here are docs on the 'terminal hyperlink' formatting that I use to link to the docs: https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda
      Logging.warn(
        `Skipped "${Event.name}" on contract "${Event.contractName}", as there is no handler registered. You need to implement the event "${Event.name}" register method in your handler file or ignore this warning if you don't intend to implement it. Here are our docs on this topic: \n\n https://docs.envio.dev/docs/event-handlers`,
      )
      let _ = hasPrintedWarning->Set.add(eventKey)
    }
    None
  | (loaderHandler, contractRegister) =>
    Some({
      ?loaderHandler,
      ?contractRegister,
      eventOptions: getDefaultEventOptions(eventMod),
    })
  }
}

let global = make()

let getWildcardEventKeys: unit => array<EventLookup.eventKey> = () =>
  global.eventOptionsMap->EventLookup.getWildcardEventKeys

let defaultAsyncFn = _ => Promise.resolve()

module MakeRegister = (Event: Types.Event) => {
  let eventMod = module(Event)->Types.eventModToInternal

  let handler = handler =>
    global->addLoaderHandler(
      eventMod,
      {
        loader: defaultAsyncFn,
        handler,
      },
      ~eventOptions=None,
    )

  let contractRegister: contractRegister<Event.eventArgs> => unit = contractRegister =>
    global->addContractRegister(eventMod, contractRegister, ~eventOptions=None)

  let handlerWithLoader: loaderHandler<Event.eventArgs, 'loaderReturn> => unit = args =>
    global->addLoaderHandler(eventMod, args, ~eventOptions=None)
}
