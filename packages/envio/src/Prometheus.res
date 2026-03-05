module Labels = {
  let rec schemaIsString = (schema: S.t<'a>) =>
    switch schema->S.classify {
    | String => true
    | Null(s)
    | Option(s) =>
      s->schemaIsString
    | _ => false
    }

  let getLabelNames = (schema: S.t<'a>) =>
    switch schema->S.classify {
    | Object({items}) =>
      let nonStringFields = items->Belt.Array.reduce([], (nonStringFields, item) => {
        if item.schema->schemaIsString {
          nonStringFields
        } else {
          nonStringFields->Belt.Array.concat([item.location])
        }
      })

      switch nonStringFields {
      | [] => items->Belt.Array.map(item => item.location)->Ok
      | nonStringItems =>
        let nonStringItems = nonStringItems->Js.Array2.joinWith(", ")
        Error(
          `Label schema must be an object with string (or optional string) values. Non string values: ${nonStringItems}`,
        )
      }
    | _ => Error("Label schema must be an object")
    }
}

let metricNames: Utils.Set.t<string> = Utils.Set.make()

module MakeSafePromMetric = (
  M: {
    type t
    let make: {"name": string, "help": string, "labelNames": array<string>} => t
    let labels: (t, 'a) => t
    let handleFloat: (t, float) => unit
    let handleInt: (t, int) => unit
  },
): {
  type t<'a>
  let makeOrThrow: (~name: string, ~help: string, ~labelSchema: S.t<'a>) => t<'a>
  let handleInt: (t<'a>, ~labels: 'a, ~value: int) => unit
  let handleFloat: (t<'a>, ~labels: 'a, ~value: float) => unit
  let increment: (t<'a>, ~labels: 'a) => unit
  let incrementMany: (t<'a>, ~labels: 'a, ~value: int) => unit
} => {
  type t<'a> = {metric: M.t, labelSchema: S.t<'a>}

  let makeOrThrow = (~name, ~help, ~labelSchema: S.t<'a>): t<'a> =>
    switch labelSchema->Labels.getLabelNames {
    | Ok(labelNames) =>
      if metricNames->Utils.Set.has(name) {
        Js.Exn.raiseError("Duplicate prometheus metric name: " ++ name)
      } else {
        metricNames->Utils.Set.add(name)->ignore
        let metric = M.make({
          "name": name,
          "help": help,
          "labelNames": labelNames,
        })

        {metric, labelSchema}
      }

    | Error(error) => Js.Exn.raiseError(error)
    }

  let handleFloat = ({metric, labelSchema}: t<'a>, ~labels: 'a, ~value) =>
    metric
    ->M.labels(labels->S.reverseConvertToJsonOrThrow(labelSchema))
    ->M.handleFloat(value)

  let handleInt = ({metric, labelSchema}: t<'a>, ~labels: 'a, ~value) =>
    metric
    ->M.labels(labels->S.reverseConvertToJsonOrThrow(labelSchema))
    ->M.handleInt(value)

  let increment = ({metric, labelSchema}: t<'a>, ~labels: 'a) =>
    (
      metric
      ->M.labels(labels->S.reverseConvertToJsonOrThrow(labelSchema))
      ->Obj.magic
    )["inc"]()

  let incrementMany = ({metric, labelSchema}: t<'a>, ~labels: 'a, ~value) =>
    (
      metric
      ->M.labels(labels->S.reverseConvertToJsonOrThrow(labelSchema))
      ->Obj.magic
    )["inc"](value)
}

module SafeCounter = MakeSafePromMetric({
  type t = PromClient.Counter.counter
  let make = PromClient.Counter.makeCounter
  let labels = PromClient.Counter.labels
  let handleInt = PromClient.Counter.incMany
  let handleFloat = PromClient.Counter.incMany->(Utils.magic: ((PromClient.Counter.counter, int) => unit) => ((PromClient.Counter.counter, float) => unit))
})

module SafeGauge = MakeSafePromMetric({
  type t = PromClient.Gauge.gauge
  let make = PromClient.Gauge.makeGauge
  let labels = PromClient.Gauge.labels
  let handleInt = PromClient.Gauge.set
  let handleFloat = PromClient.Gauge.setFloat
})


module ProcessingBatch = {
  let loadTimeCounter = PromClient.Counter.makeCounter({
    "name": "envio_preload_seconds",
    "help": "Cumulative time spent on preloading entities during batch processing.",
  })

  let handlerTimeCounter = PromClient.Counter.makeCounter({
    "name": "envio_processing_seconds",
    "help": "Cumulative time spent executing event handlers during batch processing.",
  })

  let writeTimeCounter = PromClient.Counter.makeCounter({
    "name": "envio_storage_write_seconds",
    "help": "Cumulative time spent writing batch data to storage.",
  })

  let writeSumTimeCounter = PromClient.Counter.makeCounter({
    "name": "envio_storage_write_seconds_total",
    "help": "Cumulative time spent on storage write operations during the indexing process.",
  })

  let writeCount = PromClient.Counter.makeCounter({
    "name": "envio_storage_write_total",
    "help": "Total number of batch writes to storage.",
  })

  let registerMetrics = (~loadDuration, ~handlerDuration, ~dbWriteDuration) => {
    loadTimeCounter->PromClient.Counter.incMany(loadDuration->(Utils.magic: float => int))
    handlerTimeCounter->PromClient.Counter.incMany(handlerDuration->(Utils.magic: float => int))
    writeTimeCounter->PromClient.Counter.incMany(dbWriteDuration->(Utils.magic: float => int))
    writeSumTimeCounter->PromClient.Counter.incMany(dbWriteDuration->(Utils.magic: float => int))
    writeCount->PromClient.Counter.inc
  }
}

let chainIdLabelsSchema = S.object(s => {
  s.field("chainId", S.string->S.coerce(S.int))
})

module ProgressReady = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_progress_ready",
    ~help="Whether the chain is fully synced to the head.",
    ~labelSchema=chainIdLabelsSchema,
  )

  // Keep legacy metric name for backward compatibility
  let legacyGauge = PromClient.Gauge.makeGauge({
    "name": "hyperindex_synced_to_head",
    "help": "All chains fully synced",
  })

  let set = (~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=1)
  }

  let setAllReady = () => {
    legacyGauge->PromClient.Gauge.set(1)
  }
}

let handlerLabelsSchema = S.schema(s =>
  {
    "contract": s.matches(S.string),
    "event": s.matches(S.string),
  }
)

module ProcessingHandler = {
  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_processing_handler_seconds",
    ~help="Cumulative time spent inside individual event handler executions.",
    ~labelSchema=handlerLabelsSchema,
  )

  let count = SafeCounter.makeOrThrow(
    ~name="envio_processing_handler_total",
    ~help="Total number of individual event handler executions.",
    ~labelSchema=handlerLabelsSchema,
  )

  let increment = (~contract, ~event, ~duration) => {
    let labels = {"contract": contract, "event": event}
    timeCounter->SafeCounter.handleFloat(~labels, ~value=duration)
    count->SafeCounter.increment(~labels)
  }
}

