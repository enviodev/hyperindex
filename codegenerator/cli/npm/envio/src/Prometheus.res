let loadEntitiesDurationCounter = PromClient.Counter.makeCounter({
  "name": "load_entities_processing_time_spent",
  "help": "Duration spend on loading entities",
  "labelNames": [],
})

let eventRouterDurationCounter = PromClient.Counter.makeCounter({
  "name": "event_router_processing_time_spent",
  "help": "Duration spend on event routing",
  "labelNames": [],
})

let executeBatchDurationCounter = PromClient.Counter.makeCounter({
  "name": "execute_batch_processing_time_spent",
  "help": "Duration spend on executing batch",
  "labelNames": [],
})

let allChainsSyncedToHead = PromClient.Gauge.makeGauge({
  "name": "hyperindex_synced_to_head",
  "help": "All chains fully synced",
  "labelNames": [],
})

let sourceChainHeight = PromClient.Gauge.makeGauge({
  "name": "chain_block_height",
  "help": "Chain Height of Source Chain",
  "labelNames": ["chainId"],
})

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
  let handleFloat = PromClient.Counter.incMany->Utils.magic
})

module SafeGauge = MakeSafePromMetric({
  type t = PromClient.Gauge.gauge
  let make = PromClient.Gauge.makeGauge
  let labels = PromClient.Gauge.labels
  let handleInt = PromClient.Gauge.set
  let handleFloat = PromClient.Gauge.setFloat
})

let makeSafeHistogramOrThrow = (~name, ~help, ~labelSchema, ~backets=?) => {
  let histogram = PromClient.Histogram.make({
    "name": name,
    "help": help,
    "labelNames": labelSchema->Labels.getLabelNames->Belt.Result.getExn,
    "buckets": backets,
  })

  labels => {
    histogram
    ->PromClient.Histogram.labels(labels->S.reverseConvertToJsonOrThrow(labelSchema))
    ->PromClient.Histogram.startTimer
  }
}

module BenchmarkSummaryData = {
  type labels = {
    group: string,
    stat: string,
    label: string,
  }
  let labelSchema = S.schema(s => {
    group: s.matches(S.string),
    stat: s.matches(S.string),
    label: s.matches(S.string),
  })

  let gauge = SafeGauge.makeOrThrow(
    ~name="benchmark_summary_data",
    ~help="All data points collected during indexer benchmark",
    ~labelSchema,
  )

  let set = (
    ~group: string,
    ~label: string,
    ~n: float,
    ~mean: float,
    ~stdDev: option<float>,
    ~min: float,
    ~max: float,
    ~sum: float,
  ) => {
    let mk = stat => {
      group,
      stat,
      label,
    }
    gauge->SafeGauge.handleFloat(~labels=mk("n"), ~value=n)
    gauge->SafeGauge.handleFloat(~labels=mk("mean"), ~value=mean)
    gauge->SafeGauge.handleFloat(~labels=mk("min"), ~value=min)
    gauge->SafeGauge.handleFloat(~labels=mk("max"), ~value=max)
    gauge->SafeGauge.handleFloat(~labels=mk("sum"), ~value=sum)
    switch stdDev {
    | Some(stdDev) => gauge->SafeGauge.handleFloat(~labels=mk("stdDev"), ~value=stdDev)
    | None => ()
    }
  }
}

let incrementLoadEntityDurationCounter = (~duration) => {
  loadEntitiesDurationCounter->PromClient.Counter.incMany(duration)
}

let incrementEventRouterDurationCounter = (~duration) => {
  eventRouterDurationCounter->PromClient.Counter.incMany(duration)
}

let incrementExecuteBatchDurationCounter = (~duration) => {
  executeBatchDurationCounter->PromClient.Counter.incMany(duration)
}

let setSourceChainHeight = (~blockNumber, ~chain) => {
  sourceChainHeight
  ->PromClient.Gauge.labels({"chainId": chain->ChainMap.Chain.toString})
  ->PromClient.Gauge.set(blockNumber)
}

let setAllChainsSyncedToHead = () => {
  allChainsSyncedToHead->PromClient.Gauge.set(1)
}

module BenchmarkCounters = {
  type labels = {label: string}
  let labelSchema = S.schema(s => {
    label: s.matches(S.string),
  })

  let gauge = SafeGauge.makeOrThrow(
    ~name="benchmark_counters",
    ~help="All counters collected during indexer benchmark",
    ~labelSchema,
  )

  let set = (~label, ~millis, ~totalRuntimeMillis) => {
    gauge->SafeGauge.handleFloat(~labels={label: label}, ~value=millis)
    gauge->SafeGauge.handleFloat(~labels={label: "Total Run Time (ms)"}, ~value=totalRuntimeMillis)
  }
}

module PartitionBlockFetched = {
  type labels = {chainId: int, partitionId: string}

  let labelSchema = S.schema(s => {
    chainId: s.matches(S.string->S.coerce(S.int)),
    partitionId: s.matches(S.string),
  })

  let counter = SafeGauge.makeOrThrow(
    ~name="partition_block_fetched",
    ~help="The latest fetched block number for each partition",
    ~labelSchema,
  )

