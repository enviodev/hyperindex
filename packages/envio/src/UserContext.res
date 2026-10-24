// What every handler run of an indexer shares. The run itself — its item,
// checkpoint and whether it's a preload — is read from the RunScope it was
// entered with, so one context object serves every run, concurrent ones and
// both passes included.
type params = {
  indexerState: IndexerState.t,
  loadManager: LoadManager.t,
  persistence: Persistence.t,
  config: Config.t,
  // Refreshed by HandlerRuntime when a batch changes it.
  mutable chains: Internal.chains,
}

let effectContextPrototype = %raw(`Object.create(null)`)
Utils.Object.defineProperty(
  effectContextPrototype,
  "log",
  {
    // Wrap with toMethod so `this` binds to the EffectContext instance.
    get: Utils.toMethod(() =>
      %raw(`this`)->RunScope.effectRunOf->RunScope.effectLogger->Logger.asContextLog
    ),
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

let initEffect = (params: params, ~run: RunScope.handlerRun) => {
  let handlerChainId = run.item->Internal.getItemChainId
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
      effectContext->RunScope.attachEffectRun({caller: run, effectName: effect.name})
      LoadLayer.loadEffect(
        ~loadManager=params.loadManager,
        ~persistence=params.persistence,
        ~effect,
        ~effectArgs={
          input,
          context: effectContext,
          cacheKey: input->S.reverseConvertOrThrow(effect.input)->Utils.Hash.makeOrThrow,
          chainId: handlerChainId,
          checkpointId: run.checkpointId,
        },
        ~scope,
        ~indexerState=params.indexerState,
        ~shouldGroup=run.isPreload,
      )
    }
  }
  makeCaller(~caller=None)
}

// Reads against ClickHouse-only entities have no Postgres table to hit;
// surface a friendly error instead of letting the SQL layer fail with
// "relation does not exist".
let throwClickHouseReadOnly = (entityConfig: Internal.entityConfig, op: string) =>
  JsError.throwWithMessage(
    `context.${entityConfig.name}.${op}() is unavailable: ClickHouse storage is currently write-only. Follow Envio releases to be notified when ClickHouse supports both reads and writes from handlers.`,
  )

type entityContext = {
  get: string => promise<option<Internal.entity>>,
  getWhere: dict<dict<unknown>> => promise<array<Internal.entity>>,
  getOrThrow: (string, ~message: string=?) => promise<Internal.entity>,
  getOrCreate: Internal.entity => promise<Internal.entity>,
  set: Internal.entity => unit,
  deleteUnsafe: EntityId.t => unit,
}

