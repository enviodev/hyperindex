// Thrown by a sync op that can't be served from memory. Owned by envio so the
// subgraph runtime's replay loop can tell it apart from a real handler error.
// User code never swallows it: AssemblyScript has no try/catch, and the ops
// keep re-throwing it while the round stays aborted.
exception Suspend

let isSuspend = exn =>
  switch exn {
  | Suspend => true
  | _ => false
  }

// Every suspend throws this one value: `throw(Suspend)` builds a fresh Error,
// stack trace and all, and a mapping suspends several times per event.
let suspend: exn = Suspend

type roundStatus =
  | Active
  // Set by a suspended sync op. Every context access re-throws the stored
  // error, so even a caught suspend stops the round at its next one.
  | Aborted(exn)

// One `context.runSync` call. Its body is replayed from the top each time it
// suspends on a read that wasn't in memory yet.
type syncRun = {
  run: RunScope.handlerRun,
  mutable status: roundStatus,
  // Ops scheduled by this round's suspended reads, awaited before the replay.
  mutable pending: array<promise<unit>>,
  // Effect outputs read from the in-memory table during this call, reused by
  // its later rounds.
  memo: dict<Internal.effectOutput>,
  // This round's writes, held until it completes.
  mutable writes: SyncWrites.t,
  // Preload reads this round answered as absent while their load was in flight.
  mutable speculated: int,
}

// The round running right now. A round's body runs synchronously from start to
// end, so no other run's code can observe it.
let currentSync: ref<option<syncRun>> = ref(None)

let syncOf = (run: RunScope.handlerRun) =>
  switch currentSync.contents {
  | Some(sync) if sync.run === run => Some(sync)
  | _ => None
  }

// The handler run a `context.${prop}` access belongs to, refused while its
// round is aborted.
let currentRunOrThrow = (~prop) => {
  let run = RunScope.currentHandlerRunOrThrow(~prop)
  switch run->syncOf {
  | Some({status: Aborted(exn)}) => throw(exn)
  | _ => ()
  }
  run
}

let syncOrThrow = (run, ~prop) =>
  switch run->syncOf {
  | Some(sync) => sync
  | None => JsError.throwWithMessage(`context.${prop} is only available inside context.runSync.`)
  }

