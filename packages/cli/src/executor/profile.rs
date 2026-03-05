use crate::cli_args::clap_definitions::ProfileArgs;
use anyhow::{Context, Result};
use std::collections::HashMap;

const DEFAULT_HOST: &str = "localhost";
const DEFAULT_PORT: u16 = 9898;

/// Resolve the indexer base URL from args > env vars > .env file > defaults.
fn resolve_base_url(args: &ProfileArgs) -> String {
    if let Some(ref url) = args.url {
        return url.clone();
    }

    // Try loading .env file (best-effort)
    let _ = dotenvy::EnvLoader::with_path(".env")
        .sequence(dotenvy::EnvSequence::EnvThenInput)
        .load();

    let host = std::env::var("ENVIO_INDEXER_HOST").unwrap_or_else(|_| DEFAULT_HOST.to_string());
    let port = std::env::var("ENVIO_INDEXER_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT);

    format!("http://{}:{}", host, port)
}

// ---------------------------------------------------------------------------
//  Prometheus text-format parser (mirrors UI ConsolePage.res Metrics module)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Metric {
    name: String,
    labels: HashMap<String, String>,
    value: String,
}

fn parse_prometheus_metrics(text: &str) -> Vec<Metric> {
    let selected: std::collections::HashSet<&str> = [
        // System resources
        "process_cpu_user_seconds_total",
        "process_cpu_system_seconds_total",
        "process_resident_memory_bytes",
        "nodejs_heap_size_used_bytes",
        "nodejs_heap_size_total_bytes",
        "nodejs_eventloop_lag_seconds",
        // Processing pipeline counters
        "envio_preload_seconds",
        "envio_processing_seconds",
        "envio_storage_write_seconds",
        "envio_storage_write_total",
        "envio_processing_max_batch_size",
        // Per-handler metrics
        "envio_processing_handler_seconds",
        "envio_processing_handler_total",
        "envio_preload_handler_seconds",
        "envio_preload_handler_total",
        "envio_preload_handler_seconds_total",
        // Fetching metrics (per chain)
        "envio_fetching_block_range_seconds",
        "envio_fetching_block_range_parse_seconds",
        "envio_fetching_block_range_total",
        "envio_fetching_block_range_events_total",
        "envio_fetching_block_range_size",
        // Indexing metrics (per chain)
        "envio_indexing_known_height",
        "envio_indexing_addresses",
        "envio_indexing_max_concurrency",
        "envio_indexing_concurrency",
        "envio_indexing_partitions",
        "envio_indexing_idle_seconds",
        "envio_indexing_source_waiting_seconds",
        "envio_indexing_source_querying_seconds",
        "envio_indexing_buffer_size",
        "envio_indexing_target_buffer_size",
        "envio_indexing_buffer_block",
        "envio_indexing_end_block",
        // Source metrics
        "envio_source_request_total",
        "envio_source_request_seconds_total",
        "envio_source_known_height",
        // Progress metrics
        "envio_progress_block",
        "envio_progress_events",
        "envio_progress_latency",
        "envio_progress_ready",
        // Info
        "envio_info",
        // Effect API metrics
        "envio_effect_call_total",
        "envio_effect_cache",
        "envio_effect_call_seconds",
        "envio_effect_call_seconds_total",
        "envio_effect_active_calls",
        "envio_effect_queue",
        "envio_effect_queue_wait_seconds",
        "envio_effect_cache_invalidations",
        // Storage load metrics
        "envio_storage_load_seconds",
        "envio_storage_load_seconds_total",
        "envio_storage_load_total",
        "envio_storage_load_where_size",
        "envio_storage_load_size",
        // Sink metrics
        "envio_sink_write_seconds",
        "envio_sink_write_total",
        // Reorg metrics
        "envio_reorg_detected_total",
        "envio_rollback_total",
        "envio_rollback_seconds",
        "envio_rollback_events",
    ]
    .into_iter()
    .collect();

    let mut metrics = Vec::new();

    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Split name{labels} value
        let (name, rest) = if let Some(brace_pos) = line.find('{') {
            (&line[..brace_pos], &line[brace_pos..])
        } else {
            // name value
            let parts: Vec<&str> = line.splitn(2, ' ').collect();
            if parts.len() != 2 {
                continue;
            }
            if !selected.contains(parts[0]) {
                continue;
            }
            metrics.push(Metric {
                name: parts[0].to_string(),
                labels: HashMap::new(),
                value: parts[1].to_string(),
            });
            continue;
        };

        if !selected.contains(name) {
            continue;
        }

        // Parse labels between { and }
        let labels_end = match rest.find('}') {
            Some(pos) => pos,
            None => continue,
        };
        let labels_str = &rest[1..labels_end];
        let value_str = rest[labels_end + 1..].trim();

        let mut labels = HashMap::new();
        // Simple label parser: key="value",key="value"
        for part in split_labels(labels_str) {
            if let Some(eq_pos) = part.find('=') {
                let key = part[..eq_pos].trim();
                let val = part[eq_pos + 1..].trim().trim_matches('"');
                labels.insert(key.to_string(), val.to_string());
            }
        }

        metrics.push(Metric {
            name: name.to_string(),
            labels,
            value: value_str.to_string(),
        });
    }

    metrics
}

/// Split label string respecting quoted values (commas inside quotes are ignored).
fn split_labels(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut in_quotes = false;

    for (i, c) in s.char_indices() {
        match c {
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                let part = s[start..i].trim();
                if !part.is_empty() {
                    parts.push(part);
                }
                start = i + 1;
            }
            _ => {}
        }
    }
    let remaining = s[start..].trim();
    if !remaining.is_empty() {
        parts.push(remaining);
    }
    parts
}

// ---------------------------------------------------------------------------
//  Structured metric types
// ---------------------------------------------------------------------------

fn parse_f64(s: &str) -> Option<f64> {
    s.parse::<f64>().ok()
}

fn parse_i64(s: &str) -> Option<i64> {
    // Handle float strings like "1234.0" from prometheus
    s.parse::<i64>()
        .ok()
        .or_else(|| s.parse::<f64>().ok().map(|f| f as i64))
}

/// Convert seconds (float from counter) to milliseconds
fn secs_to_ms(s: &str) -> Option<f64> {
    parse_f64(s).map(|v| v * 1000.0)
}

#[derive(Debug, Default)]
struct ResourceMetrics {
    cpu_user: Option<f64>,
    cpu_system: Option<f64>,
    memory_bytes: Option<f64>,
    heap_used: Option<f64>,
    heap_total: Option<f64>,
    event_loop_lag: Option<f64>,
}

/// Per-handler timing from envio_processing_handler_* and envio_preload_handler_*
#[derive(Debug, Default)]
struct HandlerMetric {
    label: String,
    handler_seconds: f64,
    handler_count: i64,
    preload_seconds: f64,
    preload_count: i64,
    preload_sum_seconds: f64,
}

