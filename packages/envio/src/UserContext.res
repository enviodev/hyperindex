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

let effectContextPrototype = %raw(`Object.create(null)`)
Utils.Object.defineProperty(
  effectContextPrototype,
  "log",
  {
    // Wrap with toMethod so `this` binds to the EffectContext instance.
    get: Utils.toMethod(() => ConsoleScope.effectLogger(%raw(`this`))()->Logger.asContextLog),
  },
)
%%raw(`
// Top-level so the getter is created once, not per context. \`this\` is the
// EffectContext instance; only cross-chain contexts install it.
function throwCrossChainChainAccess() {
  throw new Error('context.chain is not available on the cross-chain effect "' + this._effectName + '". Set \`crossChain: false\` in its options to scope the effect to a single chain, then read context.chain.id.');
}
var crossChainChainDescriptor = { get: throwCrossChainChainAccess, enumerable: true };
var EffectContext = function(chainId, effectName, defaultShouldCache, callEffect) {
  this.effect = callEffect;
  this.cache = defaultShouldCache;
  if (chainId === undefined) {
    // Cross-chain: reading context.chain throws, via the shared getter.
    Object.defineProperty(this, "_effectName", { value: effectName });
    Object.defineProperty(this, "chain", crossChainChainDescriptor);
  } else {
    this.chain = { id: chainId };
  }
};
EffectContext.prototype = effectContextPrototype;
`)