// Fires the async op behind a sync miss, records it for the replay and aborts
// the round.
let scheduleAndSuspend = (sync: syncRun, promise: promise<'a>): 'b => {
  sync.pending->Array.push(promise->Utils.Promise.ignoreValue)
  sync.status = Aborted(suspend)
  throw(suspend)
}

// Preload reads past a miss: the read answers as absent and the round runs on,
// so the reads after it that don't depend on it join this round's batch rather
// than taking a round each. Nothing preload computes is kept, and the round is
// replayed once its reads land. Bounded, for a mapping that loops on a read.
let maxSpeculatedReads = 32

let missOrSuspend = (sync: syncRun, promise: promise<'a>, ~absent: 'b): 'b =>
  if sync.run.isPreload && sync.speculated < maxSpeculatedReads {
    sync.pending->Array.push(promise->Utils.Promise.ignoreValue)
    sync.speculated = sync.speculated + 1
    absent
  } else {
    sync->scheduleAndSuspend(promise)
  }

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

// An effect that didn't state a scope follows the config: cross-chain by
// default, per-chain under `disable_default_cross_chain`.
let isCrossChain = (params: params, effect: Internal.effect) =>
  effect.crossChain->Option.getOr(params.config.defaultCrossChain)

// A chain-scoped effect always resolves against the chain of the handler run
// that triggered the call, even several effects deep.
let rec prepareEffectCall = (
  params: params,
  ~run: RunScope.handlerRun,
  ~caller: option<Internal.effect>,
  effect: Internal.effect,
  input: Internal.effectInput,
) => {
  let handlerChainId = run.item->Internal.getItemChainId
  let scope = params->isCrossChain(effect) ? Internal.CrossChain : Internal.Chain(handlerChainId)

  switch (caller, scope) {
  | (Some(callerEffect), Chain(_)) if params->isCrossChain(callerEffect) =>
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
    ~callEffect=(child, input) => params->callEffect(~run, ~caller=Some(effect), child, input),
  )
  effectContext->RunScope.attachEffectRun({caller: run, effectName: effect.name})
  let effectArgs: Internal.effectArgs = {
    input,
    context: effectContext,
    cacheKey: input
    ->S.reverseConvertOrThrow(effect.input)
    ->Utils.Hash.makeOrThrow
    ->Utils.Hash.boundCacheKey,
    chainId: handlerChainId,
    checkpointId: run.checkpointId,
  }
  (scope, effectArgs)
}

and callEffect = (params: params, ~run: RunScope.handlerRun, ~caller, effect, input) => {
  let (scope, effectArgs) = params->prepareEffectCall(~run, ~caller, effect, input)
  LoadLayer.loadEffect(
    ~loadManager=params.loadManager,
    ~persistence=params.persistence,
    ~effect,
    ~effectArgs,
    ~scope,
    ~indexerState=params.indexerState,
    ~shouldGroup=run.isPreload,
  )
}

let effectMemoKey = (~effect: Internal.effect, ~scope: Internal.chainScope, ~cacheKey) =>
  switch scope {
  | CrossChain => `${effect.name}.${cacheKey}`
  | Chain(chainId) => `${effect.name}.${chainId->ChainId.toString}.${cacheKey}`
  }

// An effect's output when it's in memory; otherwise the round suspends on it.
let effectSync = (params: params, effect: Internal.effect, input: Internal.effectInput) => {
  let run = currentRunOrThrow(~prop="effectSync")
  let sync = run->syncOrThrow(~prop="effectSync")
  let (scope, effectArgs) = params->prepareEffectCall(~run, ~caller=None, effect, input)
  let memoKey = effectMemoKey(~effect, ~scope, ~cacheKey=effectArgs.cacheKey)
  switch sync.memo->Utils.Dict.dangerouslyGetNonOption(memoKey) {
  | Some(output) => output
  | None =>
    let inMemTable = params.indexerState->InMemoryStore.getEffectInMemTable(~effect, ~scope)
    if inMemTable->InMemoryStore.hasEffectOutput(effectArgs.cacheKey) {
      let output = inMemTable->InMemoryStore.getEffectOutputUnsafe(effectArgs.cacheKey)
      sync.memo->Dict.set(memoKey, output)
      output
    } else if sync.speculated > 0 {
      // The input may be computed from a speculated read: an effect can cost
      // an RPC call, so it waits to be asked with the real values.
      sync.status = Aborted(suspend)
      throw(suspend)
    } else {
      sync->scheduleAndSuspend(
        LoadLayer.loadEffect(
          ~loadManager=params.loadManager,
          ~persistence=params.persistence,
          ~effect,
          ~effectArgs,
          ~scope,
          ~indexerState=params.indexerState,
          ~shouldGroup=run.isPreload,
        ),
      )
    }
  }
}

// A TTL drops an entity's rows whenever ClickHouse merges them, so for one kept
// there alone a read would turn on merge timing rather than on the events.
let expiresUnread = (entityConfig: Internal.entityConfig) =>
  !entityConfig.storage.postgres &&
  entityConfig.storage.clickhouseOptions
  ->Option.flatMap(options => options.ttl)
  ->Option.isSome

let throwExpiresUnread = (entityConfig: Internal.entityConfig, op: string) => {
  let {name} = entityConfig
  JsError.throwWithMessage(
    `context.${name}.${op}() is unavailable: ${name} is kept in ClickHouse alone with a ttl, which drops its rows whenever ClickHouse merges them, so a handler would read it differently from one run to the next. Keep it in Postgres too, with @storage(postgres: true, clickhouse: {...}), or drop the ttl.`,
  )
}

type entityContext = {
  get: string => promise<option<Internal.entity>>,
  getWhere: dict<dict<unknown>> => promise<array<Internal.entity>>,
  getOrThrow: (string, ~message: string=?) => promise<Internal.entity>,
  getOrCreate: Internal.entity => promise<Internal.entity>,
  set: Internal.entity => unit,
  deleteUnsafe: EntityId.t => unit,
}

type syncEntityContext = {
  getSync: string => option<Internal.entity>,
  getWhereSync: dict<dict<unknown>> => array<Internal.entity>,
  getInBlockSync: string => option<Internal.entity>,
}

let makeEntityContext = (params: params, ~entityConfig: Internal.entityConfig) => {
  let prop = entityConfig.name
  let entityName = entityConfig.name
  // The handler context is always chain-scoped, so a per-chain entity resolves
  // to the chain the handler runs on and a cross-chain one to the shared
  // partition.
  let scopeOf = (run: RunScope.handlerRun) =>
    entityConfig->InMemoryStore.entityScope(~chainId=run.item->Internal.getItemChainId)

  let loadById = entityId => {
    let run = currentRunOrThrow(~prop)
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

  // A preload run's writes are no-ops: its run proper makes them. Inside a sync
  // round they are held until the round completes, a preload's only for the
  // batch's later preloads to read (PreloadLookahead), never in the store.
  let write = (run: RunScope.handlerRun, change: Change.t<Internal.entity>) =>
    switch (run->syncOf, run.isPreload) {
    | (Some(sync), false) =>
      sync.writes->SyncWrites.record(~entityConfig, ~scope=run->scopeOf, change)
    | (Some(sync), true) if PreloadLookahead.isActive() =>
      sync.writes->SyncWrites.record(~entityConfig, ~scope=run->scopeOf, change)
    | (None, false) =>
      params.indexerState->SyncWrites.write(~entityConfig, ~scope=run->scopeOf, change)
    | (_, true) => ()
    }

  let set = (entity: Internal.entity) => {
    let run = currentRunOrThrow(~prop)
    run->write(
      Set({
        entityId: entity.id->EntityId.unsafeOfString,
        checkpointId: run.checkpointId,
        entity,
      }),
    )
  }

  let deleteUnsafe = entityId => {
    let run = currentRunOrThrow(~prop)
    run->write(Delete({entityId, checkpointId: run.checkpointId}))
  }

  let entityContext: entityContext = if entityConfig->expiresUnread {
    {
      get: _ => throwExpiresUnread(entityConfig, "get"),
      getWhere: _ => throwExpiresUnread(entityConfig, "getWhere"),
      getOrThrow: (_, ~message as _=?) => throwExpiresUnread(entityConfig, "getOrThrow"),
      getOrCreate: _ => throwExpiresUnread(entityConfig, "getOrCreate"),
      set,
      deleteUnsafe,
    }
  } else {
    {
      get: loadById,
      getWhere: filter => {
        let run = currentRunOrThrow(~prop)
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

  let object =
    Utils.StrictObject.make(
      Utils.StrictObject.makePrototype(op =>
        JsError.throwWithMessage(`Invalid context.${entityConfig.name}.${op} operation.`)
      ),
    )->Utils.StrictObject.assign(entityContext)

  // The subgraph runtime's synchronous reads: answered from memory, or the
  // round suspends on the load and is replayed once it lands.
  if Env.subgraphMode.contents {
    let syncEntityContext: syncEntityContext = {
      getSync: entityId => {
        let run = currentRunOrThrow(~prop)
        let sync = run->syncOrThrow(~prop=`${prop}.getSync`)
        let scope = run->scopeOf
        switch sync.writes->SyncWrites.getById(~entityConfig, ~entityId) {
        | Some(entity) => entity
        | None =>
          switch run.isPreload
            ? PreloadLookahead.overlayGet(~item=run.item, ~entityName, ~scope, ~entityId)
            : None {
          | Some(entity) => entity
          | None =>
            switch LoadLayer.getByIdInMemory(
              ~entityConfig,
              ~scope,
              ~indexerState=params.indexerState,
              ~entityId,
            ) {
            | Some(entity) =>
              if run.isPreload && entity->Option.isNone {
                PreloadLookahead.recordAbsent(~item=run.item, ~entityName, ~scope, ~entityId)
              }
              entity
            | None =>
              sync->missOrSuspend(
                ~absent=None,
                LoadLayer.loadById(
                  ~loadManager=params.loadManager,
                  ~persistence=params.persistence,
                  ~entityConfig,
                  ~scope,
                  ~indexerState=params.indexerState,
                  ~shouldGroup=run.isPreload,
                  ~entityId,
                ),
              )
            }
          }
        }
      },
      getWhereSync: filter => {
        let run = currentRunOrThrow(~prop)
        let sync = run->syncOrThrow(~prop=`${prop}.getWhereSync`)
        let scope = run->scopeOf
        let filter = filter->EntityFilter.parseOrThrow(~entityName, ~table=entityConfig.table)
        switch LoadLayer.getByFilterInMemory(
          ~entityConfig,
          ~scope,
          ~indexerState=params.indexerState,
          ~filter,
        ) {
        | Some(entities) => sync.writes->SyncWrites.overlayFilter(entities, ~entityConfig, ~filter)
        | None =>
          sync->missOrSuspend(
            ~absent=[],
            LoadLayer.loadByParsedFilter(
              ~loadManager=params.loadManager,
              ~persistence=params.persistence,
              ~entityConfig,
              ~scope,
              ~indexerState=params.indexerState,
              ~shouldGroup=run.isPreload,
              ~filter,
            ),
          )
        }
      },
      // Never suspends: the in-memory table spans the whole batch, so a change
      // only counts as "in this block" when it was written at this run's
      // checkpoint.
      getInBlockSync: entityId => {
        let run = currentRunOrThrow(~prop)
        let sync = run->syncOrThrow(~prop=`${prop}.getInBlockSync`)
        switch sync.writes->SyncWrites.getById(~entityConfig, ~entityId) {
        | Some(entity) => entity
        | None =>
          let inMemTable =
            params.indexerState->InMemoryStore.getInMemTable(~entityConfig, ~scope=run->scopeOf)
          switch inMemTable.latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(entityId) {
          | Some(change) if change->Change.getCheckpointId == run.checkpointId =>
            change->InMemoryTable.Entity.mapChangeToEntity
          | _ => None
          }
        }
      },
    }
    object->Utils.StrictObject.assign(
      syncEntityContext->(Utils.magic: syncEntityContext => entityContext),
    )
  } else {
    object
  }
}

// Deterministic mappings always make progress, so the cap only exists to turn
// a non-deterministic one into a clear error instead of a hang.
let maxSyncRounds = 10000

let rec runSyncRound = async (params: params, sync: syncRun, fn: unit => unit, ~round) => {
  if round > maxSyncRounds {
    JsError.throwWithMessage(
      `The handler suspended on a synchronous read too many times: gave up after ${maxSyncRounds->Int.toString} rounds. This usually means the code isn't deterministic across reruns.`,
    )
  }
  let run = sync.run
  sync.status = Active
  sync.pending = []
  sync.speculated = 0
  sync.writes = SyncWrites.make()
  let startedAt = PreloadLookahead.roundStarted(~isPreload=run.isPreload)

  let previous = currentSync.contents
  currentSync := Some(sync)
  let outcome = try {
    fn()
    Ok()
  } catch {
  | exn => Error(exn)
  }
  currentSync := previous
  PreloadLookahead.roundEnded(~item=run.item, ~startedAt)
  let writes = sync.writes

  // Neither a suspended round nor a failed one keeps what it wrote.
  sync.writes = SyncWrites.make()

  let suspended = switch outcome {
  | Ok() =>
    switch sync.status {
    // The body caught the suspend and returned anyway, so it didn't see the
    // reads it asked for: it is replayed like any other suspended round.
    | Aborted(_) => true
    // Ran on reads it was told were absent.
    | Active if sync.speculated > 0 => true
    | Active =>
      if run.isPreload {
        writes->SyncWrites.forEachChange((~entityConfig, ~scope, change) =>
          PreloadLookahead.overlaySet(
            ~item=run.item,
            ~entityName=entityConfig.name,
            ~scope,
            ~entityId=change->Change.getEntityId->EntityId.toKey,
            ~entity=change->InMemoryTable.Entity.mapChangeToEntity,
          )
        )
      } else {
        writes->SyncWrites.commit(~indexerState=params.indexerState)
      }
      false
    }
  // A round handed a speculated absence may well throw on it: the replay that
  // sees the real value decides whether the error is the handler's.
  | Error(exn) if exn->isSuspend || sync.speculated > 0 => true
  | Error(exn) =>
    // The body threw its own error after scheduling a read. Those ops are
    // nobody's result now, and an unhandled rejection would replace the error
    // the handler actually raised.
    sync.pending->Array.forEach(promise => promise->Utils.Promise.catchResolve(_ => ())->ignore)
    sync.pending = []
    throw(exn)
  }

  if suspended {
    // A round only suspends by scheduling the read it missed.
    let pending = sync.pending
    sync.pending = []
    let errors = []
    let _ = await pending
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
    await params->runSyncRound(sync, fn, ~round=round + 1)
  }
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
      {enumerable: true, get: () => get(currentRunOrThrow(~prop=name))},
    )
    ->ignore

  define("log", (run: RunScope.handlerRun) =>
    (run.isPreload ? Logger.silentContextLog : run->RunScope.handlerLogger->Logger.asContextLog)->(
      Utils.magic: Envio.logger => unknown
    )
  )
  // Reads the run when called, so a kept `context.effect` is refused once its
  // handler resolved, like a kept entity accessor.
  let effect = (effect, input) =>
    params->callEffect(~run=currentRunOrThrow(~prop="effect"), ~caller=None, effect, input)
  context
  ->Utils.Object.definePropertyWithValue(
    "effect",
    {
      enumerable: true,
      value: effect->(
        Utils.magic: (
          (Internal.effect, Internal.effectInput) => promise<Internal.effectOutput>
        ) => unknown
      ),
    },
  )
  ->ignore
  if Env.subgraphMode.contents {
    context
    ->Utils.Object.definePropertyWithValue(
      "effectSync",
      {
        enumerable: true,
        value: ((effect, input) => params->effectSync(effect, input))->(
          Utils.magic: ((Internal.effect, Internal.effectInput) => Internal.effectOutput) => unknown
        ),
      },
    )
    ->ignore
    context
    ->Utils.Object.definePropertyWithValue(
      "runSync",
      {
        enumerable: true,
        value: (
          fn => {
            let run = currentRunOrThrow(~prop="runSync")
            params->runSyncRound(
              {
                run,
                status: Active,
                pending: [],
                memo: Dict.make(),
                writes: SyncWrites.make(),
                speculated: 0,
              },
              fn,
              ~round=1,
            )
          }
        )->(Utils.magic: ((unit => unit) => promise<unit>) => unknown),
      },
    )
    ->ignore
  }
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