/// Processing pipeline data from the new counter-based metrics
#[derive(Debug, Default)]
struct PerformanceData {
    // Cumulative pipeline durations (seconds converted to ms for display)
    preload_ms: Option<f64>,
    processing_ms: Option<f64>,
    storage_write_ms: Option<f64>,
    storage_write_count: Option<i64>,
    max_batch_size: Option<i64>,
    // Per-handler breakdown
    handlers: Vec<HandlerMetric>,
    resources: ResourceMetrics,
    // Info
    version: Option<String>,
}

#[derive(Debug, Default)]
struct EffectItem {
    name: String,
    call_count: i64,
    cache_count: i64,
    call_seconds: f64,
    sum_seconds: f64,
    active_calls: i64,
    queue_count: i64,
    queue_wait_seconds: f64,
    cache_load_seconds: f64,
    cache_load_count: Option<i64>,
    cache_load_where_size: Option<i64>,
    cache_load_hits: Option<i64>,
    cache_invalidations: i64,
}

#[derive(Debug, Default)]
struct StorageReadItem {
    name: String,
    load_seconds: f64,
    sum_seconds: f64,
    count: i64,
    where_size: i64,
    size: i64,
}

/// Per-chain fetching stats from envio_fetching_block_range_*
#[derive(Debug, Default)]
struct FetchingChainData {
    chain_id: String,
    fetch_seconds: f64,
    parse_seconds: f64,
    fetch_count: i64,
    events_fetched: i64,
    blocks_covered: i64,
}

/// Per-chain indexing status from envio_indexing_*
#[derive(Debug, Default)]
struct IndexingChainData {
    chain_id: String,
    known_height: Option<i64>,
    addresses: Option<i64>,
    max_concurrency: Option<i64>,
    concurrency: Option<i64>,
    partitions: Option<i64>,
    idle_seconds: f64,
    source_waiting_seconds: f64,
    source_querying_seconds: f64,
    buffer_size: Option<i64>,
    buffer_block: Option<i64>,
    end_block: Option<i64>,
}

/// Per-chain progress from envio_progress_*
#[derive(Debug, Default)]
struct ProgressChainData {
    chain_id: String,
    block: Option<i64>,
    events: Option<i64>,
    latency_ms: Option<i64>,
    ready: bool,
}

/// Sink write metrics
#[derive(Debug, Default)]
struct SinkItem {
    name: String,
    write_seconds: f64,
    write_count: i64,
}

/// Reorg/rollback summary
#[derive(Debug, Default)]
struct ReorgData {
    reorgs_detected: i64,
    rollbacks: i64,
    rollback_seconds: f64,
    rollback_events: i64,
}

// ---------------------------------------------------------------------------
//  Grouping functions
// ---------------------------------------------------------------------------

