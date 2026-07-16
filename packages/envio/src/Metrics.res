// Hand-rolled prometheus text rendering, computed from live indexer state at
// scrape time. No prom-client involved: counters live on IndexerState and its
// sub-states, gauges are derived from the state they describe.

// Prometheus floats keep at most 3 decimals; integral values render without a
// fractional part.
@inline
let formatValue = (value: float) => (Math.round(value *. 1000.) /. 1000.)->Float.toString

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

// An unlabeled metric with its single sample.
let single = (b: builder, ~name, ~help, ~kind, ~value) => {
  b->block(~name, ~help, ~kind)
  b->sample(~name, ~value)
}

let renderIndexerState = (b: builder, state: IndexerState.t) => {
  let config = state->IndexerState.config
  let crossChainState = state->IndexerState.crossChainState
  let chainStates = state->IndexerState.chainStates

  let chains =
    chainStates
    ->Dict.valuesToArray
    ->Array.map(cs => (`{chainId="${(cs->ChainState.chainConfig).id->Int.toString}"}`, cs))
  let handlers =
    state
    ->IndexerState.handlerStats
    ->Dict.valuesToArray
    ->Array.map((s: IndexerState.handlerStat) => (
      `{contract="${s.contract}",event="${s.event}"}`,
      s,
    ))
  let effects = {
    let entries = []
    state
    ->IndexerState.effectState
    ->EffectState.stats
    ->Utils.Dict.forEach((s: EffectState.effectStats) =>
      entries->Array.push((
        `{effect="${s.effectName}",scope="${s.scope->Internal.EffectCache.scopeToString}"}`,
        s,
      ))
    )
    entries
  }
  let storageLoads =
    state
    ->IndexerState.storageLoadStats
    ->Dict.valuesToArray
    ->Array.map((s: IndexerState.storageLoadStat) => (
      `{operation="${s.operation}",storage="${s.storage}"}`,
      s,
    ))
  let storageWrites =
    state
    ->IndexerState.storageWriteStats
    ->Dict.valuesToArray
    ->Array.map((s: IndexerState.storageWriteStat) => (`{storage="${s.storage}"}`, s))
  let historyPrunes = {
    let entries = []
    state
    ->IndexerState.historyPruneStats
    ->Utils.Dict.forEachWithKey((s, entityName) =>
      entries->Array.push((`{entity="${entityName}"}`, s))
    )
    entries
  }
  let sourceRequests = {
    let entries = []
    chainStates->Utils.Dict.forEach(cs =>
      cs
      ->ChainState.sourceManager
      ->SourceManager.getRequestStatSamples
      ->Array.forEach((s: SourceManager.requestStatSample) =>
        entries->Array.push((
          `{source="${s.sourceName}",chainId="${s.chainId->Int.toString}",method="${s.method}"}`,
          s,
        ))
      )
    )
    entries
  }
  let sources = {
    let entries = []
    chainStates->Utils.Dict.forEach(cs =>
      cs
      ->ChainState.sourceManager
      ->SourceManager.getSourceHeightSamples
      ->Array.forEach((s: SourceManager.sourceHeightSample) =>
        entries->Array.push((`{source="${s.sourceName}",chainId="${s.chainId->Int.toString}"}`, s))
      )
    )
    entries
  }

  b->single(
    ~name="envio_preload_seconds",
    ~help="Cumulative time spent on preloading entities during batch processing.",
    ~kind="counter",
    ~value=state->IndexerState.preloadSeconds,
  )
  b->single(
    ~name="envio_processing_seconds",
    ~help="Cumulative time spent executing event handlers during batch processing.",
    ~kind="counter",
    ~value=state->IndexerState.processingSeconds,
  )
  b->series(
    ~name="envio_progress_ready",
    ~help="Whether the chain is fully synced to the head.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.isReady ? 1. : 0.,
  )
  // Keep legacy metric name for backward compatibility
  b->single(
    ~name="hyperindex_synced_to_head",
    ~help="All chains fully synced",
    ~kind="gauge",
    ~value=chains->Utils.Array.notEmpty && chains->Array.every(((_, cs)) => cs->ChainState.isReady)
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
    ~value=s => s.processingCount->Int.toFloat,
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
    ~value=s => s.preloadCount->Int.toFloat,
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
    ~value=cs => cs->ChainState.blockRangeFetchSeconds,
  )
  b->series(
    ~name="envio_fetching_block_range_parse_seconds",
    ~help="Cumulative time spent parsing block range fetch responses.",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => cs->ChainState.blockRangeParseSeconds,
  )
  b->series(
    ~name="envio_fetching_block_range_total",
    ~help="Total number of block range fetch operations.",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => cs->ChainState.blockRangeFetchCount->Int.toFloat,
  )
  b->series(
    ~name="envio_fetching_block_range_events_total",
    ~help="Cumulative number of events fetched across all block range operations.",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => cs->ChainState.blockRangeFetchedEvents->Int.toFloat,
  )
  b->series(
    ~name="envio_fetching_block_range_size",
    ~help="Cumulative number of blocks covered across all block range fetch operations.",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => cs->ChainState.blockRangeFetchedBlocks->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_known_height",
    ~help="The latest known block number reported by the active indexing source. This value may lag behind the actual chain height, as it is updated only when needed.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.knownHeight->Int.toFloat,
  )
  b->single(
    ~name="envio_process_start_time_seconds",
    ~help="Start time of the process since unix epoch in seconds.",
    ~kind="gauge",
    ~value=state->IndexerState.indexerStartTime->Date.getTime /. 1000.,
  )
  b->series(
    ~name="envio_indexing_concurrency",
    ~help="The number of executing concurrent queries to the chain data-source.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.sourceManager->SourceManager.inFlightCount->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_partitions",
    ~help="The number of partitions used to split fetching logic by addresses and block ranges.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.partitionsCount->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_idle_seconds",
    ~help="The time the indexer source syncing has been idle. A high value may indicate the source sync is a bottleneck.",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => cs->ChainState.sourceManager->SourceManager.idleSeconds,
  )
  b->series(
    ~name="envio_indexing_source_waiting_seconds",
    ~help="The time the indexer has been waiting for new blocks.",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => cs->ChainState.sourceManager->SourceManager.waitingForNewBlockSeconds,
  )
  b->series(
    ~name="envio_indexing_source_querying_seconds",
    ~help="The time spent performing queries to the chain data-source.",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => cs->ChainState.sourceManager->SourceManager.queryingSeconds,
  )
  b->series(
    ~name="envio_indexing_buffer_size",
    ~help="The current number of items in the indexing buffer.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.bufferSize->Int.toFloat,
  )
  b->single(
    ~name="envio_indexing_target_buffer_size",
    ~help="The indexer-wide target buffer size shared across all chains. The actual number of items in the queue may exceed this value, but the indexer always tries to keep the buffer filled up to this target.",
    ~kind="gauge",
    ~value=crossChainState->CrossChainState.targetBufferSize->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_buffer_block",
    ~help="The highest block number that has been fully fetched by the indexer.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.bufferBlockNumber->Int.toFloat,
  )
  b->seriesOpt(
    ~name="envio_indexing_end_block",
    ~help="The block number to stop indexing at. (inclusive)",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.endBlock->Option.map(Int.toFloat),
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
    ~value=s => s.height->Int.toFloat,
  )
  b->seriesOpt(
    ~name="envio_reorg_detected_total",
    ~help="Total number of reorgs detected",
    ~kind="counter",
    ~entries=chains,
    ~value=cs => {
      let count = cs->ChainState.reorgCount
      count > 0 ? Some(count->Int.toFloat) : None
    },
  )
  b->seriesOpt(
    ~name="envio_reorg_detected_block",
    ~help="The block number where reorg was detected the last time. This doesn't mean that the block was reorged, this is simply where we found block hash to be different.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.reorgDetectedBlock->Option.map(Int.toFloat),
  )
  b->single(
    ~name="envio_reorg_threshold",
    ~help="Whether indexing is currently within the reorg threshold",
    ~kind="gauge",
    ~value=crossChainState->CrossChainState.isInReorgThreshold ? 1. : 0.,
  )
  b->single(
    ~name="envio_rollback_enabled",
    ~help="Whether rollback on reorg is enabled",
    ~kind="gauge",
    ~value=config.shouldRollbackOnReorg ? 1. : 0.,
  )
  b->single(
    ~name="envio_rollback_seconds",
    ~help="Rollback on reorg total time.",
    ~kind="counter",
    ~value=state->IndexerState.rollbackSeconds,
  )
  b->single(
    ~name="envio_rollback_total",
    ~help="Number of successful rollbacks on reorg",
    ~kind="counter",
    ~value=state->IndexerState.rollbackCount->Int.toFloat,
  )
  b->single(
    ~name="envio_rollback_events",
    ~help="Number of events rollbacked on reorg",
    ~kind="counter",
    ~value=state->IndexerState.rollbackEventsCount,
  )
  b->series(
    ~name="envio_rollback_history_prune_seconds",
    ~help="The total time spent pruning entity history which is not in the reorg threshold.",
    ~kind="counter",
    ~entries=historyPrunes,
    ~value=(s: IndexerState.historyPruneStat) => s.seconds,
  )
  b->series(
    ~name="envio_rollback_history_prune_total",
    ~help="Number of successful entity history prunes",
    ~kind="counter",
    ~entries=historyPrunes,
    ~value=(s: IndexerState.historyPruneStat) => s.count->Int.toFloat,
  )
  b->seriesOpt(
    ~name="envio_rollback_target_block",
    ~help="The block number reorg was rollbacked to the last time.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.rollbackTargetBlock->Option.map(Int.toFloat),
  )
  b->single(
    ~name="envio_processing_max_batch_size",
    ~help="The maximum number of items to process in a single batch.",
    ~kind="gauge",
    ~value=config.batchSize->Int.toFloat,
  )
  b->series(
    ~name="envio_progress_block",
    ~help="The block number of the latest block processed and stored in the database.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.committedProgressBlockNumber->Int.toFloat,
  )
  b->series(
    ~name="envio_progress_events",
    ~help="The number of events processed and reflected in the database.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.numEventsProcessed,
  )
  b->seriesOpt(
    ~name="envio_progress_latency",
    ~help="The latency in milliseconds between the latest processed event creation and the time it was written to storage.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.progressLatencyMs->Option.map(Int.toFloat),
  )
  // Effects that were never called (e.g. seeded from the persisted cache only)
  // get no call samples.
  let ifCalled = (s: EffectState.effectStats, value) =>
    s.callCount > 0 || s.activeCallsCount > 0 ? Some(value) : None
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
    ~value=s => s->ifCalled(s.callCount->Int.toFloat),
  )
  b->seriesOpt(
    ~name="envio_effect_active_calls",
    ~help="The number of Effect function calls that are currently running.",
    ~kind="gauge",
    ~entries=effects,
    ~value=s => s->ifCalled(s.activeCallsCount->Int.toFloat),
  )
  // Only effects that persist their cache get a sample; a plain effect keeps
  // the count at zero forever.
  b->seriesOpt(
    ~name="envio_effect_cache",
    ~help="The number of items in the effect cache.",
    ~kind="gauge",
    ~entries=effects,
    ~value=s => s.cacheCount > 0 ? Some(s.cacheCount->Int.toFloat) : None,
  )
  b->seriesOpt(
    ~name="envio_effect_cache_invalidations",
    ~help="The number of effect cache invalidations.",
    ~kind="counter",
    ~entries=effects,
    ~value=s => s.invalidationsCount > 0 ? Some(s.invalidationsCount->Int.toFloat) : None,
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
    ~entries=effects,
    ~value=s => s.queueWaitSeconds !== 0. ? Some(s.queueWaitSeconds) : None,
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
    ~value=s => s.count->Int.toFloat,
  )
  b->series(
    ~name="envio_storage_load_where_size",
    ~help="Cumulative number of filter conditions ('where' items) used in storage load operations during the indexing process.",
    ~kind="counter",
    ~entries=storageLoads,
    ~value=s => s.whereSize->Int.toFloat,
  )
  b->series(
    ~name="envio_storage_load_size",
    ~help="Cumulative number of records loaded from storage during the indexing process.",
    ~kind="counter",
    ~entries=storageLoads,
    ~value=s => s.size->Int.toFloat,
  )
  b->series(
    ~name="envio_storage_write_seconds",
    ~help="Cumulative time spent writing batch data to storage.",
    ~kind="counter",
    ~entries=storageWrites,
    ~value=(s: IndexerState.storageWriteStat) => s.seconds,
  )
  b->series(
    ~name="envio_storage_write_total",
    ~help="Cumulative number of successful storage write operations during the indexing process.",
    ~kind="counter",
    ~entries=storageWrites,
    ~value=(s: IndexerState.storageWriteStat) => s.count->Int.toFloat,
  )
  b->series(
    ~name="envio_indexing_addresses",
    ~help="The number of addresses indexed on chain. Includes both static and dynamic addresses.",
    ~kind="gauge",
    ~entries=chains,
    ~value=cs => cs->ChainState.numAddresses->Int.toFloat,
  )
}

let collect = (~state: option<IndexerState.t>) => {
  let b = {out: ""}
  b->series(
    ~name="envio_info",
    ~help="Information about the indexer",
    ~kind="gauge",
    ~entries=[(`{version="${Utils.EnvioPackage.value.version}"}`, ())],
    ~value=() => 1.,
  )
  switch state {
  | Some(state) => b->renderIndexerState(state)
  | None => ()
  }
  b.out ++ "\n"
}