module PreloadHandler = {
  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_preload_handler_seconds",
    ~help="Wall-clock time spent inside individual preload handler executions.",
    ~labelSchema=handlerLabelsSchema,
  )

  let count = SafeCounter.makeOrThrow(
    ~name="envio_preload_handler_total",
    ~help="Total number of individual preload handler executions.",
    ~labelSchema=handlerLabelsSchema,
  )

  let sumTimeCounter = SafeCounter.makeOrThrow(
    ~name="envio_preload_handler_seconds_total",
    ~help="Cumulative time spent inside individual preload handler executions. Can exceed wall-clock time due to parallel execution.",
    ~labelSchema=handlerLabelsSchema,
  )

  type operationRef = {
    mutable pendingCount: int,
    timerRef: Hrtime.timeRef,
  }
  let operations: Js.Dict.t<operationRef> = Js.Dict.empty()

  let makeKey = (~contract, ~event) => contract ++ ":" ++ event

  let startOperation = (~contract, ~event) => {
    let key = makeKey(~contract, ~event)
    switch operations->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(operationRef) => operationRef.pendingCount = operationRef.pendingCount + 1
    | None =>
      operations->Js.Dict.set(
        key,
        {
          pendingCount: 1,
          timerRef: Hrtime.makeTimer(),
        },
      )
    }
    Hrtime.makeTimer()
  }

  let endOperation = (timerRef, ~contract, ~event) => {
    let key = makeKey(~contract, ~event)
    let labels = {"contract": contract, "event": event}
    let operationRef = operations->Js.Dict.unsafeGet(key)
    operationRef.pendingCount = operationRef.pendingCount - 1
    if operationRef.pendingCount === 0 {
      timeCounter->SafeCounter.handleFloat(
        ~labels,
        ~value=operationRef.timerRef->Hrtime.timeSince->Hrtime.toSecondsFloat,
      )
      operations->Utils.Dict.deleteInPlace(key)
    }
    sumTimeCounter->SafeCounter.handleFloat(
      ~labels,
      ~value=timerRef->Hrtime.timeSince->Hrtime.toSecondsFloat,
    )
    count->SafeCounter.increment(~labels)
  }
}


