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

type contextParams = {
  eventItem: Internal.eventItem,
  inMemoryStore: InMemoryStore.t,
  loadManager: LoadManager.t,
  persistence: Persistence.t,
  isPreload: bool,
  shouldSaveHistory: bool,
}

let rec initEffect = (params: contextParams) => (
  effect: Internal.effect,
  input: Internal.effectInput,
) =>
  LoadLayer.loadEffect(
    ~loadManager=params.loadManager,
    ~persistence=params.persistence,
    ~effect,
    ~effectArgs={
      input,
      context: params->Utils.Proxy.make(effectTraps)->Utils.magic,
      cacheKey: input->S.reverseConvertOrThrow(effect.input)->Utils.Hash.makeOrThrow,
    },
    ~inMemoryStore=params.inMemoryStore,
    ~shouldGroup=params.isPreload,
    ~eventItem=params.eventItem,
  )
and effectTraps: Utils.Proxy.traps<contextParams> = {
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

let makeEntityHandlerContext = (
  ~entityConfig: Internal.entityConfig,
  ~params,
): Types.entityHandlerContext<Internal.entity> => {
  let get = entityId =>
    LoadLayer.loadById(
      ~loadManager=params.loadManager,
      ~persistence=params.persistence,
      ~entityConfig,
      ~inMemoryStore=params.inMemoryStore,
      ~shouldGroup=false,
      ~eventItem=params.eventItem,
      ~entityId,
    )
  let set = (entity: Internal.entity) => {
    params.inMemoryStore
    ->InMemoryStore.getInMemTable(~entityConfig)
    ->InMemoryTable.Entity.set(
      Set(entity)->Types.mkEntityUpdate(
        ~eventIdentifier=params.eventItem->makeEventIdentifier,
        ~entityId=entity.id,
      ),
      ~shouldSaveHistory=params.shouldSaveHistory,
    )
  }
  {
    set,
    deleteUnsafe: entityId => {
      params.inMemoryStore
      ->InMemoryStore.getInMemTable(~entityConfig)
      ->InMemoryTable.Entity.set(
        Delete->Types.mkEntityUpdate(
          ~eventIdentifier=params.eventItem->makeEventIdentifier,
          ~entityId,
        ),
        ~shouldSaveHistory=params.shouldSaveHistory,
      )
    },
    getOrThrow: (entityId, ~message=?) =>
      get(entityId)->Promise.thenResolve(entity => {
        switch entity {
        | Some(entity) => entity
        | None =>
          Js.Exn.raiseError(
            message->Belt.Option.getWithDefault(
              `Entity '${entityConfig.name}' with ID '${entityId}' is expected to exist.`,
            ),
          )
        }
      }),
    getOrCreate: (entity: Internal.entity) => {
      get(entity.id)->Promise.thenResolve(storageEntity => {
        switch storageEntity {
        | Some(entity) => entity
        | None => {
            set(entity)
            entity
          }
        }
      })
    },
    get,
  }
}

let handlerTraps: Utils.Proxy.traps<contextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    switch prop {
    | "log" => params.eventItem->Logging.getUserLogger->Utils.magic
    | "effect" =>
      initEffect((params :> contextParams))->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      )

    | _ =>
      switch Entities.byName->Utils.Dict.dangerouslyGetNonOption(prop) {
      | Some(entityConfig) => makeEntityHandlerContext(~entityConfig, ~params)->Utils.magic
      | None =>
        Js.Exn.raiseError(`Invalid context access by '${prop}' property. ${codegenHelpMessage}`)
      }
    }
  },
}

let getHandlerContext = (params: contextParams): Internal.handlerContext => {
  params->Utils.Proxy.make(handlerTraps)->Utils.magic
}

let getHandlerArgs = (params: contextParams, ~loaderReturn): Internal.handlerArgs => {
  event: params.eventItem.event,
  context: getHandlerContext(params),
  loaderReturn,
}

