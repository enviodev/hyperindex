let makeEventIdentifier = (eventItem: Internal.eventItem): Types.eventIdentifier => {
  let {event, blockNumber, timestamp} = eventItem
  {
    chainId: event.chainId,
    blockTimestamp: timestamp,
    blockNumber,
    logIndex: event.logIndex,
  }
}

let getEventId = (eventItem: Internal.eventItem) => {
  EventUtils.packEventIndex(~blockNumber=eventItem.blockNumber, ~logIndex=eventItem.event.logIndex)
}

let makeDynamicContractId = (~chainId, ~contractAddress) => {
  chainId->Belt.Int.toString ++ "-" ++ contractAddress->Address.toString
}

type handlerContextParams = {
  eventItem: Internal.eventItem,
  inMemoryStore: InMemoryStore.t,
  loadLayer: LoadLayer.t,
  shouldSaveHistory: bool,
}

let makeEntityHandlerContext = (
  ~inMemoryStore,
  ~entityMod: module(Entities.InternalEntity),
  ~eventItem,
  ~loadLayer,
  ~shouldSaveHistory,
): Types.entityHandlerContext<Entities.internalEntity> => {
  {
    set: entity => {
      inMemoryStore
      ->InMemoryStore.getInMemTable(~entityMod)
      ->InMemoryTable.Entity.set(
        Set(entity)->Types.mkEntityUpdate(
          ~eventIdentifier=eventItem->makeEventIdentifier,
          ~entityId=entity.id,
        ),
        ~shouldSaveHistory,
      )
    },
    deleteUnsafe: entityId => {
      inMemoryStore
      ->InMemoryStore.getInMemTable(~entityMod)
      ->InMemoryTable.Entity.set(
        Delete->Types.mkEntityUpdate(~eventIdentifier=eventItem->makeEventIdentifier, ~entityId),
        ~shouldSaveHistory,
      )
    },
    get: entityId =>
      loadLayer->LoadLayer.loadById(
        ~entityMod,
        ~inMemoryStore,
        ~groupLoad=false,
        ~eventItem,
        ~entityId,
      ),
  }
}

let handlerTraps: Utils.Proxy.traps<handlerContextParams> = {
  get: (~target, ~prop: unknown) => {
    if prop->Js.typeof !== "string" {
      Js.Exn.raiseError("Invalid context access by a non-string property.")
    } else {
      let prop = prop->(Utils.magic: unknown => string)
      if prop === "log" {
        target.eventItem->Logging.getUserLogger->Utils.magic
      } else {
        switch Entities.byName->Utils.Dict.dangerouslyGetNonOption(prop) {
        | Some(entityMod) =>
          makeEntityHandlerContext(
            ~entityMod,
            ~eventItem=target.eventItem,
            ~inMemoryStore=target.inMemoryStore,
            ~loadLayer=target.loadLayer,
            ~shouldSaveHistory=target.shouldSaveHistory,
          )->Utils.magic
        | None => Js.Exn.raiseError(`Invalid context access by "${prop}" property.`)
        }
      }
    }
  },
}

let getHandlerContext = (params: handlerContextParams): Internal.handlerContext => {
  params->Utils.Proxy.make(handlerTraps)->Utils.magic
}