module FetchingBlockRange = {
  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_fetching_block_range_seconds",
    ~help="Cumulative time spent fetching block ranges.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let parseTimeCounter = SafeCounter.makeOrThrow(
    ~name="envio_fetching_block_range_parse_seconds",
    ~help="Cumulative time spent parsing block range fetch responses.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let count = SafeCounter.makeOrThrow(
    ~name="envio_fetching_block_range_total",
    ~help="Total number of block range fetch operations.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let eventsCount = SafeCounter.makeOrThrow(
    ~name="envio_fetching_block_range_events_total",
    ~help="Cumulative number of events fetched across all block range operations.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let sizeCounter = SafeCounter.makeOrThrow(
    ~name="envio_fetching_block_range_size",
    ~help="Cumulative number of blocks covered across all block range fetch operations.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let increment = (
    ~chainId,
    ~totalTimeElapsed,
    ~parsingTimeElapsed,
    ~numEvents,
    ~blockRangeSize,
  ) => {
    timeCounter->SafeCounter.handleFloat(~labels=chainId, ~value=totalTimeElapsed)
    parseTimeCounter->SafeCounter.handleFloat(~labels=chainId, ~value=parsingTimeElapsed)
    count->SafeCounter.increment(~labels=chainId)
    eventsCount->SafeCounter.handleInt(~labels=chainId, ~value=numEvents)
    sizeCounter->SafeCounter.handleInt(~labels=chainId, ~value=blockRangeSize)
  }
}

module IndexingKnownHeight = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_known_height",
    ~help="The latest known block number reported by the active indexing source. This value may lag behind the actual chain height, as it is updated only when needed.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=blockNumber)
  }
}

module Info = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_info",
    ~help="Information about the indexer",
    ~labelSchema=S.schema(s =>
      {
        "version": s.matches(S.string),
      }
    ),
  )

  let set = (~version) => {
    gauge->SafeGauge.handleInt(~labels={"version": version}, ~value=1)
  }
}

module IndexingAddresses = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_addresses",
    ~help="The number of addresses indexed on chain. Includes both static and dynamic addresses.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~addressesCount, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=addressesCount)
  }
}

module IndexingMaxConcurrency = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_max_concurrency",
    ~help="The maximum number of concurrent queries to the chain data-source.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~maxConcurrency, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=maxConcurrency)
  }
}

module IndexingConcurrency = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_concurrency",
    ~help="The number of executing concurrent queries to the chain data-source.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~concurrency, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=concurrency)
  }
}

module IndexingPartitions = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_partitions",
    ~help="The number of partitions used to split fetching logic by addresses and block ranges.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~partitionsCount, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=partitionsCount)
  }
}

module IndexingIdleTime = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_indexing_idle_seconds",
    ~help="The time the indexer source syncing has been idle. A high value may indicate the source sync is a bottleneck.",
    ~labelSchema=chainIdLabelsSchema,
  )
}

module IndexingSourceWaitingTime = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_indexing_source_waiting_seconds",
    ~help="The time the indexer has been waiting for new blocks.",
    ~labelSchema=chainIdLabelsSchema,
  )
}