let makeEntityContext = (params: params, ~entityConfig: Internal.entityConfig) => {
  let prop = entityConfig.name
  // The handler context is always chain-scoped, so a per-chain entity resolves
  // to the chain the handler runs on and a cross-chain one to the shared
  // partition.
  let scopeOf = (run: RunScope.handlerRun) =>
    entityConfig->InMemoryStore.entityScope(~chainId=run.item->Internal.getItemChainId)

  let loadById = entityId => {
    let run = RunScope.currentHandlerRunOrThrow(~prop)
    LoadLayer.loadById(
      ~loadManager=params.loadManager,
      ~persistence=params.persistence,
      ~entityConfig,
      ~scope=run->scopeOf,
      ~indexerState=params.indexerState,
      ~shouldGroup=run.isPreload,
      ~entityId,
    )
  }

  let write = (run, change: Change.t<Internal.entity>) => {
    let scope = run->scopeOf
    params.indexerState
    ->InMemoryStore.getInMemTable(~entityConfig, ~scope)
    ->InMemoryTable.Entity.set(
      ~committedCheckpointId=params.indexerState->IndexerState.committedCheckpointIdFor(~scope),
      change,
    )
  }

  // A preload run's writes are no-ops: its run proper makes them.
  let set = (entity: Internal.entity) => {
    let run = RunScope.currentHandlerRunOrThrow(~prop)
    if !run.isPreload {
      run->write(
        Set({
          entityId: entity.id->EntityId.unsafeOfString,
          checkpointId: run.checkpointId,
          entity,
        }),
      )
    }
  }

  let deleteUnsafe = entityId => {
    let run = RunScope.currentHandlerRunOrThrow(~prop)
    if !run.isPreload {
      run->write(Delete({entityId, checkpointId: run.checkpointId}))
    }
  }

  let entityContext: entityContext = if !entityConfig.storage.postgres {
    {
      get: _ => throwClickHouseReadOnly(entityConfig, "get"),
      getWhere: _ => throwClickHouseReadOnly(entityConfig, "getWhere"),
      getOrThrow: (_, ~message as _=?) => throwClickHouseReadOnly(entityConfig, "getOrThrow"),
      getOrCreate: _ => throwClickHouseReadOnly(entityConfig, "getOrCreate"),
      set,
      deleteUnsafe,
    }
  } else {
    {
      get: loadById,
      getWhere: filter => {
        let run = RunScope.currentHandlerRunOrThrow(~prop)
        LoadLayer.loadByFilter(
          ~loadManager=params.loadManager,
          ~persistence=params.persistence,
          ~entityConfig,
          ~scope=run->scopeOf,
          ~indexerState=params.indexerState,
          ~shouldGroup=run.isPreload,
          ~filter,
        )
      },
      getOrThrow: (entityId, ~message=?) =>
        loadById(entityId)->Promise.thenResolve(entity =>
          switch entity {
          | Some(entity) => entity
          | None =>
            JsError.throwWithMessage(
              message->Option.getOr(
                `Entity '${entityConfig.name}' with ID '${entityId}' is expected to exist.`,
              ),
            )
          }
        ),
      getOrCreate: entity =>
        loadById(entity.id)->Promise.thenResolve(storageEntity =>
          switch storageEntity {
          | Some(entity) => entity
          | None =>
            set(entity)
            entity
          }
        ),
      set,
      deleteUnsafe,
    }
  }

  Utils.StrictObject.make(
    Utils.StrictObject.makePrototype(op =>
      JsError.throwWithMessage(`Invalid context.${entityConfig.name}.${op} operation.`)
    ),
  )->Utils.StrictObject.assign(entityContext)
}

// One context for every handler run of an indexer.
let makeHandlerContext = (params: params): Internal.handlerContext => {
  let context = Utils.StrictObject.make(
    Utils.StrictObject.makePrototype(prop =>
      JsError.throwWithMessage(
        `Invalid context access by '${prop}' property. ${EntityFilter.codegenHelpMessage}`,
      )
    ),
  )
  let define = (name, get) =>
    context
    ->Utils.Object.defineProperty(
      name,
      {enumerable: true, get: () => get(RunScope.currentHandlerRunOrThrow(~prop=name))},
    )
    ->ignore

  define("log", (run: RunScope.handlerRun) =>
    (run.isPreload ? Logger.silentContextLog : run->RunScope.handlerLogger->Logger.asContextLog)->(
      Utils.magic: Envio.logger => unknown
    )
  )
  define("effect", run =>
    initEffect(params, ~run)->(
      Utils.magic: (
        (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
      ) => unknown
    )
  )
  define("isPreload", run => run.isPreload->(Utils.magic: bool => unknown))
  define("chain", run =>
    params.chains
    ->ChainId.Dict.dangerouslyGetNonOption(run.item->Internal.getItemChainId)
    ->(Utils.magic: option<Internal.chainInfo> => unknown)
  )
  params.config.userEntitiesByName->Utils.Dict.forEachWithKey((entityConfig, name) => {
    let entityContext =
      params->makeEntityContext(~entityConfig)->(Utils.magic: entityContext => unknown)
    define(name, _ => entityContext)
  })
  context
}
