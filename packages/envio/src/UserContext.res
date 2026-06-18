type contextParams = {
  item: Internal.item,
  checkpointId: Internal.checkpointId,
  indexerState: IndexerState.t,
  loadManager: LoadManager.t,
  persistence: Persistence.t,
  isPreload: bool,
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
    // Wrap with toMethod so `this` binds to the EffectContext instance.
    get: Utils.toMethod(() => {
      let params = paramsByThis->Utils.WeakMap.unsafeGet(%raw(`this`))
      Ecosystem.getItemUserLogger(params.item, ~ecosystem=params.config.ecosystem)
    }),
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
      checkpointId: params.checkpointId,
    }
    LoadLayer.loadEffect(
      ~loadManager=params.loadManager,
      ~persistence=params.persistence,
      ~effect,
      ~effectArgs,
      ~indexerState=params.indexerState,
      ~shouldGroup=params.isPreload,
      ~item=params.item,
      ~ecosystem=params.config.ecosystem,
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

  @inline
  let loadWithFilter = filter =>
    LoadLayer.loadByFilter(
      ~loadManager=params.loadManager,
      ~persistence=params.persistence,
      ~entityConfig,
      ~indexerState=params.indexerState,
      ~shouldGroup=params.isPreload,
      ~item=params.item,
      ~ecosystem=params.config.ecosystem,
      ~filter,
    )

  switch filter->EntityFilter.parseGetWhereOrThrow(
    ~entityName=entityConfig.name,
    ~table=entityConfig.table,
  ) {
  | [single] => loadWithFilter(single)
  | filters =>
    filters
    ->Array.map(filter => loadWithFilter(filter))
    ->Promise.all
    ->Promise.thenResolve(results => results->Array.flat)
  }
}

let noopSet = (_entity: Internal.entity) => ()
let noopDeleteUnsafe = (_entityId: string) => ()

// Reads against ClickHouse-only entities have no Postgres table to hit;
// surface a friendly error instead of letting the SQL layer fail with
// "relation does not exist".
let throwClickHouseReadOnly = (entityConfig: Internal.entityConfig, op: string) =>
  JsError.throwWithMessage(
    `context.${entityConfig.name}.${op}() is unavailable: ClickHouse storage is currently write-only. Follow Envio releases to be notified when ClickHouse supports both reads and writes from handlers.`,
  )

let entityTraps: Utils.Proxy.traps<entityContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)

    let isClickHouseOnly = !params.entityConfig.storage.postgres

    let set = params.isPreload
      ? noopSet
      : (entity: Internal.entity) => {
          params.indexerState
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig)
          ->InMemoryTable.Entity.set(
            ~committedCheckpointId=params.indexerState->IndexerState.committedCheckpointId,
            Set({
              entityId: entity.id,
              checkpointId: params.checkpointId,
              entity,
            }),
          )
        }

    switch prop {
    | "get" =>
      if isClickHouseOnly {
        ((_entityId: string) => throwClickHouseReadOnly(params.entityConfig, "get"))->(
          Utils.magic: (string => promise<option<Internal.entity>>) => unknown
        )
      } else {
        (
          entityId =>
            LoadLayer.loadById(
              ~loadManager=params.loadManager,
              ~persistence=params.persistence,
              ~entityConfig=params.entityConfig,
              ~indexerState=params.indexerState,
              ~shouldGroup=params.isPreload,
              ~item=params.item,
              ~ecosystem=params.config.ecosystem,
              ~entityId,
            )
        )->(Utils.magic: (string => promise<option<Internal.entity>>) => unknown)
      }
    | "getWhere" =>
      if isClickHouseOnly {
        ((_filter: unknown) => throwClickHouseReadOnly(params.entityConfig, "getWhere"))->(
          Utils.magic: (unknown => promise<array<Internal.entity>>) => unknown
        )
      } else {
        (
          filter => getWhereHandler(params, filter->(Utils.magic: unknown => dict<dict<unknown>>))
        )->(Utils.magic: (unknown => promise<array<Internal.entity>>) => unknown)
      }

    | "getOrThrow" =>
      if isClickHouseOnly {
        (
          (_entityId: string, ~message as _=?) =>
            throwClickHouseReadOnly(params.entityConfig, "getOrThrow")
        )->(Utils.magic: ((string, ~message: string=?) => promise<Internal.entity>) => unknown)
      } else {
        (
          (entityId, ~message=?) =>
            LoadLayer.loadById(
              ~loadManager=params.loadManager,
              ~persistence=params.persistence,
              ~entityConfig=params.entityConfig,
              ~indexerState=params.indexerState,
              ~shouldGroup=params.isPreload,
              ~item=params.item,
              ~ecosystem=params.config.ecosystem,
              ~entityId,
            )->Promise.thenResolve(entity => {
              switch entity {
              | Some(entity) => entity
              | None =>
                JsError.throwWithMessage(
                  message->Option.getOr(
                    `Entity '${params.entityConfig.name}' with ID '${entityId}' is expected to exist.`,
                  ),
                )
              }
            })
        )->(Utils.magic: ((string, ~message: string=?) => promise<Internal.entity>) => unknown)
      }
    | "getOrCreate" =>
      if isClickHouseOnly {
        (
          (_entity: Internal.entity) => throwClickHouseReadOnly(params.entityConfig, "getOrCreate")
        )->(Utils.magic: (Internal.entity => promise<Internal.entity>) => unknown)
      } else {
        (
          (entity: Internal.entity) =>
            LoadLayer.loadById(
              ~loadManager=params.loadManager,
              ~persistence=params.persistence,
              ~entityConfig=params.entityConfig,
              ~indexerState=params.indexerState,
              ~shouldGroup=params.isPreload,
              ~item=params.item,
              ~ecosystem=params.config.ecosystem,
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
      }
    | "set" => set->(Utils.magic: (Internal.entity => unit) => unknown)
    | "deleteUnsafe" =>
      if params.isPreload {
        noopDeleteUnsafe
      } else {
        entityId => {
          params.indexerState
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig)
          ->InMemoryTable.Entity.set(
            ~committedCheckpointId=params.indexerState->IndexerState.committedCheckpointId,
            Delete({
              entityId,
              checkpointId: params.checkpointId,
            }),
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
      )->ErrorHandling.mkLogAndRaise(
        ~logger=Ecosystem.getItemLogger(params.item, ~ecosystem=params.config.ecosystem),
      )
    }
    switch prop {
    | "log" =>
      (
        params.isPreload
          ? Logging.noopLogger
          : Ecosystem.getItemUserLogger(params.item, ~ecosystem=params.config.ecosystem)
      )->(Utils.magic: Envio.logger => unknown)

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
          indexerState: params.indexerState,
          loadManager: params.loadManager,
          persistence: params.persistence,
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
          `Invalid context access by '${prop}' property. ${EntityFilter.codegenHelpMessage}`,
        )
      }
    }
  },
}

let getHandlerContext = (params: contextParams): Internal.handlerContext => {
  params->Utils.Proxy.make(handlerTraps)->(Utils.magic: contextParams => Internal.handlerContext)
}
