open Belt

let loadById = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore,
  ~shouldGroup,
  ~item,
  ~entityId,
) => {
  let key = `${entityConfig.name}.get`
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityConfig)

  let load = async (idsToLoad, ~onError as _) => {
    let timerRef = Prometheus.StorageLoad.startOperation(~operation=key)

    // Since LoadManager.call prevents registerign entities already existing in the inMemoryStore,
    // we can be sure that we load only the new ones.
    let dbEntities = try {
      await (persistence->Persistence.getInitializedStorageOrThrow).loadByIdsOrThrow(
        ~table=entityConfig.table,
        ~rowsSchema=entityConfig.rowsSchema,
        ~ids=idsToLoad,
      )
    } catch {
    | Persistence.StorageError({message, reason}) =>
      reason->ErrorHandling.mkLogAndRaise(~logger=item->Logging.getItemLogger, ~msg=message)
    }

    let entitiesMap = Js.Dict.empty()
    for idx in 0 to dbEntities->Array.length - 1 {
      let entity = dbEntities->Js.Array2.unsafe_get(idx)
      entitiesMap->Js.Dict.set(entity.id, entity)
    }
    idsToLoad->Js.Array2.forEach(entityId => {
      // Set the entity in the in memory store
      // without overwriting existing values
      // which might be newer than what we got from db
      inMemTable->InMemoryTable.Entity.initValue(
        ~allowOverWriteEntity=false,
        ~key=entityId,
        ~entity=entitiesMap->Utils.Dict.dangerouslyGetNonOption(entityId),
      )
    })

    timerRef->Prometheus.StorageLoad.endOperation(
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
    ~hasInMemory=hash => inMemTable.table->InMemoryTable.hasByHash(hash),
    ~input=entityId,
  )
}

let callEffect = (
  ~effect: Internal.effect,
  ~arg: Internal.effectArgs,
  ~inMemTable: InMemoryStore.effectCacheInMemTable,
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
    let elapsed = Hrtime.millisBetween(~from=effect.prevCallStartTimerRef, ~to=timerRef)
    if elapsed > 0 {
      Prometheus.EffectCalls.timeCounter->Prometheus.SafeCounter.incrementMany(
        ~labels=effectName,
        ~value=Hrtime.millisBetween(~from=effect.prevCallStartTimerRef, ~to=timerRef),
      )
    }
  }
  effect.prevCallStartTimerRef = timerRef

  effect.handler(arg)
  ->Promise.thenResolve(output => {
    inMemTable.dict->Js.Dict.set(arg.cacheKey, output)
    if arg.context.cache {
      inMemTable.idsToStore->Array.push(arg.cacheKey)->ignore
    }
  })
  ->Promise.catchResolve(exn => {
    onError(~inputKey=arg.cacheKey, ~exn)
  })
  ->Promise.finally(() => {
    effect.activeCallsCount = effect.activeCallsCount - 1
    Prometheus.EffectCalls.activeCallsCount->Prometheus.SafeGauge.handleInt(
      ~labels=effectName,
      ~value=effect.activeCallsCount,
    )
    let newTimer = Hrtime.makeTimer()
    Prometheus.EffectCalls.timeCounter->Prometheus.SafeCounter.incrementMany(
      ~labels=effectName,
      ~value=Hrtime.millisBetween(~from=effect.prevCallStartTimerRef, ~to=newTimer),
    )
    effect.prevCallStartTimerRef = newTimer

    Prometheus.EffectCalls.totalCallsCount->Prometheus.SafeCounter.increment(~labels=effectName)
    Prometheus.EffectCalls.sumTimeCounter->Prometheus.SafeCounter.incrementMany(
      ~labels=effectName,
      ~value=timerRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis,
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

  let timerRef = Hrtime.makeTimer()
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
        )->Promise.ignoreValue,
      )
      ->ignore
    }

  | Some(state) =>
    let now = Js.Date.now()

    // Check if we need to reset the window
    if now >= state.windowStartTime +. state.durationMs->Int.toFloat {
      state.availableCalls = state.callsPerDuration
      state.windowStartTime = now
      state.nextWindowPromise = None
    }

    // Split into immediate and queued
    let immediateCount = Js.Math.min_int(state.availableCalls, effectArgs->Array.length)
    let immediateArgs = effectArgs->Array.slice(~offset=0, ~len=immediateCount)
    let queuedArgs = effectArgs->Array.sliceToEnd(immediateCount)

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
        )->Promise.ignoreValue,
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
            Prometheus.EffectQueueCount.timeCounter->Prometheus.SafeCounter.incrementMany(
              ~labels=effectName,
              ~value=millisUntilReset.contents,
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
        ->Promise.ignoreValue,
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
  ~inMemoryStore,
  ~shouldGroup,
  ~item,
) => {
  let effectName = effect.name
  let key = `${effectName}.effect`
  let inMemTable = inMemoryStore->InMemoryStore.getEffectInMemTable(~effect)

  let load = async (args, ~onError) => {
    let idsToLoad = args->Js.Array2.map((arg: Internal.effectArgs) => arg.cacheKey)
    let idsFromCache = Utils.Set.make()

    if (
      switch persistence.storageStatus {
      | Ready({cache}) => cache->Utils.Dict.has(effectName)
      | _ => false
      }
    ) {
      let timerRef = Prometheus.StorageLoad.startOperation(~operation=key)
      let {table, outputSchema} = effect.storageMeta

      let dbEntities = try {
        await (persistence->Persistence.getInitializedStorageOrThrow).loadByIdsOrThrow(
          ~table,
          ~rowsSchema=Internal.effectCacheItemRowsSchema,
          ~ids=idsToLoad,
        )
      } catch {
      | exn =>
        item
        ->Logging.getItemLogger
        ->Logging.childWarn({
          "msg": `Failed to load cache effect cache. The indexer will continue working, but the effect will not be able to use the cache.`,
          "err": exn->Utils.prettifyExn,
          "effect": effectName,
        })
        []
      }

      dbEntities->Js.Array2.forEach(dbEntity => {
        try {
          let output = dbEntity.output->S.parseOrThrow(outputSchema)
          idsFromCache->Utils.Set.add(dbEntity.id)->ignore
          inMemTable.dict->Js.Dict.set(dbEntity.id, output)
        } catch {
        | S.Raised(error) =>
          inMemTable.invalidationsCount = inMemTable.invalidationsCount + 1
          Prometheus.EffectCacheInvalidationsCount.increment(~effectName)
          item
          ->Logging.getItemLogger
          ->Logging.childTrace({
            "msg": "Invalidated effect cache",
            "input": dbEntity.id,
            "effect": effectName,
            "err": error->S.Error.message,
          })
        }
      })

      timerRef->Prometheus.StorageLoad.endOperation(
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
        )->Promise.ignoreValue
      }
    }
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~shouldGroup,
    ~hasher=args => args.cacheKey,
    ~getUnsafeInMemory=hash => inMemTable.dict->Js.Dict.unsafeGet(hash),
    ~hasInMemory=hash => inMemTable.dict->Utils.Dict.has(hash),
    ~input=effectArgs,
  )
}

