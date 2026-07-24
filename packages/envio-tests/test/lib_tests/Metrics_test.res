open Vitest

describe("Metrics rendering helpers", () => {
  it("Renders metrics separated by a blank line, keeping 3 decimals after the point", t => {
    let b: Metrics.builder = {out: ""}
    b->Metrics.single(
      ~name="envio_preload_seconds",
      ~help="Cumulative preload time.",
      ~kind="counter",
      ~value=816.8360346669994,
    )
    b->Metrics.series(
      ~name="envio_indexing_addresses",
      ~help="The number of addresses indexed on chain.",
      ~kind="gauge",
      ~entries=[(`{chainId="1"}`, 3.), (`{chainId="137"}`, 0.)],
      ~value=v => v,
    )

    t.expect(b.out).toBe(`# HELP envio_preload_seconds Cumulative preload time.
# TYPE envio_preload_seconds counter
envio_preload_seconds 816.836

# HELP envio_indexing_addresses The number of addresses indexed on chain.
# TYPE envio_indexing_addresses gauge
envio_indexing_addresses{chainId="1"} 3
envio_indexing_addresses{chainId="137"} 0`)
  })

  it("Escapes quotes/backslashes/newlines and passes commas and equals through", t => {
    t.expect(`weird "name",a=b \\ with
newline`->Metrics.escapeLabelValue).toBe(`weird \\"name\\",a=b \\\\ with\\nnewline`)
  })

  it("Renders only the header for a series without entries and skips seriesOpt None samples", t => {
    let b: Metrics.builder = {out: ""}
    b->Metrics.series(
      ~name="envio_indexing_end_block",
      ~help="The block number to stop indexing at.",
      ~kind="gauge",
      ~entries=[],
      ~value=v => v,
    )
    b->Metrics.seriesOpt(
      ~name="envio_source_request_seconds_total",
      ~help="Cumulative time spent on data source requests.",
      ~kind="counter",
      ~entries=[(`{method="getLogs"}`, 1.5), (`{method="heightSubscription"}`, 0.)],
      ~value=v => v !== 0. ? Some(v) : None,
    )

    t.expect(b.out).toBe(`# HELP envio_indexing_end_block The block number to stop indexing at.
# TYPE envio_indexing_end_block gauge

# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter
envio_source_request_seconds_total{method="getLogs"} 1.5`)
  })
})