module IndexingQueryTime = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_indexing_source_querying_seconds",
    ~help="The time spent performing queries to the chain data-source.",
    ~labelSchema=chainIdLabelsSchema,
  )
}

module IndexingBufferSize = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_buffer_size",
    ~help="The current number of items in the indexing buffer.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~bufferSize, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=bufferSize)
  }
}

module IndexingTargetBufferSize = {
  let gauge = PromClient.Gauge.makeGauge({
    "name": "envio_indexing_target_buffer_size",
    "help": "The target buffer size per chain for indexing. The actual number of items in the queue may exceed this value, but the indexer always tries to keep the buffer filled up to this target.",
  })

  let set = (~targetBufferSize) => {
    gauge->PromClient.Gauge.set(targetBufferSize)
  }
}

module IndexingBufferBlockNumber = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_buffer_block",
    ~help="The highest block number that has been fully fetched by the indexer.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=blockNumber)
  }
}

module IndexingEndBlock = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_end_block",
    ~help="The block number to stop indexing at. (inclusive)",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~endBlock, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=endBlock)
  }
}

let sourceLabelsSchema = S.schema(s =>
  {
    "source": s.matches(S.string),
    "chainId": s.matches(S.string->S.coerce(S.int)),
  }
)

let sourceRequestLabelsSchema = S.schema(s =>
  {
    "source": s.matches(S.string),
    "chainId": s.matches(S.string->S.coerce(S.int)),
    "method": s.matches(S.string),
  }
)

module SourceRequestCount = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_source_request_total",
    ~help="The number of requests made to data sources.",
    ~labelSchema=sourceRequestLabelsSchema,
  )

  let sumTimeCounter = SafeCounter.makeOrThrow(
    ~name="envio_source_request_seconds_total",
    ~help="Cumulative time spent on data source requests.",
    ~labelSchema=sourceRequestLabelsSchema,
  )

  let increment = (~sourceName, ~chainId, ~method) => {
    counter->SafeCounter.increment(
      ~labels={"source": sourceName, "chainId": chainId, "method": method},
    )
  }

  let addSeconds = (~sourceName, ~chainId, ~method, ~seconds) => {
    sumTimeCounter->SafeCounter.handleFloat(
      ~labels={"source": sourceName, "chainId": chainId, "method": method},
      ~value=seconds,
    )
  }
}

module SourceHeight = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_source_known_height",
    ~help="The latest known block number reported by the source. This value may lag behind the actual chain height, as it is updated only when queried.",
    ~labelSchema=sourceLabelsSchema,
  )

  let set = (~sourceName, ~chainId, ~blockNumber) => {
    gauge->SafeGauge.handleInt(
      ~labels={"source": sourceName, "chainId": chainId},
      ~value=blockNumber,
    )
  }
}



module ReorgCount = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_reorg_detected_total",
    ~help="Total number of reorgs detected",
    ~labelSchema=chainIdLabelsSchema,
  )

  let increment = (~chain) => {
    counter->SafeCounter.increment(~labels=chain->ChainMap.Chain.toChainId)
  }
}

module ReorgDetectionBlockNumber = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_reorg_detected_block",
    ~help="The block number where reorg was detected the last time. This doesn't mean that the block was reorged, this is simply where we found block hash to be different.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chain) => {
    gauge->SafeGauge.handleInt(~labels=chain->ChainMap.Chain.toChainId, ~value=blockNumber)
  }
}

module ReorgThreshold = {
  let gauge = PromClient.Gauge.makeGauge({
    "name": "envio_reorg_threshold",
    "help": "Whether indexing is currently within the reorg threshold",
  })

  let set = (~isInReorgThreshold) => {
    gauge->PromClient.Gauge.set(isInReorgThreshold ? 1 : 0)
  }
}

module RollbackEnabled = {
  let gauge = PromClient.Gauge.makeGauge({
    "name": "envio_rollback_enabled",
    "help": "Whether rollback on reorg is enabled",
  })

  let set = (~enabled) => {
    gauge->PromClient.Gauge.set(enabled ? 1 : 0)
  }
}