type entityContextParams = {
  ...contextParams,
  entityConfig: Internal.entityConfig,
}

let getWhereTraps: Utils.Proxy.traps<entityContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let entityConfig = params.entityConfig
    if prop->Js.typeof !== "string" {
      Js.Exn.raiseError(
        `Invalid context.${entityConfig.name}.getWhere access by a non-string property.`,
      )
    } else {
      let dbFieldName = prop->(Utils.magic: unknown => string)
      switch entityConfig.table->Table.getFieldByDbName(dbFieldName) {
      | None =>
        Js.Exn.raiseError(
          `Invalid context.${entityConfig.name}.getWhere.${dbFieldName} - the field doesn't exist. ${codegenHelpMessage}`,
        )
      | Some(field) =>
        let fieldValueSchema = switch field {
        | Field({fieldSchema}) => fieldSchema
        | DerivedFrom(_) => S.string->S.toUnknown
        }
        {
          Entities.eq: fieldValue =>
            LoadLayer.loadByField(
              ~loadManager=params.loadManager,
              ~persistence=params.persistence,
              ~operator=Eq,
              ~entityConfig,
              ~fieldName=dbFieldName,
              ~fieldValueSchema,
              ~inMemoryStore=params.inMemoryStore,
              ~shouldGroup=params.isPreload,
              ~eventItem=params.eventItem,
              ~fieldValue,
            ),
          gt: fieldValue =>
            LoadLayer.loadByField(
              ~loadManager=params.loadManager,
              ~persistence=params.persistence,
              ~operator=Gt,
              ~entityConfig,
              ~fieldName=dbFieldName,
              ~fieldValueSchema,
              ~inMemoryStore=params.inMemoryStore,
              ~shouldGroup=params.isPreload,
              ~eventItem=params.eventItem,
              ~fieldValue,
            ),
        }->Utils.magic
      }
    }
  },
}

let noopSet = (_entity: Internal.entity) => ()

let entityTraps: Utils.Proxy.traps<entityContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)

    let set = params.isPreload
      ? noopSet
      : (entity: Internal.entity) => {
          params.inMemoryStore
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig)
          ->InMemoryTable.Entity.set(
            Set(entity)->Types.mkEntityUpdate(
              ~eventIdentifier=params.eventItem->makeEventIdentifier,
              ~entityId=entity.id,
            ),
            ~shouldSaveHistory=params.shouldSaveHistory,
          )
        }

    switch prop {
    | "get" =>
      (
        entityId =>
          LoadLayer.loadById(
            ~loadManager=params.loadManager,
            ~persistence=params.persistence,
            ~entityConfig=params.entityConfig,
            ~inMemoryStore=params.inMemoryStore,
            ~shouldGroup=params.isPreload,
            ~eventItem=params.eventItem,
            ~entityId,
          )
      )->Utils.magic
    | "getWhere" => params->Utils.Proxy.make(getWhereTraps)->Utils.magic
    | "getOrThrow" =>
      (
        (entityId, ~message=?) =>
          LoadLayer.loadById(
            ~loadManager=params.loadManager,
            ~persistence=params.persistence,
            ~entityConfig=params.entityConfig,
            ~inMemoryStore=params.inMemoryStore,
            ~shouldGroup=params.isPreload,
            ~eventItem=params.eventItem,
            ~entityId,
          )->Promise.thenResolve(entity => {
            switch entity {
            | Some(entity) => entity
            | None =>
              Js.Exn.raiseError(
                message->Belt.Option.getWithDefault(
                  `Entity '${params.entityConfig.name}' with ID '${entityId}' is expected to exist.`,
                ),
              )
            }
          })
      )->Utils.magic
    | "getOrCreate" =>
      (
        (entity: Internal.entity) =>
          LoadLayer.loadById(
            ~loadManager=params.loadManager,
            ~persistence=params.persistence,
            ~entityConfig=params.entityConfig,
            ~inMemoryStore=params.inMemoryStore,
            ~shouldGroup=params.isPreload,
            ~eventItem=params.eventItem,
            ~entityId=entity.id,
          )->Promise.thenResolve(storageEntity => {
            switch storageEntity {
            | Some(entity) => entity
            | None => {
                set(entity)
                entity
              }
            }
          })
      )->Utils.magic
    | "set" => set->Utils.magic
    | _ => Js.Exn.raiseError(`Invalid context.${params.entityConfig.name}.${prop} operation.`)
    }
  },
}

