// Thrown by a sync op that can't be served from memory. Owned by envio so the
// subgraph runtime's replay loop can tell it apart from a real handler error.
// User code never swallows it: AssemblyScript has no try/catch, and the traps
// keep re-throwing it while the context stays aborted.
exception Suspend

let isSuspend = exn =>
  switch exn {
  | Suspend => true
  | _ => false
  }

type contextStatus =
  | Active
  // Set by a suspended sync op. Every trap access and every op closure
  // re-throws the stored error, so even a caught suspend stops the handler
  // at its next context interaction.
  | Aborted(exn)
  | Resolved

// Held by reference so the entity sub-proxies, which copy the rest of the
// params by value, observe the same lifecycle as the handler context.
type syncState = {
  mutable status: contextStatus,
  // Ops scheduled by this round's suspended reads, awaited before the replay.
  mutable pending: option<array<promise<unit>>>,
  // Effect outputs already resolved for this handler invocation. Replay rounds
  // and the preload -> execute transition reuse them even when the in-memory
  // effect table drops the entry (`cache: false`).
  mutable memo: option<dict<Internal.effectOutput>>,
}

let makeSyncState = () => {status: Active, pending: None, memo: None}

type contextParams = {
  item: Internal.item,
  checkpointId: Internal.checkpointId,
  indexerState: IndexerState.t,
  loadManager: LoadManager.t,
  persistence: Persistence.t,
  isPreload: bool,
  chains: Internal.chains,
  config: Config.t,
  sync: syncState,
}

let getPending = (sync: syncState) =>
  switch sync.pending {
  | Some(pending) => pending
  | None =>
    let pending = []
    sync.pending = Some(pending)
    pending
  }

let getMemo = (sync: syncState) =>
  switch sync.memo {
  | Some(memo) => memo
  | None =>
    let memo = Dict.make()
    sync.memo = Some(memo)
    memo
  }

let checkStatusOrThrow = (params: contextParams, ~access: string) =>
  switch params.sync.status {
  | Active => ()
  | Aborted(exn) => throw(exn)
  | Resolved =>
    Utils.Error.make(
      `Impossible to access ${access} after the handler is resolved. Make sure you didn't miss an await in the handler.`,
    )->ErrorHandling.mkLogAndRaise(
      ~logger=Ecosystem.getItemLogger(params.item, ~ecosystem=params.config.ecosystem),
    )
  }

