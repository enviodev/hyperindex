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
  // The batch's calls; a preload context never adds to it.
  sidecarCalls: array<SidecarCall.t>,
  // Counts this handler run's sidecar calls, which makes the call id
  // deterministic: each run gets a fresh context, in item order.
  mutable sidecarSeq: int,
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
        params,
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
    ~item=params.item,
    ~ecosystem=params.config.ecosystem,
    ~filter,
  )

let noopSet = (_entity: Internal.entity) => ()
let noopDeleteUnsafe = (_entityId: EntityId.t) => ()

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

// `chainId:blockNumber:<position>:seq`, the same in the preload and the real
// pass, so the sidecar can dedupe a redelivery. One log can feed several
// registrations, each counting its calls from 0, so an event's position is its
// log index plus `r<registration index>`. An SVM instruction shares its
// transaction's log index, so its position in the CPI tree goes in between
// (`3.0.2r1`). A block handler has no log and takes `b<registration index>`.
let nextSidecarCallId = (params: contextParams) => {
  let seq = params.sidecarSeq
  params.sidecarSeq = seq + 1
  let chainId = params.item->Internal.getItemChainId->ChainId.toString
  let blockNumber = params.item->Internal.getItemBlockNumber->Int.toString
  let position = switch params.item {
  | Block({onBlockRegistration: {index}}) => `b${index->Int.toString}`
  | Event({logIndex, onEventRegistration: {index}}) =>
    let log = switch params.item->Internal.getItemOrderPath->Nullable.toOption {
    | Some(path) =>
      `${logIndex->Int.toString}.${path->Array.map(step => step->Int.toString)->Array.join(".")}`
    | None => logIndex->Int.toString
    }
    `${log}r${index->Int.toString}`
  }
  `${chainId}:${blockNumber}:${position}:${seq->Int.toString}`
}

let sidecarBlockTimestamp = (params: contextParams) =>
  switch params.item {
  | Block(_) => None
  | Event(_) =>
    (params.item->Internal.castUnsafeEventItem).payload
    ->Internal.getPayloadBlock
    ->Nullable.toOption
    ->Option.flatMap(block =>
      block
      ->(Utils.magic: Internal.eventBlock => dict<unknown>)
      ->Utils.Dict.dangerouslyGetNonOption(params.config.ecosystem.blockTimestampName)
    )
    ->Option.map(timestamp => timestamp->(Utils.magic: unknown => int))
  }

let warnDroppedSidecarCall = (params: contextParams, ~fn, ~id, ~reason, ~err=?) =>
  Ecosystem.getItemLogger(params.item, ~ecosystem=params.config.ecosystem)->Logging.childWarn({
    "msg": `Dropped the sidecar call ${fn}: ${reason}`,
    "callId": id,
    "err": err->Option.map(Utils.prettifyExn),
  })

// Never throws into the handler and never waits: a bad input is logged and
// dropped, and the id is still returned.
let callSidecar = (
  params: contextParams,
  ~fn,
  ~def: SidecarContract.functionDef,
  input: unknown,
) => {
  let id = params->nextSidecarCallId
  if !params.isPreload {
    // The handler holds the output form (a bigint, not its string), and
    // converting it doesn't check types, so the JSON is parsed back to check.
    switch {
      let json = input->S.reverseConvertToJsonOrThrow(def.input)
      let _ = json->S.parseOrThrow(def.input)
      json
    } {
    | json =>
      params.sidecarCalls
      ->Array.push({
        id,
        fn,
        chainId: params.item->Internal.getItemChainId,
        blockNumber: params.item->Internal.getItemBlockNumber,
        blockTimestamp: params->sidecarBlockTimestamp,
        checkpointId: params.checkpointId,
        input: json,
      })
      ->ignore
    | exception exn =>
      params->warnDroppedSidecarCall(
        ~fn,
        ~id,
        ~reason="its input doesn't match the contract",
        ~err=exn,
      )
    }
  }
  id
}

// A name the contract can't define (`defineSidecar` checks the same pattern),
// or one that `await`, serializers and test matchers probe for, reads as
// undefined: touching `context.sidecar` must not throw or look like a promise.
let sidecarFunctionName = /^[A-Za-z_][A-Za-z0-9_]*$/
let sidecarProbes = Utils.Set.fromArray(["then", "toJSON", "asymmetricMatch", "nodeType"])
let isObjectPrototypeKey: string => bool = %raw(`name => name in Object.prototype`)
let isSidecarProbe = name =>
  !(sidecarFunctionName->RegExp.test(name)) ||
  sidecarProbes->Utils.Set.has(name) ||
  isObjectPrototypeKey(name)

@val @scope("Object") external hasOwn: (dict<'a>, string) => bool = "hasOwn"

let sidecarTraps: Utils.Proxy.traps<contextParams> = {
  get: (~target as params, ~prop: unknown) =>
    if typeof(prop) !== #string {
      %raw(`undefined`)
    } else {
      let fn = prop->(Utils.magic: unknown => string)
      let functions = SidecarContract.get()->Option.map(({functions}) => functions)
      // Not even a contract function may be `then`: `await context.sidecar`
      // would call it and never resolve.
      switch functions->Option.flatMap(functions =>
        fn !== "then" && functions->hasOwn(fn) ? Some(functions->Dict.getUnsafe(fn)) : None
      ) {
      | Some(def) =>
        (input => params->callSidecar(~fn, ~def, input))->(
          Utils.magic: (unknown => string) => unknown
        )

      | None if isSidecarProbe(fn) => %raw(`undefined`)
      // Reachable from JavaScript or past a cast: dropped like a bad input,
      // still with an id, since nothing throws into the handler.
      | None =>
        let reason = switch functions {
        | Some(functions) =>
          `the sidecar contract has no such function (it has: ${functions
            ->Dict.keysToArray
            ->Array.join(", ")})`
        | None => "config.yaml has no `sidecar: { contract, entry }`"
        }

        (
          _input => {
            let id = params->nextSidecarCallId
            if !params.isPreload {
              params->warnDroppedSidecarCall(~fn, ~id, ~reason)
            }
            id
          }
        )->(Utils.magic: (unknown => string) => unknown)
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
    | "sidecar" => params->Utils.Proxy.make(sidecarTraps)->(Utils.magic: contextParams => unknown)
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
          sidecarCalls: params.sidecarCalls,
          sidecarSeq: params.sidecarSeq,
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
