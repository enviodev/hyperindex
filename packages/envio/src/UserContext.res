// What every handler run of one batch pass shares. The run itself — its item
// and checkpoint — is read from the ConsoleScope frame it was entered with, so
// one context object serves every run of the pass, concurrent ones included.
type batchParams = {
  indexerState: IndexerState.t,
  loadManager: LoadManager.t,
  persistence: Persistence.t,
  isPreload: bool,
  chains: Internal.chains,
  config: Config.t,
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

let initEffect = (params: batchParams, ~frame: ConsoleScope.handlerFrame) => {
  let handlerChainId = frame.item->Internal.getItemChainId
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
        checkpointId: frame.checkpointId,
      }
      effectContext->ConsoleScope.setEffectLogger(() =>
        params.indexerState
        ->IndexerState.loggerForItem(frame.item)
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

// The run a context call belongs to. Work a handler starts without awaiting
// keeps its run's frame, so it is caught here once the run has resolved. A
// preload run's calls stay harmless after it resolves: its writes are no-ops.
let currentFrame = (params: batchParams, ~prop) =>
  switch ConsoleScope.current()->Nullable.toOption {
  | Some(Handler(frame)) =>
    if frame.isResolved && !frame.isPreload {
      Utils.Error.make(
        `Impossible to access context.${prop} after the handler is resolved. Make sure you didn't miss an await in the handler.`,
      )->ErrorHandling.mkLogAndRaise(
        ~logger=params.indexerState->IndexerState.loggerForItem(frame.item),
      )
    }
    frame
  | Some(Logger(_)) | None =>
    JsError.throwWithMessage(
      `Impossible to access context.${prop} outside of the handler it was passed to.`,
    )
  }

let noopSet = (_entity: Internal.entity) => ()
let noopDeleteUnsafe = (_entityId: EntityId.t) => ()

// Reads against ClickHouse-only entities have no Postgres table to hit;
// surface a friendly error instead of letting the SQL layer fail with
// "relation does not exist".
let throwClickHouseReadOnly = (entityConfig: Internal.entityConfig, op: string) =>
  JsError.throwWithMessage(
    `context.${entityConfig.name}.${op}() is unavailable: ClickHouse storage is currently write-only. Follow Envio releases to be notified when ClickHouse supports both reads and writes from handlers.`,
  )

type prototype

// A prototype that names the property a context doesn't have. Only reached for
// properties the context itself lacks, so the ones it has cost nothing extra.
let makeStrictPrototype: (string => unit) => prototype = %raw(`function (onUnknown) {
  return new Proxy(Object.create(null), {
    get(_target, prop) {
      if (typeof prop === "string") onUnknown(prop);
      return undefined;
    },
  });
}`)

@val @scope("Object") external createWithPrototype: prototype => 'a = "create"
@val @scope("Object")
external assignEntityContext: ('entityContext, 'entityContext) => 'entityContext = "assign"

type entityContext = {
  get: string => promise<option<Internal.entity>>,
  getWhere: dict<dict<unknown>> => promise<array<Internal.entity>>,
  getOrThrow: (string, ~message: string=?) => promise<Internal.entity>,
  getOrCreate: Internal.entity => promise<Internal.entity>,
  set: Internal.entity => unit,
  deleteUnsafe: EntityId.t => unit,
}

let makeEntityContext = (params: batchParams, ~entityConfig: Internal.entityConfig) => {
  let prop = entityConfig.name
  // The handler context is always chain-scoped, so a per-chain entity resolves
  // to the chain the handler runs on and a cross-chain one to the shared
  // partition.
  let scopeOf = (frame: ConsoleScope.handlerFrame) =>
    entityConfig->InMemoryStore.entityScope(~chainId=frame.item->Internal.getItemChainId)

  // A row already in memory is final for both passes, so it skips the load
  // manager: grouping it with the batch's loads would only resolve it a tick
  // later to the same value.
  let loadById = (entityId: string) => {
    let scope = params->currentFrame(~prop)->scopeOf
    switch (
      params.indexerState->InMemoryStore.getInMemTable(~entityConfig, ~scope)
    ).latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(change) => Promise.resolve(change->InMemoryTable.Entity.mapChangeToEntity)
    | None =>
      LoadLayer.loadById(
        ~loadManager=params.loadManager,
        ~persistence=params.persistence,
        ~entityConfig,
        ~scope,
        ~indexerState=params.indexerState,
        ~shouldGroup=params.isPreload,
        ~entityId,
      )
    }
  }

  let write = (change: Change.t<Internal.entity>, ~scope) =>
    params.indexerState
    ->InMemoryStore.getInMemTable(~entityConfig, ~scope)
    ->InMemoryTable.Entity.set(
      ~committedCheckpointId=params.indexerState->IndexerState.committedCheckpointIdFor(~scope),
      change,
    )

  let set = params.isPreload
    ? noopSet
    : (entity: Internal.entity) => {
        let frame = params->currentFrame(~prop)
        write(
          Set({
            entityId: entity.id->EntityId.unsafeOfString,
            checkpointId: frame.checkpointId,
            entity,
          }),
          ~scope=frame->scopeOf,
        )
      }

  let deleteUnsafe = params.isPreload
    ? noopDeleteUnsafe
    : entityId => {
        let frame = params->currentFrame(~prop)
        write(Delete({entityId, checkpointId: frame.checkpointId}), ~scope=frame->scopeOf)
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
      getWhere: filter =>
        LoadLayer.loadByFilter(
          ~loadManager=params.loadManager,
          ~persistence=params.persistence,
          ~entityConfig,
          ~scope=params->currentFrame(~prop)->scopeOf,
          ~indexerState=params.indexerState,
          ~shouldGroup=params.isPreload,
          ~filter,
        ),
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

  let strict: entityContext = createWithPrototype(
    makeStrictPrototype(op =>
      JsError.throwWithMessage(`Invalid context.${entityConfig.name}.${op} operation.`)
    ),
  )
  strict->assignEntityContext(entityContext)
}

// One context for every handler run of a batch pass.
let makeHandlerContext = (params: batchParams): Internal.handlerContext => {
  let context = createWithPrototype(
    makeStrictPrototype(prop =>
      JsError.throwWithMessage(
        `Invalid context access by '${prop}' property. ${EntityFilter.codegenHelpMessage}`,
      )
    ),
  )
  let define = (name, get) =>
    context
    ->Utils.Object.defineProperty(
      name,
      {enumerable: true, get: () => get(currentFrame(params, ~prop=name))},
    )
    ->ignore

  define("log", (frame: ConsoleScope.handlerFrame) =>
    (
      params.isPreload
        ? Logger.silentContextLog
        : params.indexerState->IndexerState.loggerForItem(frame.item)->Logger.asContextLog
    )->(Utils.magic: Envio.logger => unknown)
  )
  define("effect", frame =>
    initEffect(params, ~frame)->(
      Utils.magic: (
        (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
      ) => unknown
    )
  )
  define("isPreload", _ => params.isPreload->(Utils.magic: bool => unknown))
  define("chain", frame =>
    params.chains
    ->ChainId.Dict.dangerouslyGetNonOption(frame.item->Internal.getItemChainId)
    ->(Utils.magic: option<Internal.chainInfo> => unknown)
  )
  params.config.userEntitiesByName->Utils.Dict.forEachWithKey((entityConfig, name) => {
    let entityContext =
      params->makeEntityContext(~entityConfig)->(Utils.magic: entityContext => unknown)
    define(name, _ => entityContext)
  })
  context
}