describe("Metrics.collect", () => {
  it("Renders only the indexer info when there is no state", t => {
    t.expect(Metrics.collect(~metrics=None)).toBe(`# HELP envio_info Information about the indexer
# TYPE envio_info gauge
envio_info{version="${Utils.EnvioPackage.value.version}"} 1
`)
  })

  it("Escapes both the effect and the scope label values", t => {
    let metrics: Metrics.t = {
      startTime: Date.fromTime(0.),
      scrapeTime: Date.fromTime(0.),
      targetBufferSize: 0,
      isInReorgThreshold: false,
      rollbackEnabled: false,
      maxBatchSize: 0,
      preloadSeconds: 0.,
      processingSeconds: 0.,
      processingStalledOnFetchSeconds: 0.,
      processingStalledOnStorageWriteSeconds: 0.,
      rollbackSeconds: 0.,
      rollbackCount: 0,
      rollbackEventsCount: 0.,
      chains: [],
      handlers: [],
      effects: [
        {
          effect: `a",b=c`,
          scope: `d"e`,
          callSeconds: 0.,
          callSecondsTotal: 0.,
          callCount: 2.,
          activeCallsCount: 0,
          queueCount: 0,
          queueWaitSeconds: 0.,
          invalidationsCount: 0.,
          cacheCount: None,
        },
      ],
      storageLoads: [],
      storageWrites: [],
      historyPrunes: [],
      sourceRequests: [],
      sourceHeights: [],
    }

    t.expect(
      Metrics.collect(~metrics=Some(metrics))->String.includes(
        `envio_effect_call_total{effect="a\\",b=c",scope="d\\"e"} 2`,
      ),
    ).toBe(true)
  })

  it("Renders every metric family from a fully populated snapshot", t => {
    let metrics: Metrics.t = {
      startTime: Date.fromTime(1700000000000.),
      scrapeTime: Date.fromTime(1700000123456.),
      targetBufferSize: 5000,
      isInReorgThreshold: true,
      rollbackEnabled: true,
      maxBatchSize: 5000,
      preloadSeconds: 12.3456,
      processingSeconds: 7.891,
      processingStalledOnFetchSeconds: 6.02,
      processingStalledOnStorageWriteSeconds: 1.33,
      rollbackSeconds: 0.25,
      rollbackCount: 2,
      rollbackEventsCount: 42.,
      chains: [
        {
          chainId: 1.,
          poweredByHyperSync: true,
          firstEventBlockNumber: Some(100),
          latestProcessedBlock: Some(200),
          timestampCaughtUpToHeadOrEndblock: Some(Date.fromTime(0.)),
          numEventsProcessed: 12345.,
          latestFetchedBlockNumber: 250,
          knownHeight: 300,
          numBatchesFetched: 5,
          startBlock: 0,
          endBlock: Some(1000),
          numAddresses: 7,
          isReady: true,
          sourceBlockNumber: 305,
          progressBlockNumber: 200,
          progressLatencyMs: Some(1500),
          concurrency: 2,
          partitionsCount: 3,
          bufferSize: 42,
          bufferBlockNumber: 260,
          idleSeconds: 1.5,
          waitingForNewBlockSeconds: 2.5,
          queryingSeconds: 3.5,
          blockRangeFetchSeconds: 10.123456,
          blockRangeParseSeconds: 4.2,
          blockRangeFetchCount: 5.,
          blockRangeFetchedEvents: 500.,
          blockRangeFetchedBlocks: 250.,
          reorgCount: 2,
          reorgDetectedBlock: Some(199),
          rollbackTargetBlock: Some(180),
        },
      ],
      handlers: [
        {
          contract: "ERC20",
          event: "Transfer",
          processingSeconds: 3.14159,
          processingCount: 1000.,
          preloadSeconds: 2.5,
          preloadCount: 1000.,
          preloadSecondsTotal: 6.5,
        },
      ],
      effects: [
        {
          effect: "getMetadata",
          scope: Internal.EffectCache.scopeToString(CrossChain),
          callSeconds: 8.4,
          callSecondsTotal: 20.9,
          callCount: 300.,
          activeCallsCount: 1,
          queueCount: 4,
          queueWaitSeconds: 1.75,
          invalidationsCount: 3.,
          cacheCount: Some(128),
        },
      ],
      storageLoads: [
        {
          operation: "getTransfers",
          storage: "postgres",
          seconds: 5.5,
          secondsTotal: 9.9,
          count: 250.,
          whereSize: 400.,
          size: 1200.,
        },
      ],
      storageWrites: [
        {
          storage: "postgres",
          seconds: 15.25,
          count: 80,
        },
      ],
      historyPrunes: [
        {
          entity: "Account",
          seconds: 0.5,
          count: 3,
        },
      ],
      sourceRequests: [
        {
          source: "HyperSync",
          chainId: 1,
          method: "getLogs",
          count: 42,
          seconds: 33.75,
        },
      ],
      sourceHeights: [
        {
          source: "HyperSync",
          chainId: 1,
          height: 305,
        },
      ],
    }

    t.expect(Metrics.collect(~metrics=Some(metrics))).toBe(`# HELP envio_info Information about the indexer
# TYPE envio_info gauge
envio_info{version="${Utils.EnvioPackage.value.version}"} 1

# HELP envio_preload_seconds Cumulative time spent on preloading entities during batch processing.
# TYPE envio_preload_seconds counter
envio_preload_seconds 12.346

# HELP envio_processing_seconds Cumulative time spent executing event handlers during batch processing.
# TYPE envio_processing_seconds counter
envio_processing_seconds 7.891

# HELP envio_processing_stalled_on_fetch_seconds Cumulative time batch processing was stalled with an empty buffer, waiting for fetched events. A high rate points to fetching as the bottleneck, unless the chain is caught up to the head (compare with envio_indexing_source_waiting_seconds).
# TYPE envio_processing_stalled_on_fetch_seconds counter
envio_processing_stalled_on_fetch_seconds 6.02

# HELP envio_processing_stalled_on_storage_write_seconds Cumulative time batch processing was stalled waiting for storage write capacity to free up (backpressure). A high rate points to storage writes as the bottleneck.
# TYPE envio_processing_stalled_on_storage_write_seconds counter
envio_processing_stalled_on_storage_write_seconds 1.33

# HELP envio_progress_ready Whether the chain is fully synced to the head.
# TYPE envio_progress_ready gauge
envio_progress_ready{chainId="1"} 1

# HELP hyperindex_synced_to_head All chains fully synced
# TYPE hyperindex_synced_to_head gauge
hyperindex_synced_to_head 1

# HELP envio_processing_handler_seconds Cumulative time spent inside individual event handler executions.
# TYPE envio_processing_handler_seconds counter
envio_processing_handler_seconds{contract="ERC20",event="Transfer"} 3.142

# HELP envio_processing_handler_total Total number of individual event handler executions.
# TYPE envio_processing_handler_total counter
envio_processing_handler_total{contract="ERC20",event="Transfer"} 1000

# HELP envio_preload_handler_seconds Wall-clock time spent inside individual preload handler executions.
# TYPE envio_preload_handler_seconds counter
envio_preload_handler_seconds{contract="ERC20",event="Transfer"} 2.5

# HELP envio_preload_handler_total Total number of individual preload handler executions.
# TYPE envio_preload_handler_total counter
envio_preload_handler_total{contract="ERC20",event="Transfer"} 1000

# HELP envio_preload_handler_seconds_total Cumulative time spent inside individual preload handler executions. Can exceed wall-clock time due to parallel execution.
# TYPE envio_preload_handler_seconds_total counter
envio_preload_handler_seconds_total{contract="ERC20",event="Transfer"} 6.5

# HELP envio_fetching_block_range_seconds Cumulative time spent fetching block ranges.
# TYPE envio_fetching_block_range_seconds counter
envio_fetching_block_range_seconds{chainId="1"} 10.123

# HELP envio_fetching_block_range_parse_seconds Cumulative time spent parsing block range fetch responses.
# TYPE envio_fetching_block_range_parse_seconds counter
envio_fetching_block_range_parse_seconds{chainId="1"} 4.2

# HELP envio_fetching_block_range_total Total number of block range fetch operations.
# TYPE envio_fetching_block_range_total counter
envio_fetching_block_range_total{chainId="1"} 5

# HELP envio_fetching_block_range_events_total Cumulative number of events fetched across all block range operations.
# TYPE envio_fetching_block_range_events_total counter
envio_fetching_block_range_events_total{chainId="1"} 500

# HELP envio_fetching_block_range_size Cumulative number of blocks covered across all block range fetch operations.
# TYPE envio_fetching_block_range_size counter
envio_fetching_block_range_size{chainId="1"} 250

# HELP envio_indexing_known_height The latest known block number reported by the active indexing source. This value may lag behind the actual chain height, as it is updated only when needed.
# TYPE envio_indexing_known_height gauge
envio_indexing_known_height{chainId="1"} 305

# HELP envio_process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE envio_process_start_time_seconds gauge
envio_process_start_time_seconds 1700000000

# HELP envio_process_elapsed_seconds Seconds elapsed since the indexer started. Divide a cumulative counter (e.g. envio_processing_seconds) by this to get its share of the whole run without a query-time clock.
# TYPE envio_process_elapsed_seconds gauge
envio_process_elapsed_seconds 123.456

# HELP envio_scrape_time_seconds Unix timestamp when this metrics snapshot was generated, so a single scrape can be dated without an external clock.
# TYPE envio_scrape_time_seconds gauge
envio_scrape_time_seconds 1700000123.456

# HELP envio_indexing_concurrency The number of executing concurrent queries to the chain data-source.
# TYPE envio_indexing_concurrency gauge
envio_indexing_concurrency{chainId="1"} 2

# HELP envio_indexing_partitions The number of partitions used to split fetching logic by addresses and block ranges.
# TYPE envio_indexing_partitions gauge
envio_indexing_partitions{chainId="1"} 3

# HELP envio_indexing_idle_seconds The time the indexer source syncing has been idle. A high value may indicate the source sync is a bottleneck.
# TYPE envio_indexing_idle_seconds counter
envio_indexing_idle_seconds{chainId="1"} 1.5

# HELP envio_indexing_source_waiting_seconds The time the indexer has been waiting for new blocks.
# TYPE envio_indexing_source_waiting_seconds counter
envio_indexing_source_waiting_seconds{chainId="1"} 2.5

# HELP envio_indexing_source_querying_seconds The time spent performing queries to the chain data-source.
# TYPE envio_indexing_source_querying_seconds counter
envio_indexing_source_querying_seconds{chainId="1"} 3.5

# HELP envio_indexing_buffer_size The current number of items in the indexing buffer.
# TYPE envio_indexing_buffer_size gauge
envio_indexing_buffer_size{chainId="1"} 42

# HELP envio_indexing_target_buffer_size The indexer-wide target buffer size shared across all chains. The actual number of items in the queue may exceed this value, but the indexer always tries to keep the buffer filled up to this target.
# TYPE envio_indexing_target_buffer_size gauge
envio_indexing_target_buffer_size 5000

# HELP envio_indexing_buffer_block The highest block number that has been fully fetched by the indexer.
# TYPE envio_indexing_buffer_block gauge
envio_indexing_buffer_block{chainId="1"} 260

# HELP envio_indexing_end_block The block number to stop indexing at. (inclusive)
# TYPE envio_indexing_end_block gauge
envio_indexing_end_block{chainId="1"} 1000

# HELP envio_source_request_total The number of requests made to data sources.
# TYPE envio_source_request_total counter
envio_source_request_total{source="HyperSync",chainId="1",method="getLogs"} 42

# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter
envio_source_request_seconds_total{source="HyperSync",chainId="1",method="getLogs"} 33.75

# HELP envio_source_known_height The latest known block number reported by the source. This value may lag behind the actual chain height, as it is updated only when queried.
# TYPE envio_source_known_height gauge
envio_source_known_height{source="HyperSync",chainId="1"} 305

# HELP envio_reorg_detected_total Total number of reorgs detected
# TYPE envio_reorg_detected_total counter
envio_reorg_detected_total{chainId="1"} 2

# HELP envio_reorg_detected_block The block number where reorg was detected the last time. This doesn't mean that the block was reorged, this is simply where we found block hash to be different.
# TYPE envio_reorg_detected_block gauge
envio_reorg_detected_block{chainId="1"} 199

# HELP envio_reorg_threshold Whether indexing is currently within the reorg threshold
# TYPE envio_reorg_threshold gauge
envio_reorg_threshold 1

# HELP envio_rollback_enabled Whether rollback on reorg is enabled
# TYPE envio_rollback_enabled gauge
envio_rollback_enabled 1

# HELP envio_rollback_seconds Rollback on reorg total time.
# TYPE envio_rollback_seconds counter
envio_rollback_seconds 0.25

# HELP envio_rollback_total Number of successful rollbacks on reorg
# TYPE envio_rollback_total counter
envio_rollback_total 2

# HELP envio_rollback_events Number of events rollbacked on reorg
# TYPE envio_rollback_events counter
envio_rollback_events 42

# HELP envio_rollback_history_prune_seconds The total time spent pruning entity history which is not in the reorg threshold.
# TYPE envio_rollback_history_prune_seconds counter
envio_rollback_history_prune_seconds{entity="Account"} 0.5

# HELP envio_rollback_history_prune_total Number of successful entity history prunes
# TYPE envio_rollback_history_prune_total counter
envio_rollback_history_prune_total{entity="Account"} 3

# HELP envio_rollback_target_block The block number reorg was rollbacked to the last time.
# TYPE envio_rollback_target_block gauge
envio_rollback_target_block{chainId="1"} 180

# HELP envio_processing_max_batch_size The maximum number of items to process in a single batch.
# TYPE envio_processing_max_batch_size gauge
envio_processing_max_batch_size 5000

# HELP envio_progress_block The block number of the latest block processed and stored in the database.
# TYPE envio_progress_block gauge
envio_progress_block{chainId="1"} 200

# HELP envio_progress_events The number of events processed and reflected in the database.
# TYPE envio_progress_events gauge
envio_progress_events{chainId="1"} 12345

# HELP envio_progress_latency The latency in milliseconds between the latest processed event creation and the time it was written to storage.
# TYPE envio_progress_latency gauge
envio_progress_latency{chainId="1"} 1500

# HELP envio_effect_call_seconds Processing time taken to call the Effect function.
# TYPE envio_effect_call_seconds counter
envio_effect_call_seconds{effect="getMetadata",scope="crossChain"} 8.4

# HELP envio_effect_call_seconds_total Cumulative time spent calling the Effect function during the indexing process.
# TYPE envio_effect_call_seconds_total counter
envio_effect_call_seconds_total{effect="getMetadata",scope="crossChain"} 20.9

# HELP envio_effect_call_total Cumulative number of resolved Effect function calls during the indexing process.
# TYPE envio_effect_call_total counter
envio_effect_call_total{effect="getMetadata",scope="crossChain"} 300

# HELP envio_effect_active_calls The number of Effect function calls that are currently running.
# TYPE envio_effect_active_calls gauge
envio_effect_active_calls{effect="getMetadata",scope="crossChain"} 1

# HELP envio_effect_cache The number of items in the effect cache.
# TYPE envio_effect_cache gauge
envio_effect_cache{effect="getMetadata",scope="crossChain"} 128

# HELP envio_effect_cache_invalidations The number of effect cache invalidations.
# TYPE envio_effect_cache_invalidations counter
envio_effect_cache_invalidations{effect="getMetadata"} 3

# HELP envio_effect_queue The number of effect calls waiting in the rate limit queue.
# TYPE envio_effect_queue gauge
envio_effect_queue{effect="getMetadata",scope="crossChain"} 4

# HELP envio_effect_queue_wait_seconds The time spent waiting in the rate limit queue.
# TYPE envio_effect_queue_wait_seconds counter
envio_effect_queue_wait_seconds{effect="getMetadata"} 1.75

# HELP envio_storage_load_seconds Processing time taken to load data from storage.
# TYPE envio_storage_load_seconds counter
envio_storage_load_seconds{operation="getTransfers",storage="postgres"} 5.5

# HELP envio_storage_load_seconds_total Cumulative time spent loading data from storage during the indexing process.
# TYPE envio_storage_load_seconds_total counter
envio_storage_load_seconds_total{operation="getTransfers",storage="postgres"} 9.9

# HELP envio_storage_load_total Cumulative number of successful storage load operations during the indexing process.
# TYPE envio_storage_load_total counter
envio_storage_load_total{operation="getTransfers",storage="postgres"} 250

# HELP envio_storage_load_where_size Cumulative number of filter conditions ('where' items) used in storage load operations during the indexing process.
# TYPE envio_storage_load_where_size counter
envio_storage_load_where_size{operation="getTransfers",storage="postgres"} 400

# HELP envio_storage_load_size Cumulative number of records loaded from storage during the indexing process.
# TYPE envio_storage_load_size counter
envio_storage_load_size{operation="getTransfers",storage="postgres"} 1200

# HELP envio_storage_write_seconds Cumulative time spent writing batch data to storage.
# TYPE envio_storage_write_seconds counter
envio_storage_write_seconds{storage="postgres"} 15.25

# HELP envio_storage_write_total Cumulative number of successful storage write operations during the indexing process.
# TYPE envio_storage_write_total counter
envio_storage_write_total{storage="postgres"} 80

# HELP envio_indexing_addresses The number of addresses indexed on chain. Includes both static and dynamic addresses.
# TYPE envio_indexing_addresses gauge
envio_indexing_addresses{chainId="1"} 7
`)
  })
})
