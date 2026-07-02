let loadById = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~indexerState,
  ~shouldGroup,
  ~item,
  ~ecosystem,
  ~entityId,
) => {
  let key = `${entityConfig.name}.get`
  let inMemTable = indexerState->InMemoryStore.getInMemTable(~entityConfig)

  let load = async (idsToLoad, ~onError as _) => {
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let timerRef = Prometheus.StorageLoad.startOperation(~storage=storage.name, ~operation=key)

    // Since LoadManager.call prevents registering entities already in the in-memory store,
    // we can be sure that we load only the new ones.
    let dbEntities = try {
      (
        await storage.loadOrThrow(
          ~table=entityConfig.table,
          ~filter=EntityFilter.In({
            fieldName: Table.idFieldName,
            fieldValue: idsToLoad->(Utils.magic: array<string> => array<unknown>),
          }),
        )
      )->(Utils.magic: array<unknown> => array<Internal.entity>)
    } catch {
    | Persistence.StorageError({message, reason}) =>
      reason->ErrorHandling.mkLogAndRaise(
        ~logger=Ecosystem.getItemLogger(item, ~ecosystem),
        ~msg=message,
      )
    }

    let entitiesMap = Dict.make()

    //Set the entity in the in memory store
    for idx in 0 to dbEntities->Array.length - 1 {
      let entity = dbEntities->Array.getUnsafe(idx)
      entitiesMap->Dict.set(entity.id, entity)
    }
    idsToLoad->Array.forEach(entityId => {
      inMemTable->InMemoryTable.Entity.initValue(
        ~committedCheckpointId=indexerState->IndexerState.committedCheckpointId,
        ~key=entityId,
        ~entity=entitiesMap->Utils.Dict.dangerouslyGetNonOption(entityId),
      )
    })

    timerRef->Prometheus.StorageLoad.endOperation(
      ~storage=storage.name,
      ~operation=key,
      ~whereSize=idsToLoad->Array.length,
      ~size=dbEntities->Array.length,
    )
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~shouldGroup,
    ~hasher=LoadManager.noopHasher,
    ~getUnsafeInMemory=inMemTable->InMemoryTable.Entity.getUnsafe,
    ~hasInMemory=hash => inMemTable.latestEntityChangeById->Dict.has(hash),
    ~input=entityId,
  )
}

let callEffect = (
  ~effect: Internal.effect,
  ~arg: Internal.effectArgs,
  ~inMemTable: IndexerState.effectCacheInMemTable,
  ~timerRef,
  ~onError,
) => {
  let effectName = effect.name
  let hadActiveCalls = effect.activeCallsCount > 0
  effect.activeCallsCount = effect.activeCallsCount + 1
  Prometheus.EffectCalls.activeCallsCount->Prometheus.SafeGauge.handleInt(
    ~labels=effectName,
    ~value=effect.activeCallsCount,
  )

  if hadActiveCalls {
    let elapsed = Performance.secondsBetween(~from=effect.prevCallStartTimerRef, ~to=timerRef)
    if elapsed > 0. {
      Prometheus.EffectCalls.timeCounter->Prometheus.SafeCounter.handleFloat(
        ~labels=effectName,
        ~value=elapsed,
      )
    }
  }
  effect.prevCallStartTimerRef = timerRef

  effect.handler(arg)
  ->Promise.thenResolve(output => {
    inMemTable->InMemoryStore.setEffectOutput(
      ~checkpointId=arg.checkpointId,
      ~cacheKey=arg.cacheKey,
      ~output,
      ~shouldCache=arg.context.cache,
    )
  })
  ->Utils.Promise.catchResolve(exn => {
    onError(~inputKey=arg.cacheKey, ~exn)
  })
  ->Promise.finally(() => {
    effect.activeCallsCount = effect.activeCallsCount - 1
    Prometheus.EffectCalls.activeCallsCount->Prometheus.SafeGauge.handleInt(
      ~labels=effectName,
      ~value=effect.activeCallsCount,
    )
    let newTimer = Performance.now()
    Prometheus.EffectCalls.timeCounter->Prometheus.SafeCounter.handleFloat(
      ~labels=effectName,
      ~value=Performance.secondsBetween(~from=effect.prevCallStartTimerRef, ~to=newTimer),
    )
    effect.prevCallStartTimerRef = newTimer

    Prometheus.EffectCalls.totalCallsCount->Prometheus.SafeCounter.increment(~labels=effectName)
    Prometheus.EffectCalls.sumTimeCounter->Prometheus.SafeCounter.handleFloat(
      ~labels=effectName,
      ~value=timerRef->Performance.secondsSince,
    )
  })
}

