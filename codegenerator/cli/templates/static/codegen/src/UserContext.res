let codegenHelpMessage = `Rerun 'pnpm dev' to update generated code after schema.graphql changes.`

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

type baseContextParams = {
  eventItem: Internal.eventItem,
  inMemoryStore: InMemoryStore.t,
  loadLayer: LoadLayer.t,
  shouldGroup: bool,
}

let rec initEffect = (params: baseContextParams) => (
  effect: Internal.effect,
  input: Internal.effectInput,
) =>
  params.loadLayer->LoadLayer.loadEffect(
    ~effect,
    ~effectArgs={
      input,
      context: params->Utils.Proxy.make(effectTraps)->Utils.magic,
      cacheKey: input->Utils.Hash.makeOrThrow,
    },
    ~inMemoryStore=params.inMemoryStore,
    ~shouldGroup=params.shouldGroup,
  )
and effectTraps: Utils.Proxy.traps<baseContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    switch prop {
    | "log" => params.eventItem->Logging.getUserLogger->Utils.magic
    | "effect" =>
      initEffect(params)->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      )

    | _ =>
      Js.Exn.raiseError(
        `Invalid context access by '${prop}' property. Effect context doesn't allow access to storage.`,
      )
    }
  },
}

type handlerContextParams = {
  ...baseContextParams,
  shouldSaveHistory: bool,
}

let makeEntityHandlerContext = (
  ~entityMod: module(Entities.InternalEntity),
  ~params,
): Types.entityHandlerContext<Entities.internalEntity> => {
  {
    set: entity => {
      params.inMemoryStore
      ->InMemoryStore.getInMemTable(~entityMod)
      ->InMemoryTable.Entity.set(
        Set(entity)->Types.mkEntityUpdate(
          ~eventIdentifier=params.eventItem->makeEventIdentifier,
          ~entityId=entity.id,
        ),
        ~shouldSaveHistory=params.shouldSaveHistory,
      )
    },
    deleteUnsafe: entityId => {
      params.inMemoryStore
      ->InMemoryStore.getInMemTable(~entityMod)
      ->InMemoryTable.Entity.set(
        Delete->Types.mkEntityUpdate(
          ~eventIdentifier=params.eventItem->makeEventIdentifier,
          ~entityId,
        ),
        ~shouldSaveHistory=params.shouldSaveHistory,
      )
    },
    get: entityId =>
      params.loadLayer->LoadLayer.loadById(
        ~entityMod,
        ~inMemoryStore=params.inMemoryStore,
        ~shouldGroup=false,
        ~eventItem=params.eventItem,
        ~entityId,
      ),
  }
}

let handlerTraps: Utils.Proxy.traps<handlerContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    switch prop {
    | "log" => params.eventItem->Logging.getUserLogger->Utils.magic
    | "effect" =>
      initEffect((params :> baseContextParams))->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      )

    | _ =>
      switch Entities.byName->Utils.Dict.dangerouslyGetNonOption(prop) {
      | Some(entityMod) => makeEntityHandlerContext(~entityMod, ~params)->Utils.magic
      | None =>
        Js.Exn.raiseError(`Invalid context access by '${prop}' property. ${codegenHelpMessage}`)
      }
    }
  },
}

let getHandlerContext = (params: handlerContextParams): Internal.handlerContext => {
  params->Utils.Proxy.make(handlerTraps)->Utils.magic
}

let getHandlerArgs = (params: handlerContextParams, ~loaderReturn): Internal.handlerArgs => {
  event: params.eventItem.event,
  context: getHandlerContext(params),
  loaderReturn,
}

type loaderEntityContextParams = {
  ...baseContextParams,
  entityMod: module(Entities.InternalEntity),
}

let getWhereTraps: Utils.Proxy.traps<loaderEntityContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let module(Entity) = params.entityMod
    if prop->Js.typeof !== "string" {
      Js.Exn.raiseError(
        `Invalid context.${(Entity.name :> string)}.getWhere access by a non-string property.`,
      )
    } else {
      let dbFieldName = prop->(Utils.magic: unknown => string)
      switch Entity.table->Table.getFieldByDbName(dbFieldName) {
      | None =>
        Js.Exn.raiseError(
          `Invalid context.${(Entity.name :> string)}.getWhere.${dbFieldName} - the field doesn't exist. ${codegenHelpMessage}`,
        )
      | Some(field) =>
        let fieldValueSchema = switch field {
        | Field({fieldSchema}) => fieldSchema
        | DerivedFrom(_) => S.string->S.toUnknown
        }
        {
          Entities.eq: fieldValue =>
            params.loadLayer->LoadLayer.loadByField(
              ~operator=Eq,
              ~entityMod=params.entityMod,
              ~fieldName=dbFieldName,
              ~fieldValueSchema,
              ~inMemoryStore=params.inMemoryStore,
              ~shouldGroup=params.shouldGroup,
              ~eventItem=params.eventItem,
              ~fieldValue,
            ),
          gt: fieldValue =>
            params.loadLayer->LoadLayer.loadByField(
              ~operator=Gt,
              ~entityMod=params.entityMod,
              ~fieldName=dbFieldName,
              ~fieldValueSchema,
              ~inMemoryStore=params.inMemoryStore,
              ~shouldGroup=params.shouldGroup,
              ~eventItem=params.eventItem,
              ~fieldValue,
            ),
        }->Utils.magic
      }
    }
  },
}

let makeEntityLoaderContext = (params): Types.entityLoaderContext<
  Entities.internalEntity,
  unknown,
> => {
  {
    get: entityId =>
      params.loadLayer->LoadLayer.loadById(
        ~entityMod=params.entityMod,
        ~inMemoryStore=params.inMemoryStore,
        ~shouldGroup=params.shouldGroup,
        ~eventItem=params.eventItem,
        ~entityId,
      ),
    getWhere: params->Utils.Proxy.make(getWhereTraps)->Utils.magic,
  }
}

let loaderTraps: Utils.Proxy.traps<baseContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    switch prop {
    | "log" => params.eventItem->Logging.getUserLogger->Utils.magic
    | "effect" =>
      initEffect((params :> baseContextParams))->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      )

    | _ =>
      switch Entities.byName->Utils.Dict.dangerouslyGetNonOption(prop) {
      | Some(entityMod) =>
        makeEntityLoaderContext({
          eventItem: params.eventItem,
          shouldGroup: params.shouldGroup,
          inMemoryStore: params.inMemoryStore,
          loadLayer: params.loadLayer,
          entityMod,
        })->Utils.magic
      | None =>
        Js.Exn.raiseError(`Invalid context access by '${prop}' property. ${codegenHelpMessage}`)
      }
    }
  },
}

let getLoaderContext = (params: baseContextParams): Internal.loaderContext => {
  params->Utils.Proxy.make(loaderTraps)->Utils.magic
}

let getLoaderArgs = (params: baseContextParams): Internal.loaderArgs => {
  event: params.eventItem.event,
  context: getLoaderContext(params),
}
