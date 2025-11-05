let codegenHelpMessage = `Rerun 'pnpm dev' to update generated code after schema.graphql changes.`

type contextParams = {
  item: Internal.item,
  checkpointId: int,
  inMemoryStore: InMemoryStore.t,
  loadManager: LoadManager.t,
  persistence: Persistence.t,
  isPreload: bool,
  shouldSaveHistory: bool,
  chains: Internal.chains,
  mutable isResolved: bool,
}

// We don't want to expose the params to the user
// so instead of storing _params on the context object,
// we use an external WeakMap
let paramsByThis: Utils.WeakMap.t<unknown, contextParams> = Utils.WeakMap.make()

let effectContextPrototype = %raw(`Object.create(null)`)
Utils.Object.defineProperty(
  effectContextPrototype,
  "log",
  {
    get: () => {
      (paramsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))).item->Logging.getUserLogger
    },
  },
)
%%raw(`
var EffectContext = function(params, defaultShouldCache, callEffect) {
  paramsByThis.set(this, params);
  this.effect = callEffect;
  this.cache = defaultShouldCache;
};
EffectContext.prototype = effectContextPrototype;
`)

@new
external makeEffectContext: (
  contextParams,
  ~defaultShouldCache: bool,
  ~callEffect: (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>,
) => Internal.effectContext = "EffectContext"

let initEffect = (params: contextParams) => {
  let rec callEffect = (effect: Internal.effect, input: Internal.effectInput) => {
    let effectContext = makeEffectContext(
      params,
      ~defaultShouldCache=effect.defaultShouldCache,
      ~callEffect,
    )
    let effectArgs: Internal.effectArgs = {
      input,
      context: effectContext,
      cacheKey: input->S.reverseConvertOrThrow(effect.input)->Utils.Hash.makeOrThrow,
    }
    LoadLayer.loadEffect(
      ~loadManager=params.loadManager,
      ~persistence=params.persistence,
      ~effect,
      ~effectArgs,
      ~inMemoryStore=params.inMemoryStore,
      ~shouldGroup=params.isPreload,
      ~item=params.item,
    )
  }
  callEffect
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
              ~item=params.item,
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
              ~item=params.item,
              ~fieldValue,
            ),
          lt: fieldValue =>
            LoadLayer.loadByField(
              ~loadManager=params.loadManager,
              ~persistence=params.persistence,
              ~operator=Lt,
              ~entityConfig,
              ~fieldName=dbFieldName,
              ~fieldValueSchema,
              ~inMemoryStore=params.inMemoryStore,
              ~shouldGroup=params.isPreload,
              ~item=params.item,
              ~fieldValue,
            ),
        }->Utils.magic
      }
    }
  },
}

let noopSet = (_entity: Internal.entity) => ()
let noopDeleteUnsafe = (_entityId: string) => ()

let entityTraps: Utils.Proxy.traps<entityContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)

    let set = params.isPreload
      ? noopSet
      : (entity: Internal.entity) => {
          params.inMemoryStore
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig)
          ->InMemoryTable.Entity.set(
            {
              entityId: entity.id,
              checkpointId: params.checkpointId,
              entityUpdateAction: Set(entity),
            },
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
            ~item=params.item,
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
            ~item=params.item,
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
            ~item=params.item,
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
    | "deleteUnsafe" =>
      if params.isPreload {
        noopDeleteUnsafe
      } else {
        entityId => {
          params.inMemoryStore
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig)
          ->InMemoryTable.Entity.set(
            {
              entityId,
              checkpointId: params.checkpointId,
              entityUpdateAction: Delete,
            },
            ~shouldSaveHistory=params.shouldSaveHistory,
          )
        }
      }->Utils.magic
    | _ => Js.Exn.raiseError(`Invalid context.${params.entityConfig.name}.${prop} operation.`)
    }
  },
}

let handlerTraps: Utils.Proxy.traps<contextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    if params.isResolved {
      Utils.Error.make(
        `Impossible to access context.${prop} after the handler is resolved. Make sure you didn't miss an await in the handler.`,
      )->ErrorHandling.mkLogAndRaise(~logger=params.item->Logging.getItemLogger)
    }
    switch prop {
    | "log" =>
      (params.isPreload ? Logging.noopLogger : params.item->Logging.getUserLogger)->Utils.magic
    | "effect" =>
      initEffect((params :> contextParams))->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      )

    | "isPreload" => params.isPreload->Utils.magic
    | "chains" => params.chains->Utils.magic
    | _ =>
      switch Entities.byName->Utils.Dict.dangerouslyGetNonOption(prop) {
      | Some(entityConfig) =>
        {
          item: params.item,
          isPreload: params.isPreload,
          inMemoryStore: params.inMemoryStore,
          loadManager: params.loadManager,
          persistence: params.persistence,
          shouldSaveHistory: params.shouldSaveHistory,
          checkpointId: params.checkpointId,
          chains: params.chains,
          isResolved: params.isResolved,
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

let getHandlerContext = (params: contextParams): Internal.handlerContext => {
  params->Utils.Proxy.make(handlerTraps)->Utils.magic
}

// Contract register context creation
type contractRegisterParams = {
  item: Internal.item,
  onRegister: (
    ~item: Internal.item,
    ~contractAddress: Address.t,
    ~contractName: Enums.ContractType.t,
  ) => unit,
  config: Config.t,
  mutable isResolved: bool,
}

let contractRegisterTraps: Utils.Proxy.traps<contractRegisterParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    if params.isResolved {
      Utils.Error.make(
        `Impossible to access context.${prop} after the contract register is resolved. Make sure you didn't miss an await in the handler.`,
      )->ErrorHandling.mkLogAndRaise(~logger=params.item->Logging.getItemLogger)
    }
    switch prop {
    | "log" => params.item->Logging.getUserLogger->Utils.magic
    | _ =>
      // Use the pre-built mapping for efficient lookup
      switch params.config.addContractNameToContractNameMapping->Utils.Dict.dangerouslyGetNonOption(
        prop,
      ) {
      | Some(contractName) => {
          let addFunction = (contractAddress: Address.t) => {
            let validatedAddress = if params.config.ecosystem === Evm {
              // The value is passed from the user-land,
              // so we need to validate and checksum/lowercase the address.
              if params.config.lowercaseAddresses {
                contractAddress->Address.Evm.fromAddressLowercaseOrThrow
              } else {
                contractAddress->Address.Evm.fromAddressOrThrow
              }
            } else {
              // TODO: Ideally we should do the same for other ecosystems
              contractAddress
            }

            params.onRegister(
              ~item=params.item,
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

let getContractRegisterContext = (params: contractRegisterParams) => {
  params
  ->Utils.Proxy.make(contractRegisterTraps)
  ->Utils.magic
}

let getContractRegisterArgs = (params: contractRegisterParams): Internal.contractRegisterArgs => {
  event: (params.item->Internal.castUnsafeEventItem).event,
  context: getContractRegisterContext(params),
}
