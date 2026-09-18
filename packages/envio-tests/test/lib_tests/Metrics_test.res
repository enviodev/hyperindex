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
    t.expect(
      `weird "name",a=b \\ with
newline`->Metrics.escapeLabelValue,
    ).toBe(`weird \\"name\\",a=b \\\\ with\\nnewline`)
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
      ~entries=[(`{method="getLogs"}`, 1.5), (`{method="heightPush"}`, 0.)],
      ~value=v => v !== 0. ? Some(v) : None,
    )

    t.expect(b.out).toBe(`# HELP envio_indexing_end_block The block number to stop indexing at.
# TYPE envio_indexing_end_block gauge

# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter
envio_source_request_seconds_total{method="getLogs"} 1.5`)
  })
})

// The state a Metrics.t carries when a test says nothing about it. Each test
// below spreads this and names only the fields it asserts on.
let baseMetrics = TestChainMetrics.emptySnapshot

describe("Metrics.collect", () => {
  it("Renders only the indexer info when there is no state", t => {
    t.expect(Metrics.collect(~metrics=None)).toBe(
      `# HELP envio_info Information about the indexer
# TYPE envio_info gauge
envio_info{version="${Utils.EnvioPackage.value.version}"} 1
`,
    )
  })

  it("Escapes both the effect and the scope label values", t => {
    let metrics: Metrics.t = {
      ...baseMetrics,
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
    }

    t.expect(
      Metrics.collect(
        ~metrics=Some(metrics),
      )->String.includes(`envio_effect_call_total{effect="a\\",b=c",scope="d\\"e"} 2`),
    ).toBe(true)
  })

  it("Omits the height stream families entirely when no source subscribes", t => {
    // No source samples at all, which is what a chain that only ever polls
    // reports — the base is already exactly that.
    t.expect(
      Metrics.collect(~metrics=Some(baseMetrics))->String.includes("envio_source_height_stream"),
    ).toBe(false)
  })

  it("Renders a stream that has never connected as zero connects", t => {
    let metrics: Metrics.t = {
      ...baseMetrics,
      sourceHeightStreams: [
        {
          source: "RPC (rpc.example.com)",
          chainId: 1->ChainId.fromInt,
          connectCount: 0,
          disconnectsByReason: [],
        },
      ],
    }

    // Nothing has disconnected, because nothing ever connected. Without the zero
    // there is no series at all, and a ws url the node will never accept would
    // go unreported — a sample only exists once a stream has been asked for, so
    // zero connects here says the stream is down rather than absent.
    t.expect(
      Metrics.collect(~metrics=Some(metrics))
      ->String.split("\n")
      ->Array.filter(line => line->String.startsWith("envio_source_height_stream")),
    ).toStrictEqual([
      `envio_source_height_stream_connects_total{source="RPC (rpc.example.com)",chainId="1"} 0`,
    ])
  })

  it("Aggregates height stream samples that share a source name and chain", t => {
    let metrics: Metrics.t = {
      ...baseMetrics,
      // Two RPC urls on the same host share a source name, and duplicate
      // samples would make Prometheus reject the whole scrape.
      sourceHeightStreams: [
        {
          source: "RPC (rpc.example.com)",
          chainId: 1->ChainId.fromInt,
          connectCount: 2,
          disconnectsByReason: [("rotated", 3)],
        },
        {
          source: "RPC (rpc.example.com)",
          chainId: 1->ChainId.fromInt,
          connectCount: 1,
          disconnectsByReason: [("rotated", 4), ("stale", 5)],
        },
      ],
    }

    t.expect(
      Metrics.collect(~metrics=Some(metrics))
      ->String.split("\n")
      ->Array.filter(line => line->String.startsWith("envio_source_height_stream")),
    ).toStrictEqual([
      `envio_source_height_stream_connects_total{source="RPC (rpc.example.com)",chainId="1"} 3`,
      `envio_source_height_stream_disconnects_total{source="RPC (rpc.example.com)",chainId="1",reason="rotated"} 7`,
      `envio_source_height_stream_disconnects_total{source="RPC (rpc.example.com)",chainId="1",reason="stale"} 5`,
    ])
  })

  it("Aggregates source request samples that share a source name and chain", t => {
    let sourceRequest = (
      ~chainId=1,
      ~method="getLogs",
      ~responseBlocks,
      ~emptyResponseCount,
    ): Metrics.sourceRequestMetrics => {
      source: "HyperSync",
      chainId: chainId->ChainId.fromInt,
      method,
      count: 1,
      seconds: 0.,
      responseBlocks,
      emptyResponseCount,
    }
    let metrics: Metrics.t = {
      ...baseMetrics,
      // Two urls on the same host share a source name, and duplicate samples
      // would make Prometheus reject the whole scrape.
      sourceRequests: [
        sourceRequest(~responseBlocks=Some(30), ~emptyResponseCount=1),
        sourceRequest(~responseBlocks=Some(12), ~emptyResponseCount=2),
        // A chain whose every response carried blocks still renders the empty
        // counter, flat at zero — a series that only appears once the first
        // empty response lands is one nothing can alert on.
        sourceRequest(~chainId=2, ~responseBlocks=Some(7), ~emptyResponseCount=0),
        // A stream push is a response nothing measures in blocks, so it stays
        // out of both series rather than reading as an empty response.
        sourceRequest(~method="heightPush", ~responseBlocks=None, ~emptyResponseCount=0),
      ],
    }

    t.expect(
      Metrics.collect(~metrics=Some(metrics))
      ->String.split("\n")
      ->Array.filter(line => line->String.startsWith("envio_source_response")),
    ).toStrictEqual([
      `envio_source_response_blocks_total{source="HyperSync",chainId="1",method="getLogs"} 42`,
      `envio_source_response_blocks_total{source="HyperSync",chainId="2",method="getLogs"} 7`,
      `envio_source_response_empty_total{source="HyperSync",chainId="1",method="getLogs"} 3`,
      `envio_source_response_empty_total{source="HyperSync",chainId="2",method="getLogs"} 0`,
    ])
  })

  it("Renders every metric family from a fully populated snapshot", t => {
    let metrics: Metrics.t = {
      startTime: Date.fromTime(1700000000000.),
      metricTime: Date.fromTime(1700000123456.),
      elapsedSeconds: 123.456,
      targetBufferSize: 5000,
      isInReorgThreshold: true,
      hasArrivedAtHead: true,
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
          chainId: 1->ChainId.fromInt,
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
          addressesByContract: [("Gravatar", 5), ("NftFactory", 2)],
          isReady: true,
          sourceBlockNumber: 305,
          progressBlockNumber: 200,
          progressLatencyMs: Some(1500),
          progressBlockTime: Some(1700000000),
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
          rateLimitTimeMs: 0.,
          rateLimitResetInMs: None,
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
          scope: Internal.chainScopeToString(CrossChain),
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
          chainId: 1->ChainId.fromInt,
          method: "getLogs",
          count: 42,
          seconds: 33.75,
          responseBlocks: Some(1234),
          emptyResponseCount: 9,
        },
        {
          source: "HyperSync",
          chainId: 1->ChainId.fromInt,
          method: "heightPush",
          count: 7,
          seconds: 0.,
          responseBlocks: None,
          emptyResponseCount: 0,
        },
        {
          source: "HyperSync",
          chainId: 1->ChainId.fromInt,
          method: "heightPushIgnored",
          count: 0,
          seconds: 0.,
          responseBlocks: None,
          emptyResponseCount: 0,
        },
      ],
      sourceHeights: [
        {
          source: "HyperSync",
          chainId: 1->ChainId.fromInt,
          height: 305,
        },
      ],
      sourceHeightStreams: [
        {
          source: "HyperSync",
          chainId: 1->ChainId.fromInt,
          connectCount: 3,
          disconnectsByReason: [("rotated", 4), ("401", 1)],
        },
      ],
    }

    t.expect(Metrics.collect(~metrics=Some(metrics))).toBe(
      `# HELP envio_info Information about the indexer
# TYPE envio_info gauge
envio_info{version="${Utils.EnvioPackage.value.version}"} 1

# HELP envio_process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE envio_process_start_time_seconds gauge
envio_process_start_time_seconds 1700000000

# HELP envio_process_metric_time_seconds The time these metrics were collected. Use it to tell how fresh a snapshot is, or to measure rates between two snapshots.
# TYPE envio_process_metric_time_seconds gauge
envio_process_metric_time_seconds 1700000123.456

# HELP envio_process_elapsed_seconds How long the indexer has been running. Divide a cumulative seconds metric by this to get the share of the run it took, eg envio_processing_seconds for time spent in event handlers.
# TYPE envio_process_elapsed_seconds gauge
envio_process_elapsed_seconds 123.456

# HELP envio_preload_seconds Cumulative time spent on preloading entities during batch processing.
# TYPE envio_preload_seconds counter
envio_preload_seconds 12.346

# HELP envio_processing_seconds Cumulative time spent executing event handlers during batch processing.
# TYPE envio_processing_seconds counter
envio_processing_seconds 7.891

# HELP envio_processing_stalled_on_fetch_seconds Time the indexer had nothing to process while waiting for events to be fetched. A high rate means fetching is the bottleneck: check the data-source latency and whether it can be queried with more concurrency. Waiting at the chain head for new blocks is not counted.
# TYPE envio_processing_stalled_on_fetch_seconds counter
envio_processing_stalled_on_fetch_seconds 6.02

# HELP envio_processing_stalled_on_storage_write_seconds Time the indexer paused processing because too many changes were still waiting to be written. A high rate means storage writes are the bottleneck: check envio_storage_write_seconds and the database performance.
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

# HELP envio_source_request_total The number of requests made to data sources. Heights pushed by a subscription stream are counted here too, under the heightPush and heightPushIgnored methods.
# TYPE envio_source_request_total counter
envio_source_request_total{source="HyperSync",chainId="1",method="getLogs"} 42
envio_source_request_total{source="HyperSync",chainId="1",method="heightPush"} 7

# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter
envio_source_request_seconds_total{source="HyperSync",chainId="1",method="getLogs"} 33.75

# HELP envio_source_response_blocks_total The number of blocks a data source returned, summed over its responses. Counted as the source sent them, before the indexer drops the blocks no event needs. Only sources whose responses are measured in blocks report it.
# TYPE envio_source_response_blocks_total counter
envio_source_response_blocks_total{source="HyperSync",chainId="1",method="getLogs"} 1234

# HELP envio_source_response_empty_total The number of responses that came back with no blocks at all — a range the source scanned and matched nothing in. Compare against envio_source_request_total for the share of requests that returned nothing.
# TYPE envio_source_response_empty_total counter
envio_source_response_empty_total{source="HyperSync",chainId="1",method="getLogs"} 9

# HELP envio_source_height_stream_connects_total The number of times a source's height subscription connected. Compare against the disconnects total, which is absent until the first disconnect and counts as zero while it is: one more connect than disconnects means the stream is up, and equal counts mean it is down and the indexer is polling instead. Zero connects means the stream has not come up, which is the normal reading for a chain that is still backfilling: subscriptions are only opened once a chain reaches the head.
# TYPE envio_source_height_stream_connects_total counter
envio_source_height_stream_connects_total{source="HyperSync",chainId="1"} 3

# HELP envio_source_height_stream_disconnects_total The number of times a source's height subscription lost a connection, by reason. Failed retries are not counted, so this is outages rather than their length. A rotated disconnect is a connection that served its time; unsubscribed is the source being benched; every other reason ended a connection early.
# TYPE envio_source_height_stream_disconnects_total counter
envio_source_height_stream_disconnects_total{source="HyperSync",chainId="1",reason="rotated"} 4
envio_source_height_stream_disconnects_total{source="HyperSync",chainId="1",reason="401"} 1

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

# HELP envio_progress_block_time_seconds Unix timestamp of the block the chain has processed up to. Subtract it from the scrape time for how far behind chain time the indexer is, which stays honest when the data source itself is behind the chain. Best effort in realtime mode, absent during backfill.
# TYPE envio_progress_block_time_seconds gauge
envio_progress_block_time_seconds{chainId="1"} 1700000000

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

# HELP envio_indexing_addresses The number of address registrations on chain, static and dynamic. An address shared by N contracts counts N times.
# TYPE envio_indexing_addresses gauge
envio_indexing_addresses{chainId="1"} 7

# HELP envio_indexing_contract_addresses The number of address registrations per contract on chain, static and dynamic. An address shared by N contracts counts N times.
# TYPE envio_indexing_contract_addresses gauge
envio_indexing_contract_addresses{chainId="1",contract="Gravatar"} 5
envio_indexing_contract_addresses{chainId="1",contract="NftFactory"} 2
`,
    )
  })
})