let rec executeWithRateLimit = (
  ~effect: Internal.effect,
  ~effectArgs: array<Internal.effectArgs>,
  ~inMemTable,
  ~onError,
  ~isFromQueue: bool,
) => {
  let effectName = effect.name

  let timerRef = Performance.now()
  let promises = []

  switch effect.rateLimit {
  | None =>
    // No rate limiting - execute all immediately
    for idx in 0 to effectArgs->Array.length - 1 {
      promises
      ->Array.push(
        callEffect(
          ~effect,
          ~arg=effectArgs->Array.getUnsafe(idx),
          ~inMemTable,
          ~timerRef,
          ~onError,
        )->Utils.Promise.ignoreValue,
      )
      ->ignore
    }

  | Some(state) =>
    let now = Date.now()

    // Check if we need to reset the window
    if now >= state.windowStartTime +. state.durationMs->Int.toFloat {
      state.availableCalls = state.callsPerDuration
      state.windowStartTime = now
      state.nextWindowPromise = None
    }

    // Split into immediate and queued
    let immediateCount = Math.Int.min(state.availableCalls, effectArgs->Array.length)
    let immediateArgs = effectArgs->Array.slice(~start=0, ~end=immediateCount)
    let queuedArgs = effectArgs->Array.slice(~start=immediateCount)

    // Update available calls
    state.availableCalls = state.availableCalls - immediateCount

    // Call immediate effects
    for idx in 0 to immediateArgs->Array.length - 1 {
      promises
      ->Array.push(
        callEffect(
          ~effect,
          ~arg=immediateArgs->Array.getUnsafe(idx),
          ~inMemTable,
          ~timerRef,
          ~onError,
        )->Utils.Promise.ignoreValue,
      )
      ->ignore
    }

    if immediateCount > 0 && isFromQueue {
      // Update queue count metric
      state.queueCount = state.queueCount - immediateCount
      Prometheus.EffectQueueCount.set(~count=state.queueCount, ~effectName)
    }

    // Handle queued items
    if queuedArgs->Utils.Array.notEmpty {
      if !isFromQueue {
        // Update queue count metric
        state.queueCount = state.queueCount + queuedArgs->Array.length
        Prometheus.EffectQueueCount.set(~count=state.queueCount, ~effectName)
      }

      let millisUntilReset = ref(0)
      let nextWindowPromise = switch state.nextWindowPromise {
      | Some(p) => p
      | None =>
        millisUntilReset :=
          (state.windowStartTime +. state.durationMs->Int.toFloat -. now)->Float.toInt
        let p = Utils.delay(millisUntilReset.contents)
        state.nextWindowPromise = Some(p)
        p
      }

      // Wait for next window and recursively process queue
      promises
      ->Array.push(
        nextWindowPromise
        ->Promise.then(() => {
          if millisUntilReset.contents > 0 {
            Prometheus.EffectQueueCount.timeCounter->Prometheus.SafeCounter.handleFloat(
              ~labels=effectName,
              ~value=millisUntilReset.contents->Int.toFloat /. 1000.,
            )
          }
          executeWithRateLimit(
            ~effect,
            ~effectArgs=queuedArgs,
            ~inMemTable,
            ~onError,
            ~isFromQueue=true,
          )
        })
        ->Utils.Promise.ignoreValue,
      )
      ->ignore
    }
  }

  // Wait for all to complete
  promises->Promise.all
}