@new
external makeEffectContext: (
  ~chainId: option<ChainId.t>,
  ~effectName: string,
  ~defaultShouldCache: bool,
  ~callEffect: (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>,
) => Internal.effectContext = "EffectContext"

let initEffect = (params: contextParams) => {
  let handlerChainId = params.item->Internal.getItemChainId
  // An effect that didn't state a scope follows the config: cross-chain by
  // default, per-chain under `disable_default_cross_chain`.
  let isCrossChain = (effect: Internal.effect) =>
    effect.crossChain->Option.getOr(params.config.defaultCrossChain)
  // A chain-scoped effect always resolves against the chain of the handler that
  // triggered the call, even several effects deep, so the chain id is captured
  // once from the item and reused for the whole nested-call tree.
  let rec makeCaller = (~caller: option<Internal.effect>) => {
    (effect: Internal.effect, input: Internal.effectInput) => {
      let scope = effect->isCrossChain ? Internal.CrossChain : Internal.Chain(handlerChainId)

      switch caller {
      | Some(callerEffect) if callerEffect->isCrossChain && !(effect->isCrossChain) =>
        // A cross-chain effect isn't tied to a single chain, so it has no chain
        // to resolve a chain-scoped child against. Reject before any cache work.
        JsError.throwWithMessage(
          `The cross-chain effect "${callerEffect.name}" cannot call the chain-scoped effect "${effect.name}", because a cross-chain effect isn't tied to a single chain. Make "${effect.name}" cross-chain (\`crossChain: true\`), or make "${callerEffect.name}" chain-scoped (\`crossChain: false\`).`,
        )
      | _ => ()
      }

      let effectContext = makeEffectContext(
        ~chainId=switch scope {
        | Internal.Chain(chainId) => Some(chainId)
        | Internal.CrossChain => None
        },
        ~effectName=effect.name,
        ~defaultShouldCache=effect.defaultShouldCache,
        ~callEffect=makeCaller(~caller=Some(effect)),
      )
      let effectArgs: Internal.effectArgs = {
        input,
        context: effectContext,
        cacheKey: input->S.reverseConvertOrThrow(effect.input)->Utils.Hash.makeOrThrow,
        chainId: handlerChainId,
        checkpointId: params.checkpointId,
      }
      effectContext->ConsoleScope.setEffectLogger(() =>
        params.indexerState
        ->IndexerState.loggerForItem(params.item)
        ->Logger.withFields({"effect": effect.name})
      )
      LoadLayer.loadEffect(
        ~loadManager=params.loadManager,
        ~persistence=params.persistence,
        ~effect,
        ~effectArgs,
        ~scope,
        ~indexerState=params.indexerState,
        ~shouldGroup=params.isPreload,
      )
    }
  }
  makeCaller(~caller=None)
}

type entityContextParams = {
  ...contextParams,
  entityConfig: Internal.entityConfig,
}

// The handler context is always chain-scoped, so a per-chain entity resolves to
// the chain the handler runs on and a cross-chain one to the shared partition.
let entityScope = (params: entityContextParams) =>
  params.entityConfig->InMemoryStore.entityScope(~chainId=params.item->Internal.getItemChainId)

let getWhereHandler = (params: entityContextParams, filter: dict<dict<unknown>>) =>
  LoadLayer.loadByFilter(
    ~loadManager=params.loadManager,
    ~persistence=params.persistence,
    ~entityConfig=params.entityConfig,
    ~scope=params->entityScope,
    ~indexerState=params.indexerState,
    ~shouldGroup=params.isPreload,
    ~filter,
  )

let noopSet = (_entity: Internal.entity) => ()
let noopDeleteUnsafe = (_entityId: EntityId.t) => ()

// A TTL drops an entity's rows whenever ClickHouse merges them, so for one kept
// there alone a read would turn on merge timing rather than on the events.
let expiresUnread = (entityConfig: Internal.entityConfig) =>
  !entityConfig.storage.postgres &&
  entityConfig.storage.clickhouseOptions
  ->Option.flatMap(options => options.ttl)
  ->Option.isSome

let entityTraps: Utils.Proxy.traps<entityContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)

    switch prop {
    | "get" | "getWhere" | "getOrThrow" | "getOrCreate" if params.entityConfig->expiresUnread =>
      let {name} = params.entityConfig
      JsError.throwWithMessage(
        `context.${name}.${prop}() is unavailable: ${name} is kept in ClickHouse alone with a ttl, which drops its rows whenever ClickHouse merges them, so a handler would read it differently from one run to the next. Keep it in Postgres too, with @storage(postgres: true, clickhouse: {...}), or drop the ttl.`,
      )
    | _ => ()
    }

    let scope = params->entityScope
    let committedCheckpointId = params.indexerState->IndexerState.committedCheckpointIdFor(~scope)

    let set = params.isPreload
      ? noopSet
      : (entity: Internal.entity) => {
          params.indexerState
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig, ~scope)
          ->InMemoryTable.Entity.set(
            ~committedCheckpointId,
            Set({
              entityId: entity.id->EntityId.unsafeOfString,
              checkpointId: params.checkpointId,
              entity,
            }),
          )
        }

    let loadById = entityId =>
      LoadLayer.loadById(
        ~loadManager=params.loadManager,
        ~persistence=params.persistence,
        ~entityConfig=params.entityConfig,
        ~scope,
        ~indexerState=params.indexerState,
        ~shouldGroup=params.isPreload,
        ~entityId,
      )

    switch prop {
    | "get" => loadById->(Utils.magic: (string => promise<option<Internal.entity>>) => unknown)
    | "getWhere" =>
      (filter => getWhereHandler(params, filter->(Utils.magic: unknown => dict<dict<unknown>>)))->(
        Utils.magic: (unknown => promise<array<Internal.entity>>) => unknown
      )

    | "getOrThrow" =>
      (
        (entityId, ~message=?) =>
          loadById(entityId)->Promise.thenResolve(entity => {
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
    | "getOrCreate" =>
      (
        (entity: Internal.entity) =>
          loadById(entity.id)->Promise.thenResolve(storageEntity => {
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
          params.indexerState
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig, ~scope)
          ->InMemoryTable.Entity.set(
            ~committedCheckpointId,
            Delete({
              entityId,
              checkpointId: params.checkpointId,
            }),
          )
        }
      }->(Utils.magic: (EntityId.t => unit) => unknown)
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
        ~logger=params.indexerState->IndexerState.loggerForItem(params.item),
      )
    }
    switch prop {
    | "log" =>
      (
        params.isPreload
          ? Logger.silentContextLog
          : params.indexerState->IndexerState.loggerForItem(params.item)->Logger.asContextLog
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
      ->ChainId.Dict.dangerouslyGetNonOption(chainId)
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