fn group_performance(metrics: &[Metric]) -> PerformanceData {
    let mut data = PerformanceData::default();
    let mut handler_map: HashMap<String, HandlerMetric> = HashMap::new();

    for m in metrics {
        match m.name.as_str() {
            "envio_preload_seconds" => data.preload_ms = secs_to_ms(&m.value),
            "envio_processing_seconds" => data.processing_ms = secs_to_ms(&m.value),
            "envio_storage_write_seconds" => data.storage_write_ms = secs_to_ms(&m.value),
            "envio_storage_write_total" => data.storage_write_count = parse_i64(&m.value),
            "envio_processing_max_batch_size" => data.max_batch_size = parse_i64(&m.value),
            "envio_processing_handler_seconds" | "envio_processing_handler_total"
            | "envio_preload_handler_seconds" | "envio_preload_handler_total"
            | "envio_preload_handler_seconds_total" => {
                let contract = m.labels.get("contract").map(|s| s.as_str()).unwrap_or("?");
                let event = m.labels.get("event").map(|s| s.as_str()).unwrap_or("?");
                let key = format!("{} {}", contract, event);
                let h = handler_map.entry(key.clone()).or_insert_with(|| HandlerMetric {
                    label: key,
                    ..Default::default()
                });
                match m.name.as_str() {
                    "envio_processing_handler_seconds" => {
                        h.handler_seconds = parse_f64(&m.value).unwrap_or(0.0)
                    }
                    "envio_processing_handler_total" => {
                        h.handler_count = parse_i64(&m.value).unwrap_or(0)
                    }
                    "envio_preload_handler_seconds" => {
                        h.preload_seconds = parse_f64(&m.value).unwrap_or(0.0)
                    }
                    "envio_preload_handler_total" => {
                        h.preload_count = parse_i64(&m.value).unwrap_or(0)
                    }
                    "envio_preload_handler_seconds_total" => {
                        h.preload_sum_seconds = parse_f64(&m.value).unwrap_or(0.0)
                    }
                    _ => {}
                }
            }
            "envio_info" => {
                data.version = m.labels.get("version").cloned();
            }
            "process_cpu_user_seconds_total" => data.resources.cpu_user = parse_f64(&m.value),
            "process_cpu_system_seconds_total" => data.resources.cpu_system = parse_f64(&m.value),
            "process_resident_memory_bytes" => data.resources.memory_bytes = parse_f64(&m.value),
            "nodejs_heap_size_used_bytes" => data.resources.heap_used = parse_f64(&m.value),
            "nodejs_heap_size_total_bytes" => data.resources.heap_total = parse_f64(&m.value),
            "nodejs_eventloop_lag_seconds" => data.resources.event_loop_lag = parse_f64(&m.value),
            _ => {}
        }
    }

    let mut handlers: Vec<HandlerMetric> = handler_map.into_values().collect();
    // Sort by total time (handler + preload) descending
    handlers.sort_by(|a, b| {
        let total_a = a.handler_seconds + a.preload_seconds;
        let total_b = b.handler_seconds + b.preload_seconds;
        total_b
            .partial_cmp(&total_a)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    data.handlers = handlers;
    data
}

fn group_effects(metrics: &[Metric]) -> Vec<EffectItem> {
    let mut effects: HashMap<String, EffectItem> = HashMap::new();

    for m in metrics {
        if let Some(effect_name) = m.labels.get("effect") {
            let item = effects
                .entry(effect_name.clone())
                .or_insert_with(|| EffectItem {
                    name: effect_name.clone(),
                    ..Default::default()
                });
            match m.name.as_str() {
                "envio_effect_call_total" => {
                    item.call_count = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_cache" => {
                    item.cache_count = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_call_seconds" => {
                    item.call_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_effect_call_seconds_total" => {
                    item.sum_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_effect_active_calls" => {
                    item.active_calls = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_queue" => {
                    item.queue_count = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_queue_wait_seconds" => {
                    item.queue_wait_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_effect_cache_invalidations" => {
                    item.cache_invalidations = parse_i64(&m.value).unwrap_or(0)
                }
                _ => {}
            }
        }

        // Storage load metrics ending in ".effect" feed into effect items
        if let Some(operation) = m.labels.get("operation") {
            if operation.ends_with(".effect") {
                let effect_name = &operation[..operation.len() - 7];
                let item = effects
                    .entry(effect_name.to_string())
                    .or_insert_with(|| EffectItem {
                        name: effect_name.to_string(),
                        ..Default::default()
                    });
                match m.name.as_str() {
                    "envio_storage_load_seconds" => {
                        item.cache_load_seconds = parse_f64(&m.value).unwrap_or(0.0)
                    }
                    "envio_storage_load_total" => {
                        item.cache_load_count = parse_i64(&m.value)
                    }
                    "envio_storage_load_where_size" => {
                        item.cache_load_where_size = parse_i64(&m.value)
                    }
                    "envio_storage_load_size" => {
                        item.cache_load_hits = parse_i64(&m.value)
                    }
                    _ => {}
                }
            }
        }
    }

    let mut sorted: Vec<EffectItem> = effects.into_values().collect();
    sorted.sort_by(|a, b| {
        let total_a = a.call_seconds + a.cache_load_seconds + a.queue_wait_seconds;
        let total_b = b.call_seconds + b.cache_load_seconds + b.queue_wait_seconds;
        total_b
            .partial_cmp(&total_a)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    sorted
}

fn group_storage_reads(metrics: &[Metric]) -> Vec<StorageReadItem> {
    let mut operations: HashMap<String, StorageReadItem> = HashMap::new();

    for m in metrics {
        if let Some(operation) = m.labels.get("operation") {
            if operation.ends_with(".effect") {
                continue;
            }
            let item = operations
                .entry(operation.clone())
                .or_insert_with(|| StorageReadItem {
                    name: operation.clone(),
                    ..Default::default()
                });
            match m.name.as_str() {
                "envio_storage_load_seconds" => {
                    item.load_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_storage_load_seconds_total" => {
                    item.sum_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_storage_load_total" => item.count = parse_i64(&m.value).unwrap_or(0),
                "envio_storage_load_where_size" => {
                    item.where_size = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_storage_load_size" => item.size = parse_i64(&m.value).unwrap_or(0),
                _ => {}
            }
        }
    }

    let mut sorted: Vec<StorageReadItem> = operations.into_values().collect();
    sorted.sort_by(|a, b| {
        b.load_seconds
            .partial_cmp(&a.load_seconds)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    sorted
}

fn group_fetching(metrics: &[Metric]) -> Vec<FetchingChainData> {
    let mut chains: HashMap<String, FetchingChainData> = HashMap::new();

    for m in metrics {
        if let Some(chain_id) = m.labels.get("chainId") {
            let entry = chains
                .entry(chain_id.clone())
                .or_insert_with(|| FetchingChainData {
                    chain_id: chain_id.clone(),
                    ..Default::default()
                });
            match m.name.as_str() {
                "envio_fetching_block_range_seconds" => {
                    entry.fetch_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_fetching_block_range_parse_seconds" => {
                    entry.parse_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_fetching_block_range_total" => {
                    entry.fetch_count = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_fetching_block_range_events_total" => {
                    entry.events_fetched = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_fetching_block_range_size" => {
                    entry.blocks_covered = parse_i64(&m.value).unwrap_or(0)
                }
                _ => {}
            }
        }
    }

    let mut sorted: Vec<FetchingChainData> = chains.into_values().collect();
    sorted.sort_by(|a, b| a.chain_id.cmp(&b.chain_id));
    sorted
}

fn group_indexing(metrics: &[Metric]) -> (Vec<IndexingChainData>, Option<i64>) {
    let mut chains: HashMap<String, IndexingChainData> = HashMap::new();
    let mut target_buffer_size: Option<i64> = None;

    for m in metrics {
        if m.name == "envio_indexing_target_buffer_size" {
            target_buffer_size = parse_i64(&m.value);
            continue;
        }

        if let Some(chain_id) = m.labels.get("chainId") {
            let entry = chains
                .entry(chain_id.clone())
                .or_insert_with(|| IndexingChainData {
                    chain_id: chain_id.clone(),
                    ..Default::default()
                });
            match m.name.as_str() {
                "envio_indexing_known_height" => entry.known_height = parse_i64(&m.value),
                "envio_indexing_addresses" => entry.addresses = parse_i64(&m.value),
                "envio_indexing_max_concurrency" => entry.max_concurrency = parse_i64(&m.value),
                "envio_indexing_concurrency" => entry.concurrency = parse_i64(&m.value),
                "envio_indexing_partitions" => entry.partitions = parse_i64(&m.value),
                "envio_indexing_idle_seconds" => {
                    entry.idle_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_indexing_source_waiting_seconds" => {
                    entry.source_waiting_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_indexing_source_querying_seconds" => {
                    entry.source_querying_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_indexing_buffer_size" => entry.buffer_size = parse_i64(&m.value),
                "envio_indexing_buffer_block" => entry.buffer_block = parse_i64(&m.value),
                "envio_indexing_end_block" => entry.end_block = parse_i64(&m.value),
                _ => {}
            }
        }
    }

    let mut sorted: Vec<IndexingChainData> = chains.into_values().collect();
    sorted.sort_by(|a, b| a.chain_id.cmp(&b.chain_id));
    (sorted, target_buffer_size)
}

fn group_progress(metrics: &[Metric]) -> Vec<ProgressChainData> {
    let mut chains: HashMap<String, ProgressChainData> = HashMap::new();

    for m in metrics {
        if let Some(chain_id) = m.labels.get("chainId") {
            let entry = chains
                .entry(chain_id.clone())
                .or_insert_with(|| ProgressChainData {
                    chain_id: chain_id.clone(),
                    ..Default::default()
                });
            match m.name.as_str() {
                "envio_progress_block" => entry.block = parse_i64(&m.value),
                "envio_progress_events" => entry.events = parse_i64(&m.value),
                "envio_progress_latency" => entry.latency_ms = parse_i64(&m.value),
                "envio_progress_ready" => {
                    entry.ready = parse_i64(&m.value).unwrap_or(0) == 1
                }
                _ => {}
            }
        }
    }

    let mut sorted: Vec<ProgressChainData> = chains.into_values().collect();
    sorted.sort_by(|a, b| a.chain_id.cmp(&b.chain_id));
    sorted
}

fn group_sinks(metrics: &[Metric]) -> Vec<SinkItem> {
    let mut sinks: HashMap<String, SinkItem> = HashMap::new();

    for m in metrics {
        if let Some(sink_name) = m.labels.get("sink") {
            let item = sinks
                .entry(sink_name.clone())
                .or_insert_with(|| SinkItem {
                    name: sink_name.clone(),
                    ..Default::default()
                });
            match m.name.as_str() {
                "envio_sink_write_seconds" => {
                    item.write_seconds = parse_f64(&m.value).unwrap_or(0.0)
                }
                "envio_sink_write_total" => {
                    item.write_count = parse_i64(&m.value).unwrap_or(0)
                }
                _ => {}
            }
        }
    }

    let mut sorted: Vec<SinkItem> = sinks.into_values().collect();
    sorted.sort_by(|a, b| {
        b.write_seconds
            .partial_cmp(&a.write_seconds)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    sorted
}

fn group_reorg(metrics: &[Metric]) -> ReorgData {
    let mut data = ReorgData::default();
    for m in metrics {
        match m.name.as_str() {
            "envio_reorg_detected_total" => {
                data.reorgs_detected += parse_i64(&m.value).unwrap_or(0)
            }
            "envio_rollback_total" => data.rollbacks = parse_i64(&m.value).unwrap_or(0),
            "envio_rollback_seconds" => {
                data.rollback_seconds = parse_f64(&m.value).unwrap_or(0.0)
            }
            "envio_rollback_events" => data.rollback_events = parse_i64(&m.value).unwrap_or(0),
            _ => {}
        }
    }
    data
}

// ---------------------------------------------------------------------------
//  Formatting helpers
// ---------------------------------------------------------------------------

fn fmt_time_ms(ms: f64) -> String {
    if ms < 1000.0 {
        format!("{:.0}ms", ms)
    } else if ms < 60_000.0 {
        format!("{:.1}s", ms / 1000.0)
    } else {
        let mins = (ms / 60_000.0).floor() as u64;
        let secs = (ms % 60_000.0) / 1000.0;
        format!("{}m {:.0}s", mins, secs)
    }
}

fn fmt_time_secs(secs: f64) -> String {
    fmt_time_ms(secs * 1000.0)
}

fn fmt_optional_ms(ms: Option<f64>) -> String {
    ms.map_or("-".to_string(), fmt_time_ms)
}

fn fmt_bytes(bytes: f64) -> String {
    if bytes < 1024.0 * 1024.0 {
        format!("{:.1}KB", bytes / 1024.0)
    } else if bytes < 1024.0 * 1024.0 * 1024.0 {
        format!("{:.1}MB", bytes / 1024.0 / 1024.0)
    } else {
        format!("{:.2}GB", bytes / 1024.0 / 1024.0 / 1024.0)
    }
}

fn fmt_number(n: i64) -> String {
    if n < 1_000 {
        return n.to_string();
    }
    let s = n.to_string();
    let mut result = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            result.push(',');
        }
        result.push(c);
    }
    result.chars().rev().collect()
}

// ---------------------------------------------------------------------------
//  Delta computation for --duration mode
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct DeltaPerformance {
    elapsed_seconds: f64,
    events_processed: i64,
    events_per_second: f64,
    batch_count_delta: i64,
    avg_batch_size: f64,
}

fn compute_delta(before: &[Metric], after: &[Metric], elapsed_secs: f64) -> DeltaPerformance {
    // Use progress events to compute events processed during the window
    let progress_before = group_progress(before);
    let progress_after = group_progress(after);

    let events_before: i64 = progress_before.iter().filter_map(|p| p.events).sum();
    let events_after: i64 = progress_after.iter().filter_map(|p| p.events).sum();
    let events_processed = events_after - events_before;

    let perf_before = group_performance(before);
    let perf_after = group_performance(after);

    let batches_before = perf_before.storage_write_count.unwrap_or(0);
    let batches_after = perf_after.storage_write_count.unwrap_or(0);
    let batch_count_delta = batches_after - batches_before;

    let events_per_second = if elapsed_secs > 0.0 {
        events_processed as f64 / elapsed_secs
    } else {
        0.0
    };

    let avg_batch_size = if batch_count_delta > 0 {
        events_processed as f64 / batch_count_delta as f64
    } else {
        0.0
    };

    DeltaPerformance {
        elapsed_seconds: elapsed_secs,
        events_processed,
        events_per_second,
        batch_count_delta,
        avg_batch_size,
    }
}

fn compute_effect_deltas(
    before: &[EffectItem],
    after: &[EffectItem],
    elapsed_secs: f64,
) -> Vec<(String, f64)> {
    let before_map: HashMap<&str, i64> =
        before.iter().map(|e| (e.name.as_str(), e.call_count)).collect();
    let mut deltas = Vec::new();
    for e in after {
        let prev = before_map.get(e.name.as_str()).copied().unwrap_or(0);
        let diff = e.call_count - prev;
        if diff > 0 && elapsed_secs > 0.0 {
            deltas.push((e.name.clone(), diff as f64 / elapsed_secs));
        }
    }
    deltas.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    deltas
}

// ---------------------------------------------------------------------------
//  Markdown report generation
// ---------------------------------------------------------------------------

fn generate_report(
    metrics: &[Metric],
    delta: Option<&DeltaPerformance>,
    effect_rps: Option<&[(String, f64)]>,
) -> String {
    let perf = group_performance(metrics);
    let effects = group_effects(metrics);
    let storage_reads = group_storage_reads(metrics);
    let fetching = group_fetching(metrics);
    let (indexing, target_buffer_size) = group_indexing(metrics);
    let progress = group_progress(metrics);
    let sinks = group_sinks(metrics);
    let reorg = group_reorg(metrics);

    let mut md = String::new();

    md.push_str("# Envio Indexer Profile\n\n");

    // ── Overview ──
    md.push_str("## Overview\n\n");

    if let Some(version) = &perf.version {
        md.push_str(&format!("**Envio version**: {}\n\n", version));
    }

    if let Some(delta) = delta {
        md.push_str(&format!(
            "**Sampling window**: {:.1}s | **Events processed during window**: {} | **Live events/sec**: {:.0}\n\n",
            delta.elapsed_seconds,
            fmt_number(delta.events_processed),
            delta.events_per_second,
        ));
        if delta.batch_count_delta > 0 {
            md.push_str(&format!(
                "**Batches during window**: {} | **Avg batch size**: {:.0}\n\n",
                delta.batch_count_delta, delta.avg_batch_size,
            ));
        }
    }

    let total_events: i64 = progress.iter().filter_map(|p| p.events).sum();
    let total_processing_ms = [perf.preload_ms, perf.processing_ms, perf.storage_write_ms]
        .iter()
        .filter_map(|v| *v)
        .sum::<f64>();

    md.push_str("| Metric | Value |\n|---|---|\n");
    md.push_str(&format!(
        "| Total Events Processed | {} |\n",
        if total_events > 0 {
            fmt_number(total_events)
        } else {
            "-".to_string()
        }
    ));
    md.push_str(&format!(
        "| Total Batches | {} |\n",
        perf.storage_write_count
            .map_or("-".to_string(), |n| fmt_number(n))
    ));
    md.push_str(&format!(
        "| Max Batch Size | {} |\n",
        perf.max_batch_size
            .map_or("-".to_string(), |n| fmt_number(n))
    ));
    md.push('\n');

    // ── Processing Pipeline Breakdown ──
    md.push_str("## Processing Pipeline\n\n");
    md.push_str("Cumulative time spent in each processing stage.\n\n");
    md.push_str("| Stage | Time |\n|---|---|\n");
    md.push_str(&format!(
        "| Loaders (preload) | {} |\n",
        fmt_optional_ms(perf.preload_ms)
    ));
    md.push_str(&format!(
        "| Handlers (processing) | {} |\n",
        fmt_optional_ms(perf.processing_ms)
    ));
    md.push_str(&format!(
        "| DB Writes | {} |\n",
        fmt_optional_ms(perf.storage_write_ms)
    ));
    if total_processing_ms > 0.0 {
        md.push_str(&format!(
            "| **Total** | **{}** |\n",
            fmt_time_ms(total_processing_ms)
        ));
    }
    md.push('\n');

    // Pipeline percentage breakdown
    if total_processing_ms > 0.0 {
        if let (Some(preload), Some(processing), Some(write)) =
            (perf.preload_ms, perf.processing_ms, perf.storage_write_ms)
        {
            md.push_str(&format!(
                "Pipeline split: Loaders {:.0}% | Handlers {:.0}% | DB Writes {:.0}%\n\n",
                preload / total_processing_ms * 100.0,
                processing / total_processing_ms * 100.0,
                write / total_processing_ms * 100.0,
            ));
        }
    }

    // ── Per-Handler Breakdown ──
    if !perf.handlers.is_empty() {
        md.push_str("## Handler Breakdown\n\n");
        md.push_str("Per-handler timing sorted by total time (handler + preload).\n\n");
        md.push_str("| Handler | Handler Time | Calls | Preload Time | Preload Calls |\n|---|---|---|---|---|\n");
        for h in &perf.handlers {
            md.push_str(&format!(
                "| {} | {} | {} | {} | {} |\n",
                h.label,
                fmt_time_secs(h.handler_seconds),
                fmt_number(h.handler_count),
                fmt_time_secs(h.preload_seconds),
                fmt_number(h.preload_count),
            ));
        }
        md.push('\n');
    }

    // ── Chain Progress ──
    if !progress.is_empty() {
        md.push_str("## Chain Progress\n\n");
        md.push_str("| Chain | Block | Events | Latency | Synced |\n|---|---|---|---|---|\n");
        for p in &progress {
            md.push_str(&format!(
                "| {} | {} | {} | {} | {} |\n",
                p.chain_id,
                p.block.map_or("-".to_string(), |b| fmt_number(b)),
                p.events.map_or("-".to_string(), |e| fmt_number(e)),
                p.latency_ms
                    .map_or("-".to_string(), |ms| fmt_time_ms(ms as f64)),
                if p.ready { "Yes" } else { "No" },
            ));
        }
        md.push('\n');
    }

    // ── Fetching Performance ──
    if !fetching.is_empty() {
        md.push_str("## Fetching Performance\n\n");
        md.push_str("Per-chain data fetching statistics.\n\n");
        md.push_str("| Chain | Fetch Time | Parse Time | Fetches | Events Fetched | Blocks Covered | Avg Events/Fetch |\n|---|---|---|---|---|---|---|\n");
        for f in &fetching {
            let avg_events_per_fetch = if f.fetch_count > 0 {
                format!("{:.0}", f.events_fetched as f64 / f.fetch_count as f64)
            } else {
                "-".to_string()
            };
            md.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} | {} |\n",
                f.chain_id,
                fmt_time_secs(f.fetch_seconds),
                fmt_time_secs(f.parse_seconds),
                fmt_number(f.fetch_count),
                fmt_number(f.events_fetched),
                fmt_number(f.blocks_covered),
                avg_events_per_fetch,
            ));
        }
        md.push('\n');
    }

    // ── Indexing Status ──
    if !indexing.is_empty() {
        md.push_str("## Indexing Status\n\n");
        md.push_str("Per-chain indexing configuration and timing.\n\n");
        md.push_str("| Chain | Known Height | Buffer | Concurrency | Partitions | Addresses | Idle Time | Waiting | Querying |\n|---|---|---|---|---|---|---|---|---|\n");
        for idx in &indexing {
            md.push_str(&format!(
                "| {} | {} | {} | {}/{} | {} | {} | {} | {} | {} |\n",
                idx.chain_id,
                idx.known_height.map_or("-".to_string(), |h| fmt_number(h)),
                idx.buffer_size.map_or("-".to_string(), |b| fmt_number(b)),
                idx.concurrency.map_or("-".to_string(), |c| c.to_string()),
                idx.max_concurrency.map_or("-".to_string(), |c| c.to_string()),
                idx.partitions.map_or("-".to_string(), |p| p.to_string()),
                idx.addresses.map_or("-".to_string(), |a| fmt_number(a)),
                fmt_time_secs(idx.idle_seconds),
                fmt_time_secs(idx.source_waiting_seconds),
                fmt_time_secs(idx.source_querying_seconds),
            ));
        }
        if let Some(tbs) = target_buffer_size {
            md.push_str(&format!("\nTarget buffer size: {}\n", fmt_number(tbs)));
        }
        md.push('\n');
    }

    // ── Effects API ──
    if !effects.is_empty() {
        md.push_str("## Effect API Breakdown\n\n");
        md.push_str("Sorted by total time (cache loading + queue + execution).\n\n");
        md.push_str(
            "| Effect | Total Time | Calls | Active | Queue | Cache | Batched % | Invalidations |\n\
             |---|---|---|---|---|---|---|---|\n",
        );
        for e in &effects {
            let total_time = e.call_seconds + e.cache_load_seconds + e.queue_wait_seconds;
            let batched_pct = match (e.cache_load_where_size, e.cache_load_count) {
                (Some(ws), Some(c)) if ws > 0 && c > 0 => {
                    let saved = ws - c;
                    format!("{:.1}%", saved as f64 / ws as f64 * 100.0)
                }
                _ => "-".to_string(),
            };
            md.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} | {} | {} |\n",
                e.name,
                fmt_time_secs(total_time),
                fmt_number(e.call_count),
                e.active_calls,
                e.queue_count,
                fmt_number(e.cache_count),
                batched_pct,
                fmt_number(e.cache_invalidations),
            ));
        }
        md.push('\n');

        // Per-effect time breakdown
        md.push_str("### Effect Time Breakdown\n\n");
        md.push_str("| Effect | Cache Loading | Queue Time | Execution | Concurrency Saved |\n|---|---|---|---|---|\n");
        for e in &effects {
            let concurrency_saved = if e.sum_seconds > 0.0 {
                fmt_time_secs(e.sum_seconds)
            } else {
                "-".to_string()
            };
            let avg_exec = if e.call_count > 0 && e.sum_seconds > 0.0 {
                format!(
                    " (avg {})",
                    fmt_time_secs(e.sum_seconds / e.call_count as f64)
                )
            } else {
                String::new()
            };
            md.push_str(&format!(
                "| {} | {} | {} | {}{} | {} |\n",
                e.name,
                fmt_time_secs(e.cache_load_seconds),
                fmt_time_secs(e.queue_wait_seconds),
                fmt_time_secs(e.call_seconds),
                avg_exec,
                concurrency_saved,
            ));
        }
        md.push('\n');

        // Effect RPS from delta mode
        if let Some(rps_data) = effect_rps {
            if !rps_data.is_empty() {
                md.push_str("### Effect Requests/sec (during sampling window)\n\n");
                md.push_str("| Effect | RPS |\n|---|---|\n");
                for (name, rps) in rps_data {
                    md.push_str(&format!("| {} | {:.1} |\n", name, rps));
                }
                md.push('\n');
            }
        }
    }

    // ── Storage Reads ──
    if !storage_reads.is_empty() {
        md.push_str("## Storage Reads (Entity Loads)\n\n");
        md.push_str("Sorted by processing time (descending).\n\n");
        md.push_str("| Operation | Time | Avg/Query | Calls | Batched % | Found % |\n|---|---|---|---|---|---|\n");
        for op in &storage_reads {
            let avg_per_query = if op.count > 0 {
                fmt_time_secs(op.sum_seconds / op.count as f64)
            } else {
                "-".to_string()
            };
            let batched_pct = if op.where_size > 0 && op.count > 0 {
                let saved = op.where_size - op.count;
                format!("{:.1}%", saved as f64 / op.where_size as f64 * 100.0)
            } else {
                "-".to_string()
            };
            let found_pct = if op.where_size > 0 && op.size > 0 {
                format!("{:.1}%", op.size as f64 / op.where_size as f64 * 100.0)
            } else {
                "-".to_string()
            };
            md.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} |\n",
                op.name,
                fmt_time_secs(op.load_seconds),
                avg_per_query,
                fmt_number(op.where_size),
                batched_pct,
                found_pct,
            ));
        }
        md.push('\n');
    }

    // ── Sink Writes ──
    if !sinks.is_empty() {
        md.push_str("## Sink Writes\n\n");
        md.push_str("| Sink | Time | Writes |\n|---|---|---|\n");
        for s in &sinks {
            md.push_str(&format!(
                "| {} | {} | {} |\n",
                s.name,
                fmt_time_secs(s.write_seconds),
                fmt_number(s.write_count),
            ));
        }
        md.push('\n');
    }

    // ── Reorg/Rollback ──
    if reorg.reorgs_detected > 0 || reorg.rollbacks > 0 {
        md.push_str("## Reorgs & Rollbacks\n\n");
        md.push_str("| Metric | Value |\n|---|---|\n");
        md.push_str(&format!(
            "| Reorgs Detected | {} |\n",
            fmt_number(reorg.reorgs_detected)
        ));
        md.push_str(&format!(
            "| Rollbacks | {} |\n",
            fmt_number(reorg.rollbacks)
        ));
        if reorg.rollback_seconds > 0.0 {
            md.push_str(&format!(
                "| Rollback Time | {} |\n",
                fmt_time_secs(reorg.rollback_seconds)
            ));
        }
        if reorg.rollback_events > 0 {
            md.push_str(&format!(
                "| Events Rolled Back | {} |\n",
                fmt_number(reorg.rollback_events)
            ));
        }
        md.push('\n');
    }

    // ── System Resources ──
    md.push_str("## System Resources\n\n");
    md.push_str("| Resource | Value |\n|---|---|\n");
    md.push_str(&format!(
        "| CPU Usage | {} |\n",
        match (perf.resources.cpu_user, perf.resources.cpu_system) {
            (Some(user), Some(system)) => format!(
                "{:.2}s total ({:.2}s user, {:.2}s system)",
                user + system,
                user,
                system
            ),
            _ => "-".to_string(),
        }
    ));
    md.push_str(&format!(
        "| Memory (RSS) | {} |\n",
        perf.resources
            .memory_bytes
            .map_or("-".to_string(), fmt_bytes)
    ));
    md.push_str(&format!(
        "| Heap Usage | {} |\n",
        match (perf.resources.heap_used, perf.resources.heap_total) {
            (Some(used), Some(total)) => format!("{} / {}", fmt_bytes(used), fmt_bytes(total)),
            _ => "-".to_string(),
        }
    ));
    md.push_str(&format!(
        "| Event Loop Lag | {} |\n",
        perf.resources
            .event_loop_lag
            .map_or("-".to_string(), |lag| format!("{:.2}ms", lag * 1000.0))
    ));
    md.push('\n');

    // ── Insights & Suggestions ──
    md.push_str("## Insights & Suggestions\n\n");

    let mut insights = Vec::new();

    // Performance rating from delta mode
    if let Some(delta) = delta {
        if delta.events_per_second > 10_000.0 {
            insights.push(format!(
                "**Excellent performance** — processing {:.0} events/sec.",
                delta.events_per_second
            ));
        } else if delta.events_per_second > 5_000.0 {
            insights.push(format!(
                "**Very good performance** — processing {:.0} events/sec.",
                delta.events_per_second
            ));
        } else if delta.events_per_second > 1_000.0 {
            insights.push(format!(
                "**Good performance** — processing {:.0} events/sec. There may be room for optimization.",
                delta.events_per_second
            ));
        } else if delta.events_per_second > 500.0 {
            insights.push(format!(
                "**Performance could be improved** — only {:.0} events/sec.",
                delta.events_per_second
            ));
        } else if delta.events_processed > 0 {
            insights.push(format!(
                "**Performance needs optimization** — only {:.0} events/sec.",
                delta.events_per_second
            ));
        }
    }

    // Pipeline bottleneck detection
    if total_processing_ms > 0.0 {
        if let Some(handler_ms) = perf.processing_ms {
            let handler_pct = handler_ms / total_processing_ms * 100.0;
            if handler_pct > 50.0 {
                insights.push(format!(
                    "**Handlers are the main bottleneck** — {:.0}% of processing time. Move async operations to loaders using `Promise.all` for parallelization.",
                    handler_pct
                ));
            }
        }
        if let Some(preload_ms) = perf.preload_ms {
            let preload_pct = preload_ms / total_processing_ms * 100.0;
            if preload_pct > 40.0 {
                insights.push(format!(
                    "**Loaders are a significant bottleneck** — {:.0}% of processing time. Use `Promise.all` for multiple async operations and consider using the Effect API for external calls.",
                    preload_pct
                ));
            }
        }
        if let Some(write_ms) = perf.storage_write_ms {
            let write_pct = write_ms / total_processing_ms * 100.0;
            if write_pct > 30.0 {
                insights.push(format!(
                    "**DB writes are a significant bottleneck** — {:.0}% of processing time. Consider reducing the number of entity writes or optimizing your schema.",
                    write_pct
                ));
            }
        }
    }

    // Slowest handlers
    if perf.handlers.len() >= 2 {
        let top = &perf.handlers[0];
        let second = &perf.handlers[1];
        insights.push(format!(
            "**Slowest handlers**: `{}` ({}) and `{}` ({}).",
            top.label,
            fmt_time_secs(top.handler_seconds + top.preload_seconds),
            second.label,
            fmt_time_secs(second.handler_seconds + second.preload_seconds),
        ));
    } else if let Some(top) = perf.handlers.first() {
        insights.push(format!(
            "**Slowest handler**: `{}` ({}).",
            top.label,
            fmt_time_secs(top.handler_seconds + top.preload_seconds),
        ));
    }

    // Fetching insights
    for f in &fetching {
        if f.fetch_count > 0 {
            let avg_fetch_time = f.fetch_seconds / f.fetch_count as f64;
            if avg_fetch_time > 5.0 {
                insights.push(format!(
                    "**Chain {} has slow fetch times** (avg {:.1}s per fetch). Consider enabling HyperSync or using field selection to reduce payload size.",
                    f.chain_id, avg_fetch_time
                ));
            }
        }
    }

    // Indexing idle time insights
    for idx in &indexing {
        let total_time = idx.idle_seconds + idx.source_waiting_seconds + idx.source_querying_seconds;
        if total_time > 0.0 && idx.idle_seconds / total_time > 0.5 {
            insights.push(format!(
                "**Chain {} indexer is idle {:.0}% of the time** — event processing is faster than fetching. Ensure HyperSync is enabled and use field selection.",
                idx.chain_id,
                idx.idle_seconds / total_time * 100.0,
            ));
        }
    }

    // Effect insights
    for e in &effects {
        let total = e.call_seconds + e.cache_load_seconds + e.queue_wait_seconds;
        if e.queue_wait_seconds > 0.0 && total > 0.0 {
            let queue_pct = e.queue_wait_seconds / total * 100.0;
            if queue_pct > 30.0 {
                insights.push(format!(
                    "**Effect `{}` has high queue time** ({:.0}% of its total time). Consider increasing concurrency or optimizing the external service.",
                    e.name, queue_pct
                ));
            }
        }
        if e.cache_invalidations > 0 && e.cache_count > 0 {
            let inv_rate = e.cache_invalidations as f64 / e.cache_count as f64 * 100.0;
            if inv_rate > 20.0 {
                insights.push(format!(
                    "**Effect `{}` has high cache invalidation rate** ({:.0}%). The cache key strategy may need adjustment.",
                    e.name, inv_rate
                ));
            }
        }
    }

    // Storage read insights
    for op in &storage_reads {
        if op.where_size > 0 && op.size > 0 {
            let found_pct = op.size as f64 / op.where_size as f64 * 100.0;
            if found_pct < 30.0 && op.where_size > 100 {
                insights.push(format!(
                    "**Storage read `{}` has low hit rate** ({:.0}%). Many lookups return empty — consider if all these reads are necessary.",
                    op.name, found_pct
                ));
            }
        }
    }

    // Memory insight
    if let Some(mem) = perf.resources.memory_bytes {
        if mem > 1024.0 * 1024.0 * 1024.0 {
            insights.push(format!(
                "**High memory usage** ({}). Consider optimizing entity caching or reducing batch sizes.",
                fmt_bytes(mem)
            ));
        }
    }

    // Event loop lag insight
    if let Some(lag) = perf.resources.event_loop_lag {
        if lag > 0.1 {
            insights.push(format!(
                "**High event loop lag** ({:.0}ms). This indicates heavy synchronous computation blocking the Node.js event loop. Move CPU-intensive work to async operations.",
                lag * 1000.0
            ));
        }
    }

    if insights.is_empty() {
        md.push_str("No specific insights available. The indexer may still be starting up.\n");
    } else {
        for insight in &insights {
            md.push_str(&format!("- {}\n", insight));
        }
    }

    md.push('\n');

    // Add spaces to table separators for readability: |---|---| → | --- | --- |
    let mut result = String::new();
    let mut chars = md.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '|' {
            // Check for |---
            let rest: String = chars.clone().take(3).collect();
            if rest == "---" {
                result.push_str("| --- ");
                chars.nth(2); // skip the three dashes
                continue;
            }
        }
        result.push(c);
    }
    result
}