describe("Metrics.merge", () => {
  let startTime = Date.fromTime(1000.)
  let metricTime = Date.fromTime(5000.)

  let handler = (~event, ~processingCount): Metrics.handlerMetrics => {
    contract: "Token",
    event,
    processingSeconds: 1.,
    processingCount,
    preloadSeconds: 0.5,
    preloadCount: 2.,
    preloadSecondsTotal: 3.,
  }

  let effect = (~cacheCount): Metrics.effectMetrics => {
    effect: "getMetadata",
    scope: "crossChain",
    callSeconds: 1.,
    callSecondsTotal: 2.,
    callCount: 3.,
    activeCallsCount: 1,
    queueCount: 2,
    queueWaitSeconds: 0.25,
    invalidationsCount: 1.,
    cacheCount,
  }

  it("Returns one worker's snapshot unchanged, taking the clock from the caller", t => {
    let only: Metrics.t = {
      ...baseMetrics,
      startTime: Date.fromTime(777.),
      metricTime: Date.fromTime(888.),
      elapsedSeconds: 42.,
      processingSeconds: 1.5,
      maxBatchSize: 5000,
      chains: [TestChainMetrics.make(~progressBlockNumber=400, ~firstEventBlockNumber=Some(150))],
      handlers: [handler(~event="Transfer", ~processingCount=4.)],
      effects: [effect(~cacheCount=Some(7))],
    }

    t.expect(Metrics.merge([only], ~startTime, ~metricTime, ~elapsedSeconds=9.)).toStrictEqual({
      ...only,
      startTime,
      metricTime,
      elapsedSeconds: 9.,
    })
  })

  it("Concatenates chain series, sums what shares a key, and folds the scalars", t => {
    let chainOne = TestChainMetrics.make(~progressBlockNumber=400, ~firstEventBlockNumber=None)
    let chainTwo = {...chainOne, Metrics.chainId: 137->ChainId.fromInt}

    let first: Metrics.t = {
      ...baseMetrics,
      targetBufferSize: 100,
      maxBatchSize: 5000,
      isInReorgThreshold: false,
      rollbackEnabled: true,
      processingSeconds: 1.5,
      rollbackCount: 1,
      chains: [chainOne],
      handlers: [handler(~event="Transfer", ~processingCount=4.)],
      effects: [effect(~cacheCount=Some(7))],
      storageWrites: [{storage: "Postgres", seconds: 2., count: 3}],
    }
    let second: Metrics.t = {
      ...baseMetrics,
      targetBufferSize: 50,
      maxBatchSize: 1000,
      isInReorgThreshold: true,
      hasArrivedAtHead: true,
      rollbackEnabled: true,
      processingSeconds: 0.5,
      rollbackCount: 2,
      chains: [chainTwo],
      handlers: [
        handler(~event="Transfer", ~processingCount=6.),
        handler(~event="Approval", ~processingCount=1.),
      ],
      effects: [effect(~cacheCount=None)],
      storageWrites: [{storage: "Postgres", seconds: 1., count: 4}],
    }

    t.expect(
      Metrics.merge([first, second], ~startTime, ~metricTime, ~elapsedSeconds=9.),
    ).toStrictEqual({
      ...baseMetrics,
      startTime,
      metricTime,
      elapsedSeconds: 9.,
      targetBufferSize: 150,
      maxBatchSize: 5000,
      isInReorgThreshold: true,
      // One worker still backfilling speaks for the whole indexer.
      hasArrivedAtHead: false,
      rollbackEnabled: true,
      processingSeconds: 2.,
      rollbackCount: 3,
      chains: [chainOne, chainTwo],
      handlers: [
        {
          ...handler(~event="Transfer", ~processingCount=10.),
          processingSeconds: 2.,
          preloadSeconds: 1.,
          preloadCount: 4.,
          preloadSecondsTotal: 6.,
        },
        handler(~event="Approval", ~processingCount=1.),
      ],
      effects: [
        {
          ...effect(~cacheCount=Some(7)),
          callSeconds: 2.,
          callSecondsTotal: 4.,
          callCount: 6.,
          activeCallsCount: 2,
          queueCount: 4,
          queueWaitSeconds: 0.5,
          invalidationsCount: 2.,
        },
      ],
      storageWrites: [{storage: "Postgres", seconds: 3., count: 7}],
    })
  })

  it("Renders an empty group as an indexer that has reported nothing yet", t => {
    t.expect(Metrics.merge([], ~startTime, ~metricTime, ~elapsedSeconds=0.)).toStrictEqual({
      ...baseMetrics,
      startTime,
      metricTime,
    })
  })
})