// Fires the async op behind a sync miss, records it for the replay loop and
// aborts the context.
let scheduleAndSuspend = (params: contextParams, promise: promise<'a>): 'b => {
  params.sync->getPending->Array.push(promise->Utils.Promise.ignoreValue)
  params.sync.status = Aborted(Suspend)
  throw(Suspend)
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
// Top-level so the getter is created once, not per context. \`this\` is the
// EffectContext instance; only cross-chain contexts install it.
function throwCrossChainChainAccess() {
  throw new Error('context.chain is not available on the cross-chain effect "' + this._effectName + '". Set \`crossChain: false\` in its options to scope the effect to a single chain, then read context.chain.id.');
}
var crossChainChainDescriptor = { get: throwCrossChainChainAccess, enumerable: true };
var EffectContext = function(params, chainId, effectName, defaultShouldCache, callEffect) {
  paramsByThis.set(this, params);
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
  contextParams,
  ~chainId: option<ChainId.t>,
  ~effectName: string,
  ~defaultShouldCache: bool,
  ~callEffect: (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>,
) => Internal.effectContext = "EffectContext"

// Builds the scope and args a call to `effect` resolves against. Split out of
// `initEffect` so the sync caller derives the same cache key and scope without
// duplicating the nested-caller rules.
let rec prepareEffectCall = (
  params: contextParams,
  ~effect: Internal.effect,
  ~input: Internal.effectInput,
  ~caller: option<Internal.effect>,
) => {
  // An effect that didn't state a scope follows the config: cross-chain by
  // default, per-chain under `disable_default_cross_chain`.
  let isCrossChain = (effect: Internal.effect) =>
    effect.crossChain->Option.getOr(params.config.defaultCrossChain)
  // A chain-scoped effect always resolves against the chain of the handler that
  // triggered the call, even several effects deep, so the chain id is captured
  // once from the item and reused for the whole nested-call tree.
  let scope = effect->isCrossChain
    ? Internal.CrossChain
    : Internal.Chain(params.item->Internal.getItemChainId)

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
    params,
    ~chainId=switch scope {
    | Internal.Chain(chainId) => Some(chainId)
    | Internal.CrossChain => None
    },
    ~effectName=effect.name,
    ~defaultShouldCache=effect.defaultShouldCache,
    // Nested calls made by the effect handler itself stay async: only the
    // handler that started the sync run needs a sync answer.
    ~callEffect=(nested, nestedInput) =>
      params->callEffectAsync(~effect=nested, ~input=nestedInput, ~caller=Some(effect)),
  )
  let effectArgs: Internal.effectArgs = {
    input,
    context: effectContext,
    cacheKey: input->S.reverseConvertOrThrow(effect.input)->Utils.Hash.makeOrThrow,
    checkpointId: params.checkpointId,
  }
  (scope, effectArgs)
}

and callEffectAsync = (params: contextParams, ~effect, ~input, ~caller) => {
  let (scope, effectArgs) = params->prepareEffectCall(~effect, ~input, ~caller)
  LoadLayer.loadEffect(
    ~loadManager=params.loadManager,
    ~persistence=params.persistence,
    ~effect,
    ~effectArgs,
    ~scope,
    ~indexerState=params.indexerState,
    ~shouldGroup=params.isPreload,
    ~item=params.item,
    ~ecosystem=params.config.ecosystem,
  )
}

let initEffect = (params: contextParams) => {
  (effect: Internal.effect, input: Internal.effectInput) => {
    params->checkStatusOrThrow(~access="context.effect")
    params->callEffectAsync(~effect, ~input, ~caller=None)
  }
}

let effectMemoKey = (~effect: Internal.effect, ~scope: Internal.chainScope, ~cacheKey) =>
  switch scope {
  | CrossChain => `${effect.name}.${cacheKey}`
  | Chain(chainId) => `${effect.name}.${chainId->ChainId.toString}.${cacheKey}`
  }

let initEffectSync = (params: contextParams) => {
  (effect: Internal.effect, input: Internal.effectInput) => {
    params->checkStatusOrThrow(~access="context.effectSync")
    let (scope, effectArgs) = params->prepareEffectCall(~effect, ~input, ~caller=None)
    let memo = params.sync->getMemo
    let memoKey = effectMemoKey(~effect, ~scope, ~cacheKey=effectArgs.cacheKey)
    switch memo->Utils.Dict.dangerouslyGetNonOption(memoKey) {
    | Some(output) => output
    | None =>
      let inMemTable = params.indexerState->InMemoryStore.getEffectInMemTable(~effect, ~scope)
      if inMemTable->InMemoryStore.hasEffectOutput(effectArgs.cacheKey) {
        let output = inMemTable->InMemoryStore.getEffectOutputUnsafe(effectArgs.cacheKey)
        memo->Dict.set(memoKey, output)
        output
      } else {
        params->scheduleAndSuspend(
          LoadLayer.loadEffect(
            ~loadManager=params.loadManager,
            ~persistence=params.persistence,
            ~effect,
            ~effectArgs,
            ~scope,
            ~indexerState=params.indexerState,
            ~shouldGroup=params.isPreload,
            ~item=params.item,
            ~ecosystem=params.config.ecosystem,
          ),
        )
      }
    }
  }
}

type entityContextParams = {
  ...contextParams,
  entityConfig: Internal.entityConfig,
}

// The handler context is always chain-scoped, so a per-chain entity resolves to
// the chain the handler runs on and a cross-chain one to the shared partition.
let entityScope = (params: entityContextParams) =>
  params.entityConfig->InMemoryStore.entityScope(
    ~chainId=params.item->Internal.getItemChainId,
  )

let getWhereHandler = (params: entityContextParams, filter: dict<dict<unknown>>) => {
  let entityConfig = params.entityConfig

  @inline
  let loadWithFilter = filter =>
    LoadLayer.loadByFilter(
      ~loadManager=params.loadManager,
      ~persistence=params.persistence,
      ~entityConfig,
      ~scope=params->entityScope,
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
let noopDeleteUnsafe = (_entityId: EntityId.t) => ()

// Reads against ClickHouse-only entities have no Postgres table to hit;
// surface a friendly error instead of letting the SQL layer fail with
// "relation does not exist".
let throwClickHouseReadOnly = (entityConfig: Internal.entityConfig, op: string) =>
  JsError.throwWithMessage(
    `context.${entityConfig.name}.${op}() is unavailable: ClickHouse storage is currently write-only. Follow Envio releases to be notified when ClickHouse supports both reads and writes from handlers.`,
  )

// A sync read against the in-memory entity table: a hit is returned as-is
// (including a recorded absence), a miss schedules the async load and suspends.
let getSyncHandler = (params: entityContextParams, entityId: string) => {
  let inMemTable =
    params.indexerState->InMemoryStore.getInMemTable(
      ~entityConfig=params.entityConfig,
      ~scope=params->entityScope,
    )
  if inMemTable.latestEntityChangeById->Dict.has(entityId) {
    (inMemTable->InMemoryTable.Entity.getUnsafe)(entityId)
  } else {
    (params :> contextParams)->scheduleAndSuspend(
      LoadLayer.loadById(
        ~loadManager=params.loadManager,
        ~persistence=params.persistence,
        ~entityConfig=params.entityConfig,
        ~scope=params->entityScope,
        ~indexerState=params.indexerState,
        ~shouldGroup=params.isPreload,
        ~item=params.item,
        ~ecosystem=params.config.ecosystem,
        ~entityId,
      ),
    )
  }
}

let getWhereSyncHandler = (params: entityContextParams, filter: dict<dict<unknown>>) => {
  let entityConfig = params.entityConfig
  let inMemTable =
    params.indexerState->InMemoryStore.getInMemTable(~entityConfig, ~scope=params->entityScope)
  let hasIndex = inMemTable->InMemoryTable.Entity.hasIndex
  let getOnIndex = inMemTable->InMemoryTable.Entity.getUnsafeOnIndex

  let filters =
    filter->EntityFilter.parseGetWhereOrThrow(
      ~entityName=entityConfig.name,
      ~table=entityConfig.table,
    )

  let missing = []
  let entities = []
  filters->Array.forEach(filter => {
    let filterKey = filter->EntityFilter.toString
    if hasIndex(filterKey) {
      entities->Array.pushMany(getOnIndex(filterKey))
    } else {
      missing->Array.push(
        LoadLayer.loadByFilter(
          ~loadManager=params.loadManager,
          ~persistence=params.persistence,
          ~entityConfig,
          ~scope=params->entityScope,
          ~indexerState=params.indexerState,
          ~shouldGroup=params.isPreload,
          ~item=params.item,
          ~ecosystem=params.config.ecosystem,
          ~filter,
        )->Utils.Promise.ignoreValue,
      )
    }
  })

  if missing->Utils.Array.notEmpty {
    let pending = params.sync->getPending
    missing->Array.forEach(promise => pending->Array.push(promise))
    params.sync.status = Aborted(Suspend)
    throw(Suspend)
  }
  entities
}

// Never suspends: the in-memory table spans the whole batch, so a change only
// counts as "in this block" when it was written at this handler's checkpoint.
let getInBlockSyncHandler = (params: entityContextParams, entityId: string) => {
  let inMemTable =
    params.indexerState->InMemoryStore.getInMemTable(
      ~entityConfig=params.entityConfig,
      ~scope=params->entityScope,
    )
  switch inMemTable.latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(entityId) {
  | Some(change) if change->Change.getCheckpointId == params.checkpointId =>
    change->InMemoryTable.Entity.mapChangeToEntity
  | _ => None
  }
}

let entityTraps: Utils.Proxy.traps<entityContextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)

    (params :> contextParams)->checkStatusOrThrow(
      ~access=`context.${params.entityConfig.name}.${prop}`,
    )

    let isClickHouseOnly = !params.entityConfig.storage.postgres

    let set = params.isPreload
      ? noopSet
      : (entity: Internal.entity) => {
          // The check lives inside the closure too: a handler that grabbed
          // `context.X.set` before a suspend must not keep writing.
          (params :> contextParams)->checkStatusOrThrow(
            ~access=`context.${params.entityConfig.name}.set`,
          )
          params.indexerState
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig, ~scope=params->entityScope)
          ->InMemoryTable.Entity.set(
            ~committedCheckpointId=params.indexerState->IndexerState.committedCheckpointId,
            Set({
              entityId: entity.id->EntityId.unsafeOfString,
              checkpointId: params.checkpointId,
              entity,
            }),
          )
        }

    switch prop {
    | "getSync" =>
      (entityId => params->getSyncHandler(entityId))->(
        Utils.magic: (string => option<Internal.entity>) => unknown
      )
    | "getWhereSync" =>
      (
        filter => params->getWhereSyncHandler(filter->(Utils.magic: unknown => dict<dict<unknown>>))
      )->(Utils.magic: (unknown => array<Internal.entity>) => unknown)
    | "getInBlockSync" =>
      (entityId => params->getInBlockSyncHandler(entityId))->(
        Utils.magic: (string => option<Internal.entity>) => unknown
      )
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
              ~scope=params->entityScope,
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
              ~scope=params->entityScope,
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
              ~scope=params->entityScope,
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
          (params :> contextParams)->checkStatusOrThrow(
            ~access=`context.${params.entityConfig.name}.deleteUnsafe`,
          )
          params.indexerState
          ->InMemoryStore.getInMemTable(~entityConfig=params.entityConfig, ~scope=params->entityScope)
          ->InMemoryTable.Entity.set(
            ~committedCheckpointId=params.indexerState->IndexerState.committedCheckpointId,
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

// Deterministic mappings always make progress, so the cap only exists to turn
// a non-deterministic one into a clear error instead of a hang.
let maxSyncRounds = 10000

// Runs a synchronous body, replaying it from the top each time it suspends on
// a read that wasn't in memory yet.
let rec runSyncRound = async (params: contextParams, fn: unit => unit, ~round) => {
  if round > maxSyncRounds {
    JsError.throwWithMessage(
      `The handler suspended on a synchronous read too many times: gave up after ${maxSyncRounds->Int.toString} rounds. This usually means the code isn't deterministic across reruns.`,
    )
  }
  params.sync.status = Active
  params.sync.pending = None

  let suspended = switch fn() {
  | () => false
  | exception exn =>
    if exn->isSuspend {
      true
    } else {
      throw(exn)
    }
  }

  switch params.sync.pending {
  | None => ()
  | Some(pending) =>
    params.sync.pending = None
    if suspended {
      let errors = []
      let _ =
        await pending
        ->Array.map(promise =>
          promise->Promise.catch(exn => {
            errors->Array.push(exn)
            Promise.resolve()
          })
        )
        ->Promise.all
      switch errors->Array.get(0) {
      | Some(exn) => throw(exn)
      | None => ()
      }
      await params->runSyncRound(fn, ~round=round + 1)
    } else {
      // The body swallowed the suspend and returned anyway. The scheduled ops
      // are nobody's result now, but they must not surface as unhandled
      // rejections.
      pending->Array.forEach(promise => promise->Utils.Promise.silentCatch->ignore)
    }
  }
}

let handlerTraps: Utils.Proxy.traps<contextParams> = {
  get: (~target as params, ~prop: unknown) => {
    let prop = prop->(Utils.magic: unknown => string)
    params->checkStatusOrThrow(~access=`context.${prop}`)
    switch prop {
    | "effectSync" =>
      initEffectSync((params :> contextParams))->(
        Utils.magic: ((Internal.effect, Internal.effectInput) => Internal.effectOutput) => unknown
      )
    | "runSync" =>
      (fn => params->runSyncRound(fn, ~round=1))->(
        Utils.magic: ((unit => unit) => promise<unit>) => unknown
      )
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
          sync: params.sync,
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
