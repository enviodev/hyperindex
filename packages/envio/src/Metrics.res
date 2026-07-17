type chainMetrics = {
  chainId: float,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  numEventsProcessed: float,
  latestFetchedBlockNumber: int,
  // Clamped to endBlock once the chain has processed to it.
  knownHeight: int,
  numBatchesFetched: int,
  startBlock: int,
  endBlock: option<int>,
  numAddresses: int,
  isReady: bool,
  // Raw source height, unlike knownHeight which is clamped to endBlock.
  sourceBlockNumber: int,
  // Raw committed progress (may be -1), unlike the optional latestProcessedBlock.
  progressBlockNumber: int,
  progressLatencyMs: option<int>,
  concurrency: int,
  partitionsCount: int,
  bufferSize: int,
  // Raw buffer block (may be -1), unlike the clamped latestFetchedBlockNumber.
  bufferBlockNumber: int,
  idleSeconds: float,
  waitingForNewBlockSeconds: float,
  queryingSeconds: float,
  blockRangeFetchSeconds: float,
  blockRangeParseSeconds: float,
  blockRangeFetchCount: float,
  blockRangeFetchedEvents: float,
  blockRangeFetchedBlocks: float,
  reorgCount: int,
  reorgDetectedBlock: option<int>,
  rollbackTargetBlock: option<int>,
}

type handlerMetrics = {
  contract: string,
  event: string,
  processingSeconds: float,
  processingCount: float,
  preloadSeconds: float,
  preloadCount: float,
  preloadSecondsTotal: float,
}

type effectMetrics = {
  effect: string,
  scope: string,
  callSeconds: float,
  callSecondsTotal: float,
  callCount: float,
  activeCallsCount: int,
  queueCount: int,
  queueWaitSeconds: float,
  invalidationsCount: float,
  // None for effects that don't persist their cache.
  cacheCount: option<int>,
}

type storageLoadMetrics = {
  operation: string,
  storage: string,
  seconds: float,
  secondsTotal: float,
  count: float,
  whereSize: float,
  size: float,
}

type storageWriteMetrics = {
  storage: string,
  seconds: float,
  count: int,
}

type historyPruneMetrics = {
  entity: string,
  seconds: float,
  count: int,
}

type sourceRequestMetrics = {
  source: string,
  chainId: int,
  method: string,
  count: int,
  seconds: float,
}

type sourceHeightMetrics = {
  source: string,
  chainId: int,
  height: int,
}

type t = {
  startTime: Date.t,
  targetBufferSize: int,
  isInReorgThreshold: bool,
  rollbackEnabled: bool,
  maxBatchSize: int,
  preloadSeconds: float,
  processingSeconds: float,
  rollbackSeconds: float,
  rollbackCount: int,
  rollbackEventsCount: float,
  chains: array<chainMetrics>,
  handlers: array<handlerMetrics>,
  effects: array<effectMetrics>,
  storageLoads: array<storageLoadMetrics>,
  storageWrites: array<storageWriteMetrics>,
  historyPrunes: array<historyPruneMetrics>,
  sourceRequests: array<sourceRequestMetrics>,
  sourceHeights: array<sourceHeightMetrics>,
}

// Prometheus floats keep at most 3 decimals; integral values render without a
// fractional part.
@inline
let formatValue = (value: float) => (Math.round(value *. 1000.) /. 1000.)->Float.toString

// Prometheus exposition-format escaping for label values: a raw `"`, `\` or
// newline in a user-supplied name (contract, event, effect, ...) would
// otherwise break the scrape.
let escapeLabelValue = (value: string) =>
  if value->String.includes("\\") || value->String.includes("\"") || value->String.includes("\n") {
    value
    ->String.replaceAll("\\", "\\\\")
    ->String.replaceAll("\"", "\\\"")
    ->String.replaceAll("\n", "\\n")
  } else {
    value
  }

// Accumulate into one string rather than building a lines array to join: `++`
// compiles to JS `+=`, which V8 grows as a ConsString instead of recopying.
type builder = {mutable out: string}

// Begin a metric: HELP/TYPE header, with a blank line between metrics.
let block = (b: builder, ~name, ~help, ~kind) => {
  let header = `# HELP ${name} ${help}\n# TYPE ${name} ${kind}`
  b.out = b.out === "" ? header : b.out ++ "\n\n" ++ header
}

let sample = (b: builder, ~name, ~labels="", ~value) =>
  b.out = b.out ++ "\n" ++ name ++ labels ++ " " ++ formatValue(value)