describe("Metrics.renderRuntime", () => {
  let sample = (~heapUsed, ~gc): Metrics.runtimeSample => {
    cpuUserSeconds: 1.5,
    cpuSystemSeconds: 0.5,
    processStartTimeSeconds: 1700000000.,
    residentMemoryBytes: 300.,
    heapTotalBytes: 200.,
    heapUsedBytes: heapUsed,
    externalMemoryBytes: 10.,
    eventLoopUtilization: 0.25,
    eventLoopLagMeanSeconds: 0.001,
    eventLoopLagMinSeconds: 0.,
    eventLoopLagMaxSeconds: 0.002,
    eventLoopLagStddevSeconds: 0.0005,
    eventLoopLagP50Seconds: 0.001,
    eventLoopLagP90Seconds: 0.0015,
    eventLoopLagP99Seconds: 0.002,
    heapSpaces: [{space: "new", size: 100., used: 40., available: 60.}],
    activeResources: [("TCPSocketWrap", 2.)],
    gc,
    nodeVersion: "v24.1.2",
  }

  // Comment lines are the same in every layout, so only the samples are compared.
  let samples = rendered =>
    rendered
    ->String.split("\n")
    ->Array.filter(line => line !== "" && !(line->String.startsWith("#")))

  it("Renders one process without labels, and a run's processes under a worker label", t => {
    t.expect((
      Metrics.renderRuntime([("", sample(~heapUsed=150., ~gc=[]))])->samples,
      Metrics.renderRuntime([
        (`worker="1"`, sample(~heapUsed=50., ~gc=[])),
        (`worker="137"`, sample(~heapUsed=150., ~gc=[{kind: "minor", count: 3., seconds: 0.03}])),
      ])->samples,
    )).toStrictEqual((
      [
        "process_cpu_user_seconds_total 1.5",
        "process_cpu_system_seconds_total 0.5",
        "process_cpu_seconds_total 2",
        "process_start_time_seconds 1700000000",
        "process_resident_memory_bytes 300",
        "nodejs_heap_size_total_bytes 200",
        "nodejs_heap_size_used_bytes 150",
        "nodejs_external_memory_bytes 10",
        "nodejs_eventloop_utilization 0.25",
        "nodejs_eventloop_lag_mean_seconds 0.001",
        "nodejs_eventloop_lag_min_seconds 0",
        "nodejs_eventloop_lag_max_seconds 0.002",
        "nodejs_eventloop_lag_stddev_seconds 0.001",
        "nodejs_eventloop_lag_p50_seconds 0.001",
        "nodejs_eventloop_lag_p90_seconds 0.002",
        "nodejs_eventloop_lag_p99_seconds 0.002",
        `nodejs_heap_space_size_total_bytes{space="new"} 100`,
        `nodejs_heap_space_size_used_bytes{space="new"} 40`,
        `nodejs_heap_space_size_available_bytes{space="new"} 60`,
        `nodejs_active_resources{type="TCPSocketWrap"} 2`,
        "nodejs_active_resources_total 2",
        `nodejs_version_info{version="v24.1.2",major="24",minor="1",patch="2"} 1`,
      ],
      [
        `process_cpu_user_seconds_total{worker="1"} 1.5`,
        `process_cpu_user_seconds_total{worker="137"} 1.5`,
        `process_cpu_system_seconds_total{worker="1"} 0.5`,
        `process_cpu_system_seconds_total{worker="137"} 0.5`,
        `process_cpu_seconds_total{worker="1"} 2`,
        `process_cpu_seconds_total{worker="137"} 2`,
        `process_start_time_seconds{worker="1"} 1700000000`,
        `process_start_time_seconds{worker="137"} 1700000000`,
        `process_resident_memory_bytes{worker="1"} 300`,
        `process_resident_memory_bytes{worker="137"} 300`,
        `nodejs_heap_size_total_bytes{worker="1"} 200`,
        `nodejs_heap_size_total_bytes{worker="137"} 200`,
        `nodejs_heap_size_used_bytes{worker="1"} 50`,
        `nodejs_heap_size_used_bytes{worker="137"} 150`,
        `nodejs_external_memory_bytes{worker="1"} 10`,
        `nodejs_external_memory_bytes{worker="137"} 10`,
        `nodejs_eventloop_utilization{worker="1"} 0.25`,
        `nodejs_eventloop_utilization{worker="137"} 0.25`,
        `nodejs_eventloop_lag_mean_seconds{worker="1"} 0.001`,
        `nodejs_eventloop_lag_mean_seconds{worker="137"} 0.001`,
        `nodejs_eventloop_lag_min_seconds{worker="1"} 0`,
        `nodejs_eventloop_lag_min_seconds{worker="137"} 0`,
        `nodejs_eventloop_lag_max_seconds{worker="1"} 0.002`,
        `nodejs_eventloop_lag_max_seconds{worker="137"} 0.002`,
        `nodejs_eventloop_lag_stddev_seconds{worker="1"} 0.001`,
        `nodejs_eventloop_lag_stddev_seconds{worker="137"} 0.001`,
        `nodejs_eventloop_lag_p50_seconds{worker="1"} 0.001`,
        `nodejs_eventloop_lag_p50_seconds{worker="137"} 0.001`,
        `nodejs_eventloop_lag_p90_seconds{worker="1"} 0.002`,
        `nodejs_eventloop_lag_p90_seconds{worker="137"} 0.002`,
        `nodejs_eventloop_lag_p99_seconds{worker="1"} 0.002`,
        `nodejs_eventloop_lag_p99_seconds{worker="137"} 0.002`,
        `nodejs_heap_space_size_total_bytes{worker="1",space="new"} 100`,
        `nodejs_heap_space_size_total_bytes{worker="137",space="new"} 100`,
        `nodejs_heap_space_size_used_bytes{worker="1",space="new"} 40`,
        `nodejs_heap_space_size_used_bytes{worker="137",space="new"} 40`,
        `nodejs_heap_space_size_available_bytes{worker="1",space="new"} 60`,
        `nodejs_heap_space_size_available_bytes{worker="137",space="new"} 60`,
        `nodejs_active_resources{worker="1",type="TCPSocketWrap"} 2`,
        `nodejs_active_resources{worker="137",type="TCPSocketWrap"} 2`,
        `nodejs_active_resources_total{worker="1"} 2`,
        `nodejs_active_resources_total{worker="137"} 2`,
        `nodejs_gc_duration_seconds_sum{worker="137",kind="minor"} 0.03`,
        `nodejs_gc_duration_seconds_count{worker="137",kind="minor"} 3`,
        `nodejs_version_info{worker="1",version="v24.1.2",major="24",minor="1",patch="2"} 1`,
        `nodejs_version_info{worker="137",version="v24.1.2",major="24",minor="1",patch="2"} 1`,
      ],
    ))
  })

  // A scrape whose last line has no line feed is a parse error to a strict
  // consumer, which drops the whole body rather than its last sample.
  it("Ends its body with a line feed, the way the text format requires", t => {
    t.expect(
      Metrics.renderRuntime([("", sample(~heapUsed=150., ~gc=[]))])->String.endsWith("\n"),
    ).toBe(true)
  })
})
