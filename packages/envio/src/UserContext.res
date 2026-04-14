let codegenHelpMessage = `Rerun 'pnpm dev' to update generated code after schema.graphql changes.`

type contextParams = {
  item: Internal.item,
  checkpointId: Internal.checkpointId,
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

let getWhereHandler = (params: entityContextParams, filter: dict<dict<unknown>>) => {
  let entityConfig = params.entityConfig
  let filterKeys = filter->Dict.keysToArray

  if filterKeys->Array.length === 0 {
    JsError.throwWithMessage(
      `Empty filter passed to context.${entityConfig.name}.getWhere(). Please provide a filter like { fieldName: { _eq: value } }.`,
    )
  }
  if filterKeys->Array.length > 1 {
    JsError.throwWithMessage(
      `Multiple filter fields passed to context.${entityConfig.name}.getWhere(). Currently only one filter field per call is supported. Received fields: ${filterKeys->Array.joinUnsafe(
          ", ",
        )}.`,
    )
  }

  let dbFieldName = filterKeys->Array.getUnsafe(0)
  let operatorObj = filter->Dict.getUnsafe(dbFieldName)
  let operatorKeys = operatorObj->Dict.keysToArray

  if operatorKeys->Array.length === 0 {
    JsError.throwWithMessage(
      `Empty operator passed to context.${entityConfig.name}.getWhere({ ${dbFieldName}: {} }). Please provide an operator like { _eq: value }, { _gt: value }, { _lt: value }, { _gte: value }, { _lte: value }, or { _in: [values] }.`,
    )
  }
  if operatorKeys->Array.length > 1 {
    JsError.throwWithMessage(
      `Multiple operators passed to context.${entityConfig.name}.getWhere({ ${dbFieldName}: ... }). Currently only one operator per filter field is supported. Received operators: ${operatorKeys->Array.joinUnsafe(
          ", ",
        )}.`,
    )
  }

  let operatorKey = operatorKeys->Array.getUnsafe(0)

  let fieldSchema = switch entityConfig.table->Table.getFieldByDbName(dbFieldName) {
  | None =>
    JsError.throwWithMessage(
      `Invalid field "${dbFieldName}" in context.${entityConfig.name}.getWhere(). The field doesn't exist. ${codegenHelpMessage}`,
    )
  | Some(DerivedFrom(_)) =>
    JsError.throwWithMessage(
      `The field "${dbFieldName}" on entity "${entityConfig.name}" is a derived field and cannot be used in getWhere(). Use the source entity's indexed field instead.`,
    )
  | Some(Field({isIndex: false, linkedEntity: None})) =>
    JsError.throwWithMessage(
      `The field "${dbFieldName}" on entity "${entityConfig.name}" does not have an index. To use it in getWhere(), add the @index directive in your schema.graphql:\n\n  ${dbFieldName}: ... @index\n\nThen run 'pnpm envio codegen' to regenerate.`,
    )
  | Some(Field({fieldSchema})) => fieldSchema
  }

  if operatorKey === "_in" {
    let fieldValues =
      operatorObj
      ->Dict.getUnsafe(operatorKey)
      ->(Utils.magic: unknown => array<unknown>)

    fieldValues
    ->Array.map(fieldValue =>
      LoadLayer.loadByField(
        ~loadManager=params.loadManager,
        ~persistence=params.persistence,
        ~operator=Eq,
        ~entityConfig,
        ~fieldName=dbFieldName,
        ~fieldValueSchema=fieldSchema,
        ~inMemoryStore=params.inMemoryStore,
        ~shouldGroup=params.isPreload,
        ~item=params.item,
        ~fieldValue,
      )
    )
    ->Promise.all
    ->Promise.thenResolve(results => results->Belt.Array.concatMany)
  } else if operatorKey === "_gte" || operatorKey === "_lte" {
    // _gte and _lte are composed from Eq + Gt/Lt
    let rangeOperator: TableIndices.Operator.t = operatorKey === "_gte" ? Gt : Lt
    let fieldValue = operatorObj->Dict.getUnsafe(operatorKey)

    let loadWithOperator = operator =>
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

    [loadWithOperator(Eq), loadWithOperator(rangeOperator)]
    ->Promise.all
    ->Promise.thenResolve(results => results->Belt.Array.concatMany)
  } else {
    let operator: TableIndices.Operator.t = switch operatorKey {
    | "_eq" => Eq
    | "_gt" => Gt
    | "_lt" => Lt
    | _ =>
      JsError.throwWithMessage(
        `Invalid operator "${operatorKey}" in context.${entityConfig.name}.getWhere({ ${dbFieldName}: { ${operatorKey}: ... } }). Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
      )
    }

    let fieldValue = operatorObj->Dict.getUnsafe(operatorKey)

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
      )->(Utils.magic: (string => promise<option<Internal.entity>>) => unknown)
    | "getWhere" =>
      (filter => getWhereHandler(params, filter->(Utils.magic: unknown => dict<dict<unknown>>)))->(
        Utils.magic: (unknown => promise<array<Internal.entity>>) => unknown
      )
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
              JsError.throwWithMessage(
                message->Belt.Option.getWithDefault(
                  `Entity '${params.entityConfig.name}' with ID '${entityId}' is expected to exist.`,
                ),
              )
            }
          })
      )->(Utils.magic: ((string, ~message: string=?) => promise<Internal.entity>) => unknown)
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
      )->(Utils.magic: (Internal.entity => promise<Internal.entity>) => unknown)
    | "set" => set->(Utils.magic: (Internal.entity => unit) => unknown)
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
      }->(Utils.magic: (string => unit) => unknown)
    | _ =>
      JsError.throwWithMessage(`Invalid context.${params.entityConfig.name}.${prop} operation.`)
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
      (params.isPreload ? Logging.noopLogger : params.item->Logging.getUserLogger)->(
        Utils.magic: Envio.logger => unknown
      )

    | "effect" =>
      initEffect((params :> contextParams))->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      )

    | "isPreload" => params.isPreload->(Utils.magic: bool => unknown)
    | "chain" =>
      let chainId = params.item->Internal.getItemChainId
      params.chains
      ->Utils.Dict.dangerouslyGetByIntNonOption(chainId)
      ->(Utils.magic: option<Internal.chainInfo> => unknown)
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
        ->(Utils.magic: entityContextParams => unknown)
      | None =>
        JsError.throwWithMessage(
          `Invalid context access by '${prop}' property. ${codegenHelpMessage}`,
        )
      }
    }
  },
}

let getHandlerContext = (params: contextParams): Internal.handlerContext => {
  params->Utils.Proxy.make(handlerTraps)->(Utils.magic: contextParams => Internal.handlerContext)
}

// Contract register context creation
type contractRegisterParams = {
  item: Internal.item,
  onRegister: (~item: Internal.item, ~contractAddress: Address.t, ~contractName: string) => unit,
  config: Config.t,
  mutable isResolved: bool,
}

// Helper to create a validated add function for contract registration.
// The isResolved check has to live inside the returned closure (not just in the
// outer proxy trap) because users can capture `const add = context.chain.X.add`
// before awaiting — a later call would otherwise bypass the resolved guard.
let makeAddFunction = (~params: contractRegisterParams, ~contractName: string): (
  Address.t => unit
) => {
  (contractAddress: Address.t) => {
    if params.isResolved {
      Utils.Error.make(`Impossible to access context.chain after the contract register is resolved. Make sure you didn't miss an await in the handler.`)->ErrorHandling.mkLogAndRaise(
        ~logger=params.item->Logging.getItemLogger,
      )
    }
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
}

// Chain proxy for contractRegister context: context.chain.ContractName.add(address)
let contractRegisterChainTraps: Utils.Proxy.traps<contractRegisterParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    switch prop {
    | "id" =>
      let eventItem = params.item->Internal.castUnsafeEventItem
      eventItem.chain->ChainMap.Chain.toChainId->(Utils.magic: int => unknown)
    | _ =>
      // Look up the contract name directly in config contracts across all chains.
      let contractName = prop
      let isValidContract =
        params.config.chainMap
        ->ChainMap.values
        ->Array.some(chain => chain.contracts->Array.some(c => c.name === contractName))
      if isValidContract {
        let addFn = makeAddFunction(~params, ~contractName)
        {"add": addFn}->(Utils.magic: {"add": Address.t => unit} => unknown)
      } else {
        JsError.throwWithMessage(
          `Invalid contract name '${prop}' on context.chain. ${codegenHelpMessage}`,
        )
      }
    }
  },
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
    | "log" => params.item->Logging.getUserLogger->(Utils.magic: Envio.logger => unknown)
    | "chain" =>
      params
      ->Utils.Proxy.make(contractRegisterChainTraps)
      ->(Utils.magic: contractRegisterParams => unknown)
    | _ =>
      JsError.throwWithMessage(
        `Invalid context access by '${prop}' property. Use context.chain.ContractName.add(address) to register contracts. ${codegenHelpMessage}`,
      )
    }
  },
}

let getContractRegisterContext = (params: contractRegisterParams) => {
  params
  ->Utils.Proxy.make(contractRegisterTraps)
  ->(Utils.magic: contractRegisterParams => Internal.contractRegisterContext)
}

let getContractRegisterArgs = (params: contractRegisterParams): Internal.contractRegisterArgs => {
  event: (params.item->Internal.castUnsafeEventItem).event,
  context: getContractRegisterContext(params),
}