module RollbackSuccess = {
  let timeCounter = PromClient.Counter.makeCounter({
    "name": "envio_rollback_seconds",
    "help": "Rollback on reorg total time.",
  })

  let counter = PromClient.Counter.makeCounter({
    "name": "envio_rollback_total",
    "help": "Number of successful rollbacks on reorg",
  })

  let eventsCounter = PromClient.Counter.makeCounter({
    "name": "envio_rollback_events",
    "help": "Number of events rollbacked on reorg",
  })

  let increment = (~timeSeconds: float, ~rollbackedProcessedEvents) => {
    timeCounter->PromClient.Counter.incMany(timeSeconds->(Utils.magic: float => int))
    counter->PromClient.Counter.inc
    eventsCounter->PromClient.Counter.incMany(rollbackedProcessedEvents)
  }
}

module RollbackHistoryPrune = {
  let entityNameLabelsSchema = S.object(s => s.field("entity", S.string))

  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_rollback_history_prune_seconds",
    ~help="The total time spent pruning entity history which is not in the reorg threshold.",
    ~labelSchema=entityNameLabelsSchema,
  )

  let counter = SafeCounter.makeOrThrow(
    ~name="envio_rollback_history_prune_total",
    ~help="Number of successful entity history prunes",
    ~labelSchema=entityNameLabelsSchema,
  )

  let increment = (~timeSeconds, ~entityName) => {
    timeCounter->SafeCounter.handleFloat(
      ~labels={entityName},
      ~value=timeSeconds,
    )
    counter->SafeCounter.increment(~labels={entityName})
  }
}

module RollbackTargetBlockNumber = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_rollback_target_block",
    ~help="The block number reorg was rollbacked to the last time.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chain) => {
    gauge->SafeGauge.handleInt(~labels=chain->ChainMap.Chain.toChainId, ~value=blockNumber)
  }
}

module ProcessingMaxBatchSize = {
  let gauge = PromClient.Gauge.makeGauge({
    "name": "envio_processing_max_batch_size",
    "help": "The maximum number of items to process in a single batch.",
  })

  let set = (~maxBatchSize) => {
    gauge->PromClient.Gauge.set(maxBatchSize)
  }
}

module ProgressBlockNumber = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_progress_block",
    ~help="The block number of the latest block processed and stored in the database.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=blockNumber)
  }
}

module ProgressEventsCount = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_progress_events",
    ~help="The number of events processed and reflected in the database.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~processedCount, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=processedCount)
  }
}

module ProgressLatency = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_progress_latency",
    ~help="The latency in milliseconds between the latest processed event creation and the time it was written to storage.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~latencyMs, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=latencyMs)
  }
}

let effectLabelsSchema = S.object(s => {
  s.field("effect", S.string)
})

module EffectCalls = {
  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_effect_call_seconds",
    ~help="Processing time taken to call the Effect function.",
    ~labelSchema=effectLabelsSchema,
  )

  let sumTimeCounter = SafeCounter.makeOrThrow(
    ~name="envio_effect_call_seconds_total",
    ~help="Cumulative time spent calling the Effect function during the indexing process.",
    ~labelSchema=effectLabelsSchema,
  )

  let totalCallsCount = SafeCounter.makeOrThrow(
    ~name="envio_effect_call_total",
    ~help="Cumulative number of resolved Effect function calls during the indexing process.",
    ~labelSchema=effectLabelsSchema,
  )

  let activeCallsCount = SafeGauge.makeOrThrow(
    ~name="envio_effect_active_calls",
    ~help="The number of Effect function calls that are currently running.",
    ~labelSchema=effectLabelsSchema,
  )
}

module EffectCacheCount = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_effect_cache",
    ~help="The number of items in the effect cache.",
    ~labelSchema=effectLabelsSchema,
  )

  let set = (~count, ~effectName) => {
    gauge->SafeGauge.handleInt(~labels=effectName, ~value=count)
  }
}

module EffectCacheInvalidationsCount = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_effect_cache_invalidations",
    ~help="The number of effect cache invalidations.",
    ~labelSchema=effectLabelsSchema,
  )

  let increment = (~effectName) => {
    counter->SafeCounter.increment(~labels=effectName)
  }
}

