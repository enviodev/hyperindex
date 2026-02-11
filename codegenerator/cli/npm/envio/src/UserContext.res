let codegenHelpMessage = `Rerun 'pnpm dev' to update generated code after schema.graphql changes.`

type contextParams = {
  item: Internal.item,
  checkpointId: float,
  inMemoryStore: InMemoryStore.t,
  loadManager: LoadManager.t,
  persistence: Persistence.t,
  isPreload: bool,
  shouldSaveHistory: bool,
  chains: Internal.chains,
  config: Config.t,
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

let getWhereHandler = (params: entityContextParams, filter: Js.Dict.t<Js.Dict.t<unknown>>) => {
  let entityConfig = params.entityConfig
  let filterKeys = filter->Js.Dict.keys

  if filterKeys->Array.length === 0 {
    Js.Exn.raiseError(
      `Empty filter passed to context.${entityConfig.name}.getWhere(). Please provide a filter like { fieldName: { _eq: value } }.`,
    )
  }
  if filterKeys->Array.length > 1 {
    Js.Exn.raiseError(
      `Multiple filter fields passed to context.${entityConfig.name}.getWhere(). Currently only one filter field per call is supported. Received fields: ${filterKeys->Js.Array2.joinWith(", ")}.`,
    )
  }

  let dbFieldName = filterKeys->Js.Array2.unsafe_get(0)
  let operatorObj = filter->Js.Dict.unsafeGet(dbFieldName)
  let operatorKeys = operatorObj->Js.Dict.keys

  if operatorKeys->Array.length === 0 {
    Js.Exn.raiseError(
      `Empty operator passed to context.${entityConfig.name}.getWhere({ ${dbFieldName}: {} }). Please provide an operator like { _eq: value }, { _gt: value }, or { _lt: value }.`,
    )
  }
  if operatorKeys->Array.length > 1 {
    Js.Exn.raiseError(
      `Multiple operators passed to context.${entityConfig.name}.getWhere({ ${dbFieldName}: ... }). Currently only one operator per filter field is supported. Received operators: ${operatorKeys->Js.Array2.joinWith(", ")}.`,
    )
  }

  let operatorKey = operatorKeys->Js.Array2.unsafe_get(0)
  let operator: TableIndices.Operator.t = switch operatorKey {
  | "_eq" => Eq
  | "_gt" => Gt
  | "_lt" => Lt
  | _ =>
    Js.Exn.raiseError(
      `Invalid operator "${operatorKey}" in context.${entityConfig.name}.getWhere({ ${dbFieldName}: { ${operatorKey}: ... } }). Valid operators are _eq, _gt, _lt.`,
    )
  }

  let fieldValue = operatorObj->Js.Dict.unsafeGet(operatorKey)

  switch entityConfig.table->Table.getFieldByDbName(dbFieldName) {
  | None =>
    Js.Exn.raiseError(
      `Invalid field "${dbFieldName}" in context.${entityConfig.name}.getWhere(). The field doesn't exist. ${codegenHelpMessage}`,
    )
  | Some(DerivedFrom(_)) =>
    Js.Exn.raiseError(
      `The field "${dbFieldName}" on entity "${entityConfig.name}" is a derived field and cannot be used in getWhere(). Use the source entity's indexed field instead.`,
    )
  | Some(Field({isIndex: false, linkedEntity: None})) =>
    Js.Exn.raiseError(
      `The field "${dbFieldName}" on entity "${entityConfig.name}" does not have an index. To use it in getWhere(), add the @index directive in your schema.graphql:\n\n  ${dbFieldName}: ... @index\n\nThen run 'pnpm envio codegen' to regenerate.`,
    )
  | Some(Field({fieldSchema})) =>
    LoadLayer.loadByField(
      ~loadManager=params.loadManager,
      ~persistence=params.persistence,
      ~operator,
      ~entityConfig,
      ~fieldName=dbFieldName,
      ~fieldValueSchema=fieldSchema,
      ~inMemoryStore=params.inMemoryStore,
      ~shouldGroup=params.isPreload,
      ~item=params.item,
      ~fieldValue,
    )
  }
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
            Set({
              entityId: entity.id,
              checkpointId: params.checkpointId,
              entity,
            }),
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
    | "getWhere" =>
      ((filter) => getWhereHandler(params, filter->(Utils.magic: unknown => Js.Dict.t<Js.Dict.t<unknown>>)))->Utils.magic
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
            Delete({
              entityId,
              checkpointId: params.checkpointId,
            }),
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
    | "chain" =>
      let chainId = params.item->Internal.getItemChainId
      params.chains->Utils.Dict.dangerouslyGetByIntNonOption(chainId)->Utils.magic
    | _ =>
      switch params.config.userEntitiesByName->Utils.Dict.dangerouslyGetNonOption(prop) {
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
          config: params.config,
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
  onRegister: (~item: Internal.item, ~contractAddress: Address.t, ~contractName: string) => unit,
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
            let validatedAddress = if params.config.ecosystem.name === Evm {
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

            params.onRegister(~item=params.item, ~contractAddress=validatedAddress, ~contractName)
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