// ---------------------------------------------------------------------------
//  HTTP fetch
// ---------------------------------------------------------------------------

async fn fetch_metrics(client: &reqwest::Client, base_url: &str) -> Result<String> {
    let url = format!("{}/metrics", base_url);
    let resp = client
        .get(&url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .context(format!("Failed to connect to indexer at {}", url))?;

    if !resp.status().is_success() {
        anyhow::bail!(
            "Indexer returned HTTP {} from {}",
            resp.status(),
            url
        );
    }

    resp.text()
        .await
        .context("Failed to read metrics response body")
}

// ---------------------------------------------------------------------------
//  Entry point
// ---------------------------------------------------------------------------

/// Parse metrics and generate a markdown report from raw prometheus text.
/// Extracted for testability.
fn report_from_prometheus_text(text: &str) -> String {
    let metrics = parse_prometheus_metrics(text);
    generate_report(&metrics, None, None)
}

pub async fn run_profile(args: ProfileArgs) -> Result<()> {
    let base_url = resolve_base_url(&args);
    let client = reqwest::Client::new();

    eprintln!("Fetching metrics from {} ...", base_url);

    let duration = args.duration;

    if let Some(secs) = duration {
        // Duration mode: sample start and end, compute deltas
        let secs = secs.max(3); // minimum 3 seconds
        eprintln!("Sampling for {} seconds...", secs);

        let before_text = fetch_metrics(&client, &base_url).await?;
        let before_metrics = parse_prometheus_metrics(&before_text);
        let effects_before = group_effects(&before_metrics);

        tokio::time::sleep(std::time::Duration::from_secs(secs)).await;

        let after_text = fetch_metrics(&client, &base_url).await?;
        let after_metrics = parse_prometheus_metrics(&after_text);
        let effects_after = group_effects(&after_metrics);

        let delta = compute_delta(&before_metrics, &after_metrics, secs as f64);
        let effect_rps = compute_effect_deltas(&effects_before, &effects_after, secs as f64);

        let report = generate_report(&after_metrics, Some(&delta), Some(&effect_rps));
        println!("{}", report);
    } else {
        // Instant mode: single snapshot
        let text = fetch_metrics(&client, &base_url).await?;
        let metrics = parse_prometheus_metrics(&text);
        let report = generate_report(&metrics, None, None);
        println!("{}", report);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_report_from_prometheus_metrics() {
        let input = r#"
# HELP envio_preload_seconds Cumulative time spent on preloading entities during batch processing.
# TYPE envio_preload_seconds counter
envio_preload_seconds 0.066200668
# HELP envio_processing_seconds Cumulative time spent executing event handlers during batch processing.
# TYPE envio_processing_seconds counter
envio_processing_seconds 0.03451024900000001
# HELP envio_storage_write_seconds Cumulative time spent writing batch data to storage.
# TYPE envio_storage_write_seconds counter
envio_storage_write_seconds 0.14491870900000003
# HELP envio_storage_write_total Total number of batch writes to storage.
# TYPE envio_storage_write_total counter
envio_storage_write_total 4
# HELP envio_progress_ready Whether the chain is fully synced to the head.
# TYPE envio_progress_ready gauge
# HELP hyperindex_synced_to_head All chains fully synced
# TYPE hyperindex_synced_to_head gauge
hyperindex_synced_to_head 0
# HELP envio_processing_handler_seconds Cumulative time spent inside individual event handler executions.
# TYPE envio_processing_handler_seconds counter
envio_processing_handler_seconds{contract="ERC20",event="Approval"} 0.007507434000000004
envio_processing_handler_seconds{contract="ERC20",event="Transfer"} 0.018549728
# HELP envio_processing_handler_total Total number of individual event handler executions.
# TYPE envio_processing_handler_total counter
envio_processing_handler_total{contract="ERC20",event="Approval"} 3434
envio_processing_handler_total{contract="ERC20",event="Transfer"} 6607
# HELP envio_preload_handler_seconds Wall-clock time spent inside individual preload handler executions.
# TYPE envio_preload_handler_seconds counter
envio_preload_handler_seconds{contract="ERC20",event="Approval"} 0.028596248999999997
envio_preload_handler_seconds{contract="ERC20",event="Transfer"} 0.06534654299999999
# HELP envio_preload_handler_total Total number of individual preload handler executions.
# TYPE envio_preload_handler_total counter
envio_preload_handler_total{contract="ERC20",event="Approval"} 3434
envio_preload_handler_total{contract="ERC20",event="Transfer"} 6607
# HELP envio_preload_handler_seconds_total Cumulative time spent inside individual preload handler executions. Can exceed wall-clock time due to parallel execution.
# TYPE envio_preload_handler_seconds_total counter
envio_preload_handler_seconds_total{contract="ERC20",event="Approval"} 27.46140452299992
envio_preload_handler_seconds_total{contract="ERC20",event="Transfer"} 164.58959649099964
# HELP envio_fetching_block_range_seconds Cumulative time spent fetching block ranges.
# TYPE envio_fetching_block_range_seconds counter
envio_fetching_block_range_seconds{chainId="1"} 19.410937083
# HELP envio_fetching_block_range_parse_seconds Cumulative time spent parsing block range fetch responses.
# TYPE envio_fetching_block_range_parse_seconds counter
envio_fetching_block_range_parse_seconds{chainId="1"} 0.137992167
# HELP envio_fetching_block_range_total Total number of block range fetch operations.
# TYPE envio_fetching_block_range_total counter
envio_fetching_block_range_total{chainId="1"} 2
# HELP envio_fetching_block_range_events_total Cumulative number of events fetched across all block range operations.
# TYPE envio_fetching_block_range_events_total counter
envio_fetching_block_range_events_total{chainId="1"} 10041
# HELP envio_fetching_block_range_size Cumulative number of blocks covered across all block range fetch operations.
# TYPE envio_fetching_block_range_size counter
envio_fetching_block_range_size{chainId="1"} 132690
# HELP envio_indexing_known_height The latest known block number reported by the active indexing source.
# TYPE envio_indexing_known_height gauge
envio_indexing_known_height{chainId="1"} 24592713
# HELP envio_info Information about the indexer
# TYPE envio_info gauge
envio_info{version="0.0.1-dev"} 1
# HELP envio_indexing_addresses The number of addresses indexed on chain.
# TYPE envio_indexing_addresses gauge
envio_indexing_addresses{chainId="1"} 1
# HELP envio_indexing_max_concurrency The maximum number of concurrent queries to the chain data-source.
# TYPE envio_indexing_max_concurrency gauge
envio_indexing_max_concurrency{chainId="1"} 10
# HELP envio_indexing_concurrency The number of executing concurrent queries to the chain data-source.
# TYPE envio_indexing_concurrency gauge
envio_indexing_concurrency{chainId="1"} 6
# HELP envio_indexing_partitions The number of partitions used to split fetching logic.
# TYPE envio_indexing_partitions gauge
envio_indexing_partitions{chainId="1"} 1
# HELP envio_indexing_idle_seconds The time the indexer source syncing has been idle.
# TYPE envio_indexing_idle_seconds counter
envio_indexing_idle_seconds{chainId="1"} 0.115673209
# HELP envio_indexing_source_waiting_seconds The time the indexer has been waiting for new blocks.
# TYPE envio_indexing_source_waiting_seconds counter
envio_indexing_source_waiting_seconds{chainId="1"} 1.7183905419999999
# HELP envio_indexing_source_querying_seconds The time spent performing queries to the chain data-source.
# TYPE envio_indexing_source_querying_seconds counter
envio_indexing_source_querying_seconds{chainId="1"} 19.490299541
# HELP envio_indexing_buffer_size The current number of items in the indexing buffer.
# TYPE envio_indexing_buffer_size gauge
envio_indexing_buffer_size{chainId="1"} 0
# HELP envio_indexing_target_buffer_size The target buffer size per chain for indexing.
# TYPE envio_indexing_target_buffer_size gauge
envio_indexing_target_buffer_size 50000
# HELP envio_indexing_buffer_block The highest block number that has been fully fetched by the indexer.
# TYPE envio_indexing_buffer_block gauge
envio_indexing_buffer_block{chainId="1"} 18732689
# HELP envio_source_request_total The number of requests made to data sources.
# TYPE envio_source_request_total counter
envio_source_request_total{source="HyperSync",chainId="1",method="getHeight"} 1
envio_source_request_total{source="HyperSync",chainId="1",method="getLogs"} 14
envio_source_request_total{source="HyperSync",chainId="1",method="getBlockHashes"} 2
# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter
envio_source_request_seconds_total{source="HyperSync",chainId="1",method="getHeight"} 1.7180131250000001
# HELP envio_source_known_height The latest known block number reported by the source.
# TYPE envio_source_known_height gauge
envio_source_known_height{source="HyperSync",chainId="1"} 24592713
# HELP envio_reorg_detected_total Total number of reorgs detected
# TYPE envio_reorg_detected_total counter
# HELP envio_reorg_threshold Whether indexing is currently within the reorg threshold
# TYPE envio_reorg_threshold gauge
envio_reorg_threshold 0
# HELP envio_rollback_enabled Whether rollback on reorg is enabled
# TYPE envio_rollback_enabled gauge
envio_rollback_enabled 1
# HELP envio_rollback_seconds Rollback on reorg total time.
# TYPE envio_rollback_seconds counter
envio_rollback_seconds 0
# HELP envio_rollback_total Number of successful rollbacks on reorg
# TYPE envio_rollback_total counter
envio_rollback_total 0
# HELP envio_rollback_events Number of events rollbacked on reorg
# TYPE envio_rollback_events counter
envio_rollback_events 0
# HELP envio_processing_max_batch_size The maximum number of items to process in a single batch.
# TYPE envio_processing_max_batch_size gauge
envio_processing_max_batch_size 5000
# HELP envio_progress_block The block number of the latest block processed and stored in the database.
# TYPE envio_progress_block gauge
envio_progress_block{chainId="1"} 18732689
# HELP envio_progress_events The number of events processed and reflected in the database.
# TYPE envio_progress_events gauge
envio_progress_events{chainId="1"} 10041
# HELP envio_progress_latency The latency in milliseconds between the latest processed event creation and the time it was written to storage.
# TYPE envio_progress_latency gauge
envio_progress_latency{chainId="1"} 2080747478
# HELP envio_storage_load_seconds Processing time taken to load data from storage.
# TYPE envio_storage_load_seconds counter
envio_storage_load_seconds{operation="Account.get"} 0.026509540999999998
# HELP envio_storage_load_seconds_total Cumulative time spent loading data from storage during the indexing process.
# TYPE envio_storage_load_seconds_total counter
envio_storage_load_seconds_total{operation="Account.get"} 0.026582
# HELP envio_storage_load_total Cumulative number of successful storage load operations during the indexing process.
# TYPE envio_storage_load_total counter
envio_storage_load_total{operation="Account.get"} 4
# HELP envio_storage_load_where_size Cumulative number of filter conditions used in storage load operations.
# TYPE envio_storage_load_where_size counter
envio_storage_load_where_size{operation="Account.get"} 2477
# HELP envio_storage_load_size Cumulative number of records loaded from storage.
# TYPE envio_storage_load_size counter
envio_storage_load_size{operation="Account.get"} 267
"#;

        let report = report_from_prometheus_text(input);
        insta::assert_snapshot!(report);
    }
}