module EffectQueueCount = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_effect_queue",
    ~help="The number of effect calls waiting in the rate limit queue.",
    ~labelSchema=effectLabelsSchema,
  )

  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_effect_queue_wait_seconds",
    ~help="The time spent waiting in the rate limit queue.",
    ~labelSchema=effectLabelsSchema,
  )

  let set = (~count, ~effectName) => {
    gauge->SafeGauge.handleInt(~labels=effectName, ~value=count)
  }
}

module StorageLoad = {
  let operationLabelsSchema = S.object(s => s.field("operation", S.string))

  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_storage_load_seconds",
    ~help="Processing time taken to load data from storage.",
    ~labelSchema=operationLabelsSchema,
  )

  let sumTimeCounter = SafeCounter.makeOrThrow(
    ~name="envio_storage_load_seconds_total",
    ~help="Cumulative time spent loading data from storage during the indexing process.",
    ~labelSchema=operationLabelsSchema,
  )

  let counter = SafeCounter.makeOrThrow(
    ~name="envio_storage_load_total",
    ~help="Cumulative number of successful storage load operations during the indexing process.",
    ~labelSchema=operationLabelsSchema,
  )

  let whereSizeCounter = SafeCounter.makeOrThrow(
    ~name="envio_storage_load_where_size",
    ~help="Cumulative number of filter conditions ('where' items) used in storage load operations during the indexing process.",
    ~labelSchema=operationLabelsSchema,
  )

  let sizeCounter = SafeCounter.makeOrThrow(
    ~name="envio_storage_load_size",
    ~help="Cumulative number of records loaded from storage during the indexing process.",
    ~labelSchema=operationLabelsSchema,
  )

  type operationRef = {
    mutable pendingCount: int,
    timerRef: Hrtime.timeRef,
  }
  let operations = Js.Dict.empty()

  let startOperation = (~operation) => {
    switch operations->Utils.Dict.dangerouslyGetNonOption(operation) {
    | Some(operationRef) => operationRef.pendingCount = operationRef.pendingCount + 1
    | None =>
      operations->Js.Dict.set(
        operation,
        (
          {
            pendingCount: 1,
            timerRef: Hrtime.makeTimer(),
          }: operationRef
        ),
      )
    }
    Hrtime.makeTimer()
  }

  let endOperation = (timerRef, ~operation, ~whereSize, ~size) => {
    let operationRef = operations->Js.Dict.unsafeGet(operation)
    operationRef.pendingCount = operationRef.pendingCount - 1
    if operationRef.pendingCount === 0 {
      timeCounter->SafeCounter.handleFloat(
        ~labels={operation},
        ~value=operationRef.timerRef->Hrtime.timeSince->Hrtime.toSecondsFloat,
      )
      operations->Utils.Dict.deleteInPlace(operation)
    }
    sumTimeCounter->SafeCounter.handleFloat(
      ~labels={operation},
      ~value=timerRef->Hrtime.timeSince->Hrtime.toSecondsFloat,
    )
    counter->SafeCounter.increment(~labels={operation})
    whereSizeCounter->SafeCounter.handleInt(~labels={operation}, ~value=whereSize)
    sizeCounter->SafeCounter.handleInt(~labels={operation}, ~value=size)
  }
}

module SinkWrite = {
  let sinkLabelsSchema = S.object(s => s.field("sink", S.string))

  let timeCounter = SafeCounter.makeOrThrow(
    ~name="envio_sink_write_seconds",
    ~help="Processing time taken to write data to sink.",
    ~labelSchema=sinkLabelsSchema,
  )

  let counter = SafeCounter.makeOrThrow(
    ~name="envio_sink_write_total",
    ~help="Cumulative number of successful sink write operations during the indexing process.",
    ~labelSchema=sinkLabelsSchema,
  )

  let increment = (~sinkName, ~timeSeconds) => {
    timeCounter->SafeCounter.handleFloat(~labels={sinkName}, ~value=timeSeconds)
    counter->SafeCounter.increment(~labels={sinkName})
  }
}