  let set = (~blockNumber, ~partitionId, ~chainId) => {
    counter->SafeGauge.handleInt(~labels={chainId, partitionId}, ~value=blockNumber)
  }
}

let chainIdLabelsSchema = S.object(s => {
  s.field("chainId", S.string->S.coerce(S.int))
})

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
    ~name="envio_indexing_idle_time",
    ~help="The number of milliseconds the indexer source syncing has been idle. A high value may indicate the source sync is a bottleneck.",
    ~labelSchema=chainIdLabelsSchema,
  )
}

module IndexingSourceWaitingTime = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_indexing_source_waiting_time",
    ~help="The number of milliseconds the indexer has been waiting for new blocks.",
    ~labelSchema=chainIdLabelsSchema,
  )
}

module IndexingQueryTime = {
  let counter = SafeCounter.makeOrThrow(
    ~name="envio_indexing_query_time",
    ~help="The number of milliseconds spent performing queries to the chain data-source.",
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
  let deprecatedGauge = PromClient.Gauge.makeGauge({
    "name": "chain_block_height_fully_fetched",
    "help": "Block height fully fetched by indexer",
    "labelNames": ["chainId"],
  })

  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_indexing_buffer_block_number",
    ~help="The highest block number that has been fully fetched by the indexer.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chainId) => {
    deprecatedGauge
    ->PromClient.Gauge.labels({"chainId": chainId})
    ->PromClient.Gauge.set(blockNumber)
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

module SourceHeight = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_source_height",
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

module SourceGetHeightDuration = {
  let startTimer = makeSafeHistogramOrThrow(
    ~name="envio_source_get_height_duration",
    ~help="Duration of the source get height requests in seconds",
    ~labelSchema=sourceLabelsSchema,
    ~backets=[0.1, 0.5, 1., 10.],
  )
}

module ReorgCount = {
  let deprecatedCounter = PromClient.Counter.makeCounter({
    "name": "reorgs_detected",
    "help": "Total number of reorgs detected",
    "labelNames": ["chainId"],
  })

  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_reorg_count",
    ~help="Total number of reorgs detected",
    ~labelSchema=chainIdLabelsSchema,
  )

  let increment = (~chain) => {
    deprecatedCounter
    ->PromClient.Counter.labels({"chainId": chain->ChainMap.Chain.toString})
    ->PromClient.Counter.inc
    gauge->SafeGauge.increment(~labels=chain->ChainMap.Chain.toChainId)
  }
}

module ReorgDetectionBlockNumber = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_reorg_detection_block_number",
    ~help="The block number where reorg was detected the last time. This doesn't mean that the block was reorged, this is simply where we found block hash to be different.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chain) => {
    gauge->SafeGauge.handleInt(~labels=chain->ChainMap.Chain.toChainId, ~value=blockNumber)
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

module RollbackDuration = {
  let histogram = PromClient.Histogram.make({
    "name": "envio_rollback_duration",
    "help": "Rollback on reorg duration in seconds",
    "buckets": [0.5, 1., 5., 10.],
  })

  let startTimer = () => {
    histogram->PromClient.Histogram.startTimer
  }
}

module RollbackTargetBlockNumber = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_rollback_target_block_number",
    ~help="The block number reorg was rollbacked to the last time.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chain) => {
    gauge->SafeGauge.handleInt(~labels=chain->ChainMap.Chain.toChainId, ~value=blockNumber)
  }
}

module ProcessingBlockNumber = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_processing_block_number",
    ~help="The latest item block number included in the currently processing batch for the chain.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=blockNumber)
  }
}

module ProcessingBatchSize = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_processing_batch_size",
    ~help="The number of items included in the currently processing batch for the chain.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~batchSize, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=batchSize)
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
    ~name="envio_progress_block_number",
    ~help="The block number of the latest block processed and stored in the database.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~blockNumber, ~chainId) => {
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=blockNumber)
  }
}

module ProgressEventsCount = {
  let deprecatedGauge = PromClient.Gauge.makeGauge({
    "name": "events_processed",
    "help": "Total number of events processed",
    "labelNames": ["chainId"],
  })

  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_progress_events_count",
    ~help="The number of events processed and reflected in the database.",
    ~labelSchema=chainIdLabelsSchema,
  )

  let set = (~processedCount, ~chainId) => {
    deprecatedGauge
    ->PromClient.Gauge.labels({"chainId": chainId})
    ->PromClient.Gauge.set(processedCount)
    gauge->SafeGauge.handleInt(~labels=chainId, ~value=processedCount)
  }
}

let effectLabelsSchema = S.object(s => {
  s.field("effect", S.string)
})

module EffectCallsCount = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_effect_calls_count",
    ~help="The number of calls to the effect. Including both handler execution and cache hits.",
    ~labelSchema=effectLabelsSchema,
  )

  let set = (~callsCount, ~effectName) => {
    gauge->SafeGauge.handleInt(~labels=effectName, ~value=callsCount)
  }
}

module EffectCacheCount = {
  let gauge = SafeGauge.makeOrThrow(
    ~name="envio_effect_cache_count",
    ~help="The number of items in the effect cache.",
    ~labelSchema=effectLabelsSchema,
  )

  let set = (~count, ~effectName) => {
    gauge->SafeGauge.handleInt(~labels=effectName, ~value=count)
  }
}