let loadEffect = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~effect: Internal.effect,
  ~effectArgs,
  ~indexerState,
  ~shouldGroup,
  ~item,
  ~ecosystem,
) => {
  let effectName = effect.name
  let key = `${effectName}.effect`
  let inMemTable = indexerState->InMemoryStore.getEffectInMemTable(~effect)

  let load = async (args, ~onError) => {
    let idsToLoad = args->Array.map((arg: Internal.effectArgs) => arg.cacheKey)
    let idsFromCache = Utils.Set.make()

    if (
      switch persistence.storageStatus {
      | Ready({cache}) => cache->Dict.has(effectName)
      | _ => false
      }
    ) {
      let storage = persistence->Persistence.getInitializedStorageOrThrow
      let timerRef = Prometheus.StorageLoad.startOperation(~storage=storage.name, ~operation=key)
      let {table, outputSchema} = effect.storageMeta

      let dbEntities = try {
        (
          await storage.loadOrThrow(
            ~table,
            ~filter=EntityFilter.In({
              fieldName: Table.idFieldName,
              fieldValue: idsToLoad->(Utils.magic: array<string> => array<unknown>),
            }),
          )
        )->(Utils.magic: array<unknown> => array<Internal.effectCacheItem>)
      } catch {
      | exn =>
        Ecosystem.getItemLogger(item, ~ecosystem)->Logging.childWarn({
          "msg": `Failed to load cache effect cache. The indexer will continue working, but the effect will not be able to use the cache.`,
          "err": exn->Utils.prettifyExn,
          "effect": effectName,
        })
        []
      }

      dbEntities->Array.forEach(dbEntity => {
        try {
          let output = dbEntity.output->S.parseOrThrow(outputSchema)
          idsFromCache->Utils.Set.add(dbEntity.id)->ignore
          inMemTable->InMemoryStore.initEffectOutputFromDb(~cacheKey=dbEntity.id, ~output)
        } catch {
        | S.Raised(error) =>
          inMemTable.invalidationsCount = inMemTable.invalidationsCount + 1
          Prometheus.EffectCacheInvalidationsCount.increment(~effectName)
          Ecosystem.getItemLogger(item, ~ecosystem)->Logging.childTrace({
            "msg": "Invalidated effect cache",
            "input": dbEntity.id,
            "effect": effectName,
            "err": error->S.Error.message,
          })
        }
      })

      timerRef->Prometheus.StorageLoad.endOperation(
        ~storage=storage.name,
        ~operation=key,
        ~whereSize=idsToLoad->Array.length,
        ~size=dbEntities->Array.length,
      )
    }

    let remainingCallsCount = idsToLoad->Array.length - idsFromCache->Utils.Set.size
    if remainingCallsCount > 0 {
      let argsToCall = []
      for idx in 0 to args->Array.length - 1 {
        let arg = args->Array.getUnsafe(idx)
        if !(idsFromCache->Utils.Set.has(arg.cacheKey)) {
          argsToCall->Array.push(arg)->ignore
        }
      }

      if argsToCall->Utils.Array.notEmpty {
        await executeWithRateLimit(
          ~effect,
          ~effectArgs=argsToCall,
          ~inMemTable,
          ~onError,
          ~isFromQueue=false,
        )->Utils.Promise.ignoreValue
      }
    }
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~shouldGroup,
    ~hasher=args => args.cacheKey,
    ~getUnsafeInMemory=hash => inMemTable->InMemoryStore.getEffectOutputUnsafe(hash),
    ~hasInMemory=hash => inMemTable->InMemoryStore.hasEffectOutput(hash),
    ~input=effectArgs,
  )
}

let loadByFilter = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~indexerState,
  ~shouldGroup,
  ~item,
  ~ecosystem,
  ~filter: EntityFilter.t,
) => {
  let key = filter->EntityFilter.toOperationKey(~entityName=entityConfig.name)
  let inMemTable = indexerState->InMemoryStore.getInMemTable(~entityConfig)

  let load = async (filters: array<EntityFilter.t>, ~onError as _) => {
    let storage = persistence->Persistence.getInitializedStorageOrThrow
    let timerRef = Prometheus.StorageLoad.startOperation(~storage=storage.name, ~operation=key)

    let size = ref(0)

    filters->Array.forEach(filter =>
      inMemTable->InMemoryTable.Entity.addEmptyIndex(~filter, ~table=entityConfig.table)
    )

    // Loading a superset of rows via a merged query is safe: every loaded
    // entity is matched against all registered indices, not only the
    // query's own filter.
    let queries = filters->EntityFilter.merge

    let _ = await queries
    ->Array.map(async filter => {
      try {
        let entities =
          (await storage.loadOrThrow(~table=entityConfig.table, ~filter))->(
            Utils.magic: array<unknown> => array<Internal.entity>
          )

        entities->Array.forEach(entity => {
          inMemTable->InMemoryTable.Entity.initValue(
            ~committedCheckpointId=indexerState->IndexerState.committedCheckpointId,
            ~key=entity.id,
            ~entity=Some(entity),
          )
        })

        size := size.contents + entities->Array.length
      } catch {
      | Persistence.StorageError({message, reason}) =>
        reason->ErrorHandling.mkLogAndRaise(
          ~logger=Logging.createChildFrom(
            ~logger=Ecosystem.getItemLogger(item, ~ecosystem),
            // The executed query might be merged from multiple getWhere
            // calls, so report it as the operation users write with the
            // values bound to its placeholders, instead of an internal
            // filter representation they never constructed.
            ~params={
              "operation": key,
              "params": filter->EntityFilter.getParams,
            },
          ),
          ~msg=message,
        )
      }
    })
    ->Promise.all

    timerRef->Prometheus.StorageLoad.endOperation(
      ~storage=storage.name,
      ~operation=key,
      ~whereSize=queries->Array.reduce(0, (acc, query) => acc + query->EntityFilter.valuesCount),
      ~size=size.contents,
    )
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~input=filter,
    ~shouldGroup,
    ~hasher=EntityFilter.toString,
    ~getUnsafeInMemory=inMemTable->InMemoryTable.Entity.getUnsafeOnIndex,
    ~hasInMemory=inMemTable->InMemoryTable.Entity.hasIndex,
  )
}