let loadByField = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~operator: TableIndices.Operator.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore,
  ~fieldName,
  ~fieldValueSchema,
  ~shouldGroup,
  ~item,
  ~fieldValue,
) => {
  let operatorCallName = switch operator {
  | Eq => "eq"
  | Gt => "gt"
  | Lt => "lt"
  }
  let key = `${entityConfig.name}.getWhere.${fieldName}.${operatorCallName}`
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityConfig)

  let load = async (fieldValues: array<'fieldValue>, ~onError as _) => {
    let timerRef = Prometheus.StorageLoad.startOperation(~operation=key)

    let size = ref(0)

    let indiciesToLoad = fieldValues->Js.Array2.map((fieldValue): TableIndices.Index.t => {
      Single({
        fieldName,
        fieldValue: TableIndices.FieldValue.castFrom(fieldValue),
        operator,
      })
    })

    let _ =
      await indiciesToLoad
      ->Js.Array2.map(async index => {
        inMemTable->InMemoryTable.Entity.addEmptyIndex(~index)
        try {
          let entities = await (
            persistence->Persistence.getInitializedStorageOrThrow
          ).loadByFieldOrThrow(
            ~operator=switch index {
            | Single({operator: Gt}) => #">"
            | Single({operator: Eq}) => #"="
            | Single({operator: Lt}) => #"<"
            },
            ~table=entityConfig.table,
            ~rowsSchema=entityConfig.rowsSchema,
            ~fieldName=index->TableIndices.Index.getFieldName,
            ~fieldValue=switch index {
            | Single({fieldValue}) => fieldValue
            },
            ~fieldSchema=fieldValueSchema->(
              Utils.magic: S.t<'fieldValue> => S.t<TableIndices.FieldValue.t>
            ),
          )

          entities->Array.forEach(entity => {
            //Set the entity in the in memory store
            inMemTable->InMemoryTable.Entity.initValue(
              ~allowOverWriteEntity=false,
              ~key=Entities.getEntityId(entity),
              ~entity=Some(entity),
            )
          })

          size := size.contents + entities->Array.length
        } catch {
        | Persistence.StorageError({message, reason}) =>
          reason->ErrorHandling.mkLogAndRaise(
            ~logger=Logging.createChildFrom(
              ~logger=item->Logging.getItemLogger,
              ~params={
                "operator": operatorCallName,
                "tableName": entityConfig.table.tableName,
                "fieldName": fieldName,
                "fieldValue": fieldValue,
              },
            ),
            ~msg=message,
          )
        }
      })
      ->Promise.all

    timerRef->Prometheus.StorageLoad.endOperation(
      ~operation=key,
      ~whereSize=fieldValues->Array.length,
      ~size=size.contents,
    )
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~input=fieldValue,
    ~shouldGroup,
    ~hasher=fieldValue =>
      fieldValue->TableIndices.FieldValue.castFrom->TableIndices.FieldValue.toString,
    ~getUnsafeInMemory=inMemTable->InMemoryTable.Entity.getUnsafeOnIndex(~fieldName, ~operator),
    ~hasInMemory=inMemTable->InMemoryTable.Entity.hasIndex(~fieldName, ~operator),
  )
}