let loaderTraps: Utils.Proxy.traps<contextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    switch prop {
    | "log" =>
      (params.isPreload ? Logging.noopLogger : params.eventItem->Logging.getUserLogger)->Utils.magic
    | "effect" =>
      initEffect((params :> contextParams))->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      )

    | "isPreload" => params.isPreload->Utils.magic
    | _ =>
      switch Entities.byName->Utils.Dict.dangerouslyGetNonOption(prop) {
      | Some(entityConfig) =>
        {
          eventItem: params.eventItem,
          isPreload: params.isPreload,
          inMemoryStore: params.inMemoryStore,
          loadManager: params.loadManager,
          persistence: params.persistence,
          shouldSaveHistory: params.shouldSaveHistory,
          entityConfig,
        }
        ->Utils.Proxy.make(entityTraps)
        ->Utils.magic
      | None =>
        Js.Exn.raiseError(`Invalid context access by '${prop}' property. ${codegenHelpMessage}`)
      }
    }
  },
}

let getLoaderContext = (params: contextParams): Internal.loaderContext => {
  params->Utils.Proxy.make(loaderTraps)->Utils.magic
}

let getLoaderArgs = (params: contextParams): Internal.loaderArgs => {
  event: params.eventItem.event,
  context: getLoaderContext(params),
}

// Contract register context creation
type contractRegisterParams = {
  eventItem: Internal.eventItem,
  onRegister: (
    ~eventItem: Internal.eventItem,
    ~contractAddress: Address.t,
    ~contractName: Enums.ContractType.t,
  ) => unit,
  config: Config.t,
}

let contractRegisterTraps: Utils.Proxy.traps<contractRegisterParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)

    switch prop {
    | "log" => params.eventItem->Logging.getUserLogger->Utils.magic
    | _ =>
      // Use the pre-built mapping for efficient lookup
      switch params.config.addContractNameToContractNameMapping->Utils.Dict.dangerouslyGetNonOption(
        prop,
      ) {
      | Some(contractName) => {
          let addFunction = (contractAddress: Address.t) => {
            let validatedAddress = if params.config.ecosystem === Evm {
              // The value is passed from the user-land,
              // so we need to validate and checksum the address.
              contractAddress->Address.Evm.fromAddressOrThrow
            } else {
              // TODO: Ideally we should do the same for other ecosystems
              contractAddress
            }

            params.onRegister(
              ~eventItem=params.eventItem,
              ~contractAddress=validatedAddress,
              ~contractName=contractName->(Utils.magic: string => Enums.ContractType.t),
            )
          }

          addFunction->Utils.magic
        }
      | None =>
        Js.Exn.raiseError(`Invalid context access by '${prop}' property. ${codegenHelpMessage}`)
      }
    }
  },
}

let getContractRegisterContext = (~eventItem, ~onRegister, ~config: Config.t) => {
  {
    eventItem,
    onRegister,
    config,
  }
  ->Utils.Proxy.make(contractRegisterTraps)
  ->Utils.magic
}

let getContractRegisterArgs = (
  eventItem: Internal.eventItem,
  ~onRegister,
  ~config: Config.t,
): Internal.contractRegisterArgs => {
  event: eventItem.event,
  context: getContractRegisterContext(~eventItem, ~onRegister, ~config),
}