// One metric with a sample per entry. Entries carry their pre-rendered label
// string so the same list feeds several metrics without re-rendering labels.
let series = (
  b: builder,
  ~name,
  ~help,
  ~kind,
  ~entries: array<(string, 'a)>,
  ~value: 'a => float,
) => {
  b->block(~name, ~help, ~kind)
  for i in 0 to entries->Array.length - 1 {
    let (labels, entry) = entries->Array.getUnsafe(i)
    b->sample(~name, ~labels, ~value=value(entry))
  }
}

// Same as series, but an entry can opt out of its sample (e.g. a counter that
// was never incremented or a gauge that was never observed).
let seriesOpt = (
  b: builder,
  ~name,
  ~help,
  ~kind,
  ~entries: array<(string, 'a)>,
  ~value: 'a => option<float>,
) => {
  b->block(~name, ~help, ~kind)
  for i in 0 to entries->Array.length - 1 {
    let (labels, entry) = entries->Array.getUnsafe(i)
    switch value(entry) {
    | Some(value) => b->sample(~name, ~labels, ~value)
    | None => ()
    }
  }
}

let single = (b: builder, ~name, ~help, ~kind, ~value) => {
  b->block(~name, ~help, ~kind)
  b->sample(~name, ~value)
}

let renderMetrics = (b: builder, metrics: t) => {
  let chains = metrics.chains->Array.map(m => (`{chainId="${m.chainId->Float.toString}"}`, m))
  let handlers =
    metrics.handlers->Array.map(s => (
      `{contract="${s.contract->escapeLabelValue}",event="${s.event->escapeLabelValue}"}`,
      s,
    ))
  let effects =
    metrics.effects->Array.map(s => (
      `{effect="${s.effect->escapeLabelValue}",scope="${s.scope}"}`,
      s,
    ))
  let storageLoads =
    metrics.storageLoads->Array.map(s => (
      `{operation="${s.operation->escapeLabelValue}",storage="${s.storage->escapeLabelValue}"}`,
      s,
    ))
  let storageWrites =
    metrics.storageWrites->Array.map(s => (`{storage="${s.storage->escapeLabelValue}"}`, s))
  let historyPrunes =
    metrics.historyPrunes->Array.map(s => (`{entity="${s.entity->escapeLabelValue}"}`, s))
  // Two sources can share a name (e.g. primary and fallback RPC urls on the
  // same host), so aggregate by label set — duplicate samples would make
  // Prometheus reject the scrape.
  let sourceRequests = {
    let byLabels: dict<sourceRequestMetrics> = Dict.make()
    metrics.sourceRequests->Array.forEach(s => {
      let labels = `{source="${s.source->escapeLabelValue}",chainId="${s.chainId->Int.toString}",method="${s.method->escapeLabelValue}"}`
      switch byLabels->Utils.Dict.dangerouslyGetNonOption(labels) {
      | Some(existing) =>
        byLabels->Dict.set(
          labels,
          {...existing, count: existing.count + s.count, seconds: existing.seconds +. s.seconds},
        )
      | None => byLabels->Dict.set(labels, s)
      }
    })
    byLabels->Dict.toArray
  }
  let sources = {
    let byLabels: dict<int> = Dict.make()
    metrics.sourceHeights->Array.forEach(s => {
      let labels = `{source="${s.source->escapeLabelValue}",chainId="${s.chainId->Int.toString}"}`
      switch byLabels->Utils.Dict.dangerouslyGetNonOption(labels) {
      | Some(existing) if existing >= s.height => ()
      | _ => byLabels->Dict.set(labels, s.height)
      }
    })
    byLabels->Dict.toArray
  }

  b->single(
    ~name="envio_preload_seconds",
    ~help="Cumulative time spent on preloading entities during batch processing.",
    ~kind="counter",
    ~value=metrics.preloadSeconds,
  )
  b->single(
    ~name="envio_processing_seconds",
    ~help="Cumulative time spent executing event handlers during batch processing.",
    ~kind="counter",
    ~value=metrics.processingSeconds,
  )
  b->series(
    ~name="envio_progress_ready",
    ~help="Whether the chain is fully synced to the head.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.isReady ? 1. : 0.,
  )
  // Keep legacy metric name for backward compatibility
  b->single(
    ~name="hyperindex_synced_to_head",
    ~help="All chains fully synced",
    ~kind="gauge",
    ~value=metrics.chains->Utils.Array.notEmpty && metrics.chains->Array.every(m => m.isReady)
      ? 1.
      : 0.,
  )
  b->series(
    ~name="envio_processing_handler_seconds",
    ~help="Cumulative time spent inside individual event handler executions.",
    ~kind="counter",
    ~entries=handlers,
    ~value=s => s.processingSeconds,
  )
  b->series(
    ~name="envio_processing_handler_total",
    ~help="Total number of individual event handler executions.",
    ~kind="counter",
    ~entries=handlers,
    ~value=s => s.processingCount,
  )
  b->series(
    ~name="envio_preload_handler_seconds",
    ~help="Wall-clock time spent inside individual preload handler executions.",
    ~kind="counter",
    ~entries=handlers,
    ~value=s => s.preloadSeconds,
  )
  b->series(
    ~name="envio_preload_handler_total",
    ~help="Total number of individual preload handler executions.",
    ~kind="counter",
    ~entries=handlers,
    ~value=s => s.preloadCount,
  )
  b->series(
    ~name="envio_preload_handler_seconds_total",
    ~help="Cumulative time spent inside individual preload handler executions. Can exceed wall-clock time due to parallel execution.",
    ~kind="counter",
    ~entries=handlers,
    ~value=s => s.preloadSecondsTotal,
  )
  b->series(
    ~name="envio_fetching_block_range_seconds",
    ~help="Cumulative time spent fetching block ranges.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.blockRangeFetchSeconds,
  )
  b->series(
    ~name="envio_fetching_block_range_parse_seconds",
    ~help="Cumulative time spent parsing block range fetch responses.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.blockRangeParseSeconds,
  )
  b->series(
    ~name="envio_fetching_block_range_total",
    ~help="Total number of block range fetch operations.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.blockRangeFetchCount,
  )
  b->series(
    ~name="envio_fetching_block_range_events_total",
    ~help="Cumulative number of events fetched across all block range operations.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.blockRangeFetchedEvents,
  )
  b->series(
    ~name="envio_fetching_block_range_size",
    ~help="Cumulative number of blocks covered across all block range fetch operations.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.blockRangeFetchedBlocks,
  )
  b->series(
    ~name="envio_indexing_known_height",
    ~help="The latest known block number reported by the active indexing source. This value may lag behind the actual chain height, as it is updated only when needed.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.sourceBlockNumber->Int.toFloat,
  )
  b->single(
    ~name="envio_process_start_time_seconds",
    ~help="Start time of the process since unix epoch in seconds.",
    ~kind="gauge",
    ~value=metrics.startTime->Date.getTime /. 1000.,
  )
  b->series(
    ~name="envio_indexing_concurrency",
    ~help="The number of executing concurrent queries to the chain data-source.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.concurrency->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_partitions",
    ~help="The number of partitions used to split fetching logic by addresses and block ranges.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.partitionsCount->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_idle_seconds",
    ~help="The time the indexer source syncing has been idle. A high value may indicate the source sync is a bottleneck.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.idleSeconds,
  )
  b->series(
    ~name="envio_indexing_source_waiting_seconds",
    ~help="The time the indexer has been waiting for new blocks.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.waitingForNewBlockSeconds,
  )
  b->series(
    ~name="envio_indexing_source_querying_seconds",
    ~help="The time spent performing queries to the chain data-source.",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.queryingSeconds,
  )
  b->series(
    ~name="envio_indexing_buffer_size",
    ~help="The current number of items in the indexing buffer.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.bufferSize->Int.toFloat,
  )
  b->single(
    ~name="envio_indexing_target_buffer_size",
    ~help="The indexer-wide target buffer size shared across all chains. The actual number of items in the queue may exceed this value, but the indexer always tries to keep the buffer filled up to this target.",
    ~kind="gauge",
    ~value=metrics.targetBufferSize->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_buffer_block",
    ~help="The highest block number that has been fully fetched by the indexer.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.bufferBlockNumber->Int.toFloat,
  )
  b->seriesOpt(
    ~name="envio_indexing_end_block",
    ~help="The block number to stop indexing at. (inclusive)",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.endBlock->Option.map(Int.toFloat),
  )
  b->series(
    ~name="envio_source_request_total",
    ~help="The number of requests made to data sources.",
    ~kind="counter",
    ~entries=sourceRequests,
    ~value=s => s.count->Int.toFloat,
  )
  // Skips a method's seconds line when it has no timing (e.g. heightSubscription,
  // which only ever records a count).
  b->seriesOpt(
    ~name="envio_source_request_seconds_total",
    ~help="Cumulative time spent on data source requests.",
    ~kind="counter",
    ~entries=sourceRequests,
    ~value=s => s.seconds !== 0. ? Some(s.seconds) : None,
  )
  b->series(
    ~name="envio_source_known_height",
    ~help="The latest known block number reported by the source. This value may lag behind the actual chain height, as it is updated only when queried.",
    ~kind="gauge",
    ~entries=sources,
    ~value=height => height->Int.toFloat,
  )
  b->seriesOpt(
    ~name="envio_reorg_detected_total",
    ~help="Total number of reorgs detected",
    ~kind="counter",
    ~entries=chains,
    ~value=m => m.reorgCount > 0 ? Some(m.reorgCount->Int.toFloat) : None,
  )
  b->seriesOpt(
    ~name="envio_reorg_detected_block",
    ~help="The block number where reorg was detected the last time. This doesn't mean that the block was reorged, this is simply where we found block hash to be different.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.reorgDetectedBlock->Option.map(Int.toFloat),
  )
  b->single(
    ~name="envio_reorg_threshold",
    ~help="Whether indexing is currently within the reorg threshold",
    ~kind="gauge",
    ~value=metrics.isInReorgThreshold ? 1. : 0.,
  )
  b->single(
    ~name="envio_rollback_enabled",
    ~help="Whether rollback on reorg is enabled",
    ~kind="gauge",
    ~value=metrics.rollbackEnabled ? 1. : 0.,
  )
  b->single(
    ~name="envio_rollback_seconds",
    ~help="Rollback on reorg total time.",
    ~kind="counter",
    ~value=metrics.rollbackSeconds,
  )
  b->single(
    ~name="envio_rollback_total",
    ~help="Number of successful rollbacks on reorg",
    ~kind="counter",
    ~value=metrics.rollbackCount->Int.toFloat,
  )
  b->single(
    ~name="envio_rollback_events",
    ~help="Number of events rollbacked on reorg",
    ~kind="counter",
    ~value=metrics.rollbackEventsCount,
  )
  b->series(
    ~name="envio_rollback_history_prune_seconds",
    ~help="The total time spent pruning entity history which is not in the reorg threshold.",
    ~kind="counter",
    ~entries=historyPrunes,
    ~value=s => s.seconds,
  )
  b->series(
    ~name="envio_rollback_history_prune_total",
    ~help="Number of successful entity history prunes",
    ~kind="counter",
    ~entries=historyPrunes,
    ~value=s => s.count->Int.toFloat,
  )
  b->seriesOpt(
    ~name="envio_rollback_target_block",
    ~help="The block number reorg was rollbacked to the last time.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.rollbackTargetBlock->Option.map(Int.toFloat),
  )
  b->single(
    ~name="envio_processing_max_batch_size",
    ~help="The maximum number of items to process in a single batch.",
    ~kind="gauge",
    ~value=metrics.maxBatchSize->Int.toFloat,
  )
  b->series(
    ~name="envio_progress_block",
    ~help="The block number of the latest block processed and stored in the database.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.progressBlockNumber->Int.toFloat,
  )
  b->series(
    ~name="envio_progress_events",
    ~help="The number of events processed and reflected in the database.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.numEventsProcessed,
  )
  b->seriesOpt(
    ~name="envio_progress_latency",
    ~help="The latency in milliseconds between the latest processed event creation and the time it was written to storage.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.progressLatencyMs->Option.map(Int.toFloat),
  )
  // Effects that were never called (e.g. seeded from the persisted cache only)
  // get no call samples.
  let ifCalled = (s: effectMetrics, value) =>
    s.callCount > 0. || s.activeCallsCount > 0 ? Some(value) : None
  b->seriesOpt(
    ~name="envio_effect_call_seconds",
    ~help="Processing time taken to call the Effect function.",
    ~kind="counter",
    ~entries=effects,
    ~value=s => s->ifCalled(s.callSeconds),
  )
  b->seriesOpt(
    ~name="envio_effect_call_seconds_total",
    ~help="Cumulative time spent calling the Effect function during the indexing process.",
    ~kind="counter",
    ~entries=effects,
    ~value=s => s->ifCalled(s.callSecondsTotal),
  )
  b->seriesOpt(
    ~name="envio_effect_call_total",
    ~help="Cumulative number of resolved Effect function calls during the indexing process.",
    ~kind="counter",
    ~entries=effects,
    ~value=s => s->ifCalled(s.callCount),
  )
  b->seriesOpt(
    ~name="envio_effect_active_calls",
    ~help="The number of Effect function calls that are currently running.",
    ~kind="gauge",
    ~entries=effects,
    ~value=s => s->ifCalled(s.activeCallsCount->Int.toFloat),
  )
  // Only effects that persist their cache get a sample (including a zero for
  // an existing but empty persisted table); a plain effect gets none.
  b->seriesOpt(
    ~name="envio_effect_cache",
    ~help="The number of items in the effect cache.",
    ~kind="gauge",
    ~entries=effects,
    ~value=s => s.cacheCount->Option.map(Int.toFloat),
  )
  // Unlike the rest of the effect metrics, invalidations and queue waits keep
  // the effect-only label set, aggregated across scopes.
  let effectTotals = {
    let byEffect = Dict.make()
    metrics.effects->Array.forEach(s => {
      switch byEffect->Utils.Dict.dangerouslyGetNonOption(s.effect) {
      | Some((invalidations, queueWaitSeconds)) =>
        byEffect->Dict.set(
          s.effect,
          (invalidations +. s.invalidationsCount, queueWaitSeconds +. s.queueWaitSeconds),
        )
      | None => byEffect->Dict.set(s.effect, (s.invalidationsCount, s.queueWaitSeconds))
      }
    })
    let entries = []
    byEffect->Utils.Dict.forEachWithKey((totals, effect) =>
      entries->Array.push((`{effect="${effect->escapeLabelValue}"}`, totals))
    )
    entries
  }
  b->seriesOpt(
    ~name="envio_effect_cache_invalidations",
    ~help="The number of effect cache invalidations.",
    ~kind="counter",
    ~entries=effectTotals,
    ~value=((invalidations, _)) => invalidations > 0. ? Some(invalidations) : None,
  )
  b->seriesOpt(
    ~name="envio_effect_queue",
    ~help="The number of effect calls waiting in the rate limit queue.",
    ~kind="gauge",
    ~entries=effects,
    ~value=s =>
      s.queueCount > 0 || s.queueWaitSeconds > 0. ? Some(s.queueCount->Int.toFloat) : None,
  )
  b->seriesOpt(
    ~name="envio_effect_queue_wait_seconds",
    ~help="The time spent waiting in the rate limit queue.",
    ~kind="counter",
    ~entries=effectTotals,
    ~value=((_, queueWaitSeconds)) => queueWaitSeconds !== 0. ? Some(queueWaitSeconds) : None,
  )
  b->series(
    ~name="envio_storage_load_seconds",
    ~help="Processing time taken to load data from storage.",
    ~kind="counter",
    ~entries=storageLoads,
    ~value=s => s.seconds,
  )
  b->series(
    ~name="envio_storage_load_seconds_total",
    ~help="Cumulative time spent loading data from storage during the indexing process.",
    ~kind="counter",
    ~entries=storageLoads,
    ~value=s => s.secondsTotal,
  )
  b->series(
    ~name="envio_storage_load_total",
    ~help="Cumulative number of successful storage load operations during the indexing process.",
    ~kind="counter",
    ~entries=storageLoads,
    ~value=s => s.count,
  )
  b->series(
    ~name="envio_storage_load_where_size",
    ~help="Cumulative number of filter conditions ('where' items) used in storage load operations during the indexing process.",
    ~kind="counter",
    ~entries=storageLoads,
    ~value=s => s.whereSize,
  )
  b->series(
    ~name="envio_storage_load_size",
    ~help="Cumulative number of records loaded from storage during the indexing process.",
    ~kind="counter",
    ~entries=storageLoads,
    ~value=s => s.size,
  )
  b->series(
    ~name="envio_storage_write_seconds",
    ~help="Cumulative time spent writing batch data to storage.",
    ~kind="counter",
    ~entries=storageWrites,
    ~value=s => s.seconds,
  )
  b->series(
    ~name="envio_storage_write_total",
    ~help="Cumulative number of successful storage write operations during the indexing process.",
    ~kind="counter",
    ~entries=storageWrites,
    ~value=s => s.count->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_addresses",
    ~help="The number of addresses indexed on chain. Includes both static and dynamic addresses.",
    ~kind="gauge",
    ~entries=chains,
    ~value=m => m.numAddresses->Int.toFloat,
  )
}

let collect = (~metrics: option<t>) => {
  let b = {out: ""}
  b->series(
    ~name="envio_info",
    ~help="Information about the indexer",
    ~kind="gauge",
    ~entries=[(`{version="${Utils.EnvioPackage.value.version->escapeLabelValue}"}`, ())],
    ~value=() => 1.,
  )
  switch metrics {
  | Some(metrics) => b->renderMetrics(metrics)
  | None => ()
  }
  b.out ++ "\n"
}
