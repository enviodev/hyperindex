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
        "benchmark_summary_data",
        "benchmark_counters",
        "process_cpu_user_seconds_total",
        "process_cpu_system_seconds_total",
        "process_resident_memory_bytes",
        "nodejs_heap_size_used_bytes",
        "nodejs_heap_size_total_bytes",
        "nodejs_eventloop_lag_seconds",
        "envio_effect_calls_count",
        "envio_effect_cache_count",
        "envio_effect_calls_time",
        "envio_effect_calls_sum_time",
        "envio_effect_active_calls_count",
        "envio_effect_queue_count",
        "envio_effect_queue_time",
        "envio_storage_load_time",
        "envio_storage_load_sum_time",
        "envio_storage_load_count",
        "envio_storage_load_where_size",
        "envio_storage_load_size",
        "envio_effect_cache_invalidations_count",
        "envio_progress_latency",
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
//  Structured metric types (mirrors UI ConsolePage.res types)
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

#[derive(Debug, Default)]
struct Duration {
    max: Option<f64>,
    mean: Option<f64>,
    sum: Option<f64>,
}

#[derive(Debug, Default)]
struct BatchSize {
    max: Option<i64>,
    mean: Option<i64>,
    sum: Option<i64>,
    number: Option<i64>,
}

#[derive(Debug, Default)]
struct Handler {
    label: String,
    sum: i64,
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

#[derive(Debug, Default)]
struct PerformanceData {
    batch_size: BatchSize,
    contract_register_duration: Duration,
    load_duration: Duration,
    handler_duration: Duration,
    db_write_duration: Duration,
    total_time_elapsed: Duration,
    handlers: Vec<Handler>,
    total_run_time: Option<f64>,
    resources: ResourceMetrics,
}

#[derive(Debug, Default)]
struct EffectItem {
    name: String,
    call_count: i64,
    cache_count: i64,
    calls_time: i64,
    sum_time: i64,
    active_calls: i64,
    queue_count: i64,
    queue_time: i64,
    cache_load_time: i64,
    cache_load_count: Option<i64>,
    cache_load_where_size: Option<i64>,
    cache_load_hits: Option<i64>,
    cache_invalidations: i64,
}

#[derive(Debug, Default)]
struct StorageReadItem {
    name: String,
    load_time: i64,
    sum_time: i64,
    count: i64,
    where_size: i64,
    size: i64,
}

#[derive(Debug, Default)]
struct ChainLatency {
    chain_id: String,
    latency_ms: i64,
}

// ---------------------------------------------------------------------------
//  Grouping functions (mirrors UI ConsolePage.res grouping logic)
// ---------------------------------------------------------------------------

fn group_performance(metrics: &[Metric]) -> PerformanceData {
    let mut data = PerformanceData::default();

    for m in metrics {
        match m.name.as_str() {
            "benchmark_summary_data" => {
                let group = m.labels.get("group").map(|s| s.as_str()).unwrap_or("");
                let label = m.labels.get("label").map(|s| s.as_str()).unwrap_or("");
                let stat = m.labels.get("stat").map(|s| s.as_str()).unwrap_or("");

                if group == "EventProcessing Summary" {
                    let dur = match label {
                        "Contract Register Duration (ms)" => {
                            Some(&mut data.contract_register_duration)
                        }
                        "Load Duration (ms)" => Some(&mut data.load_duration),
                        "Handler Duration (ms)" => Some(&mut data.handler_duration),
                        "DB Write Duration (ms)" => Some(&mut data.db_write_duration),
                        "Total Time Elapsed (ms)" => Some(&mut data.total_time_elapsed),
                        _ => None,
                    };
                    if let Some(dur) = dur {
                        match stat {
                            "max" => dur.max = parse_f64(&m.value),
                            "mean" => dur.mean = parse_f64(&m.value),
                            "sum" => dur.sum = parse_f64(&m.value),
                            _ => {}
                        }
                    }
                    if label == "Batch Size" {
                        match stat {
                            "n" => data.batch_size.number = parse_i64(&m.value),
                            "max" => data.batch_size.max = parse_i64(&m.value),
                            "mean" => data.batch_size.mean = parse_i64(&m.value),
                            "sum" => data.batch_size.sum = parse_i64(&m.value),
                            _ => {}
                        }
                    }
                } else if group == "Handlers Per Event" && stat == "sum" {
                    data.handlers.push(Handler {
                        label: label.to_string(),
                        sum: parse_i64(&m.value).unwrap_or(0),
                    });
                }
            }
            "benchmark_counters" => {
                if m.labels.get("label").map(|s| s.as_str()) == Some("Total Run Time (ms)") {
                    data.total_run_time = parse_f64(&m.value);
                }
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

    // Sort handlers by sum descending
    data.handlers.sort_by(|a, b| b.sum.cmp(&a.sum));
    data
}

fn group_effects(metrics: &[Metric]) -> Vec<EffectItem> {
    let mut effects: HashMap<String, EffectItem> = HashMap::new();

    for m in metrics {
        // Effect API metrics (keyed by "effect" label)
        if let Some(effect_name) = m.labels.get("effect") {
            let item = effects
                .entry(effect_name.clone())
                .or_insert_with(|| EffectItem {
                    name: effect_name.clone(),
                    ..Default::default()
                });
            match m.name.as_str() {
                "envio_effect_calls_count" => {
                    item.call_count = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_cache_count" => {
                    item.cache_count = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_calls_time" => {
                    item.calls_time = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_calls_sum_time" => {
                    item.sum_time = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_active_calls_count" => {
                    item.active_calls = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_queue_count" => {
                    item.queue_count = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_queue_time" => {
                    item.queue_time = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_effect_cache_invalidations_count" => {
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
                    "envio_storage_load_time" => {
                        item.cache_load_time = parse_i64(&m.value).unwrap_or(0)
                    }
                    "envio_storage_load_count" => {
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
        let total_a = a.calls_time + a.cache_load_time + a.queue_time;
        let total_b = b.calls_time + b.cache_load_time + b.queue_time;
        total_b.cmp(&total_a)
    });
    sorted
}

fn group_storage_reads(metrics: &[Metric]) -> Vec<StorageReadItem> {
    let mut operations: HashMap<String, StorageReadItem> = HashMap::new();

    for m in metrics {
        if let Some(operation) = m.labels.get("operation") {
            // Skip .effect operations (those are grouped under effects)
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
                "envio_storage_load_time" => {
                    item.load_time = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_storage_load_sum_time" => {
                    item.sum_time = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_storage_load_count" => item.count = parse_i64(&m.value).unwrap_or(0),
                "envio_storage_load_where_size" => {
                    item.where_size = parse_i64(&m.value).unwrap_or(0)
                }
                "envio_storage_load_size" => item.size = parse_i64(&m.value).unwrap_or(0),
                _ => {}
            }
        }
    }

    let mut sorted: Vec<StorageReadItem> = operations.into_values().collect();
    sorted.sort_by(|a, b| b.load_time.cmp(&a.load_time));
    sorted
}

fn group_chain_latencies(metrics: &[Metric]) -> Vec<ChainLatency> {
    let mut latencies = Vec::new();
    for m in metrics {
        if m.name == "envio_progress_latency" {
            if let Some(chain_id) = m.labels.get("chainId") {
                latencies.push(ChainLatency {
                    chain_id: chain_id.clone(),
                    latency_ms: parse_i64(&m.value).unwrap_or(0),
                });
            }
        }
    }
    latencies
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

fn fmt_time_ms_i64(ms: i64) -> String {
    fmt_time_ms(ms as f64)
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

fn fmt_optional_ms(ms: Option<f64>) -> String {
    ms.map_or("-".to_string(), fmt_time_ms)
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
    events_processed: i64,
    elapsed_seconds: f64,
    events_per_second: f64,
    batch_count_delta: i64,
    avg_batch_size: f64,
}

fn compute_delta(before: &[Metric], after: &[Metric], elapsed_secs: f64) -> DeltaPerformance {
    let perf_before = group_performance(before);
    let perf_after = group_performance(after);

    let events_before = perf_before.batch_size.sum.unwrap_or(0);
    let events_after = perf_after.batch_size.sum.unwrap_or(0);
    let events_processed = events_after - events_before;

    let batches_before = perf_before.batch_size.number.unwrap_or(0);
    let batches_after = perf_after.batch_size.number.unwrap_or(0);
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
        events_processed,
        elapsed_seconds: elapsed_secs,
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
    let before_map: HashMap<&str, i64> = before.iter().map(|e| (e.name.as_str(), e.call_count)).collect();
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
    let chain_latencies = group_chain_latencies(metrics);

    let mut md = String::new();

    md.push_str("# Envio Indexer Profile\n\n");

    // ── Overview ──
    md.push_str("## Overview\n\n");

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

    let events_per_second = match (perf.batch_size.sum, perf.total_run_time) {
        (Some(size), Some(time)) if time > 0.0 => Some(size as f64 / (time / 1000.0)),
        _ => None,
    };

    md.push_str("| Metric | Value |\n|---|---|\n");
    md.push_str(&format!(
        "| Profiling Time | {} |\n",
        perf.total_run_time.map_or("-".to_string(), fmt_time_ms)
    ));
    md.push_str(&format!(
        "| Processing Time | {} |\n",
        fmt_optional_ms(perf.total_time_elapsed.sum)
    ));
    md.push_str(&format!(
        "| Total Events Processed | {} |\n",
        perf.batch_size
            .sum
            .map_or("-".to_string(), |s| fmt_number(s))
    ));
    md.push_str(&format!(
        "| Average Events/sec | {} |\n",
        events_per_second.map_or("-".to_string(), |eps| format!("{:.0}", eps))
    ));
    md.push_str(&format!(
        "| Total Batches | {} |\n",
        perf.batch_size
            .number
            .map_or("-".to_string(), |n| fmt_number(n))
    ));
    md.push_str(&format!(
        "| Mean Batch Size | {} |\n",
        perf.batch_size
            .mean
            .map_or("-".to_string(), |n| n.to_string())
    ));
    md.push_str(&format!(
        "| Max Batch Size | {} |\n",
        perf.batch_size
            .max
            .map_or("-".to_string(), |n| n.to_string())
    ));
    md.push('\n');

    // ── Processing Pipeline Breakdown ──
    md.push_str("## Processing Pipeline\n\n");
    md.push_str("| Stage | Sum | Mean | Max |\n|---|---|---|---|\n");

    let stages: &[(&str, &Duration)] = &[
        ("Loaders", &perf.load_duration),
        ("Handlers", &perf.handler_duration),
        ("DB Writes", &perf.db_write_duration),
        ("Contract Register", &perf.contract_register_duration),
        ("Total Elapsed", &perf.total_time_elapsed),
    ];
    for (name, dur) in stages {
        md.push_str(&format!(
            "| {} | {} | {} | {} |\n",
            name,
            fmt_optional_ms(dur.sum),
            fmt_optional_ms(dur.mean),
            fmt_optional_ms(dur.max),
        ));
    }
    md.push('\n');

    // ── Handlers Per Event ──
    if !perf.handlers.is_empty() {
        md.push_str("## Handlers Per Event\n\n");
        md.push_str("Sorted by total time (descending).\n\n");
        md.push_str("| Handler | Total Time |\n|---|---|\n");
        for h in &perf.handlers {
            md.push_str(&format!(
                "| {} | {} |\n",
                h.label,
                fmt_time_ms_i64(h.sum)
            ));
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
            let total_time = e.calls_time + e.cache_load_time + e.queue_time;
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
                fmt_time_ms_i64(total_time),
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
            let concurrency_saved = if e.sum_time > 0 {
                fmt_time_ms_i64(e.sum_time)
            } else {
                "-".to_string()
            };
            let avg_exec = if e.call_count > 0 && e.sum_time > 0 {
                format!(
                    " (avg {})",
                    fmt_time_ms_i64(e.sum_time / e.call_count)
                )
            } else {
                String::new()
            };
            md.push_str(&format!(
                "| {} | {} | {} | {}{} | {} |\n",
                e.name,
                fmt_time_ms_i64(e.cache_load_time),
                fmt_time_ms_i64(e.queue_time),
                fmt_time_ms_i64(e.calls_time),
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
                fmt_time_ms_i64(op.sum_time / op.count)
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
                fmt_time_ms_i64(op.load_time),
                avg_per_query,
                fmt_number(op.where_size),
                batched_pct,
                found_pct,
            ));
        }
        md.push('\n');
    }

    // ── Chain Progress Latency ──
    if !chain_latencies.is_empty() {
        md.push_str("## Chain Latency\n\n");
        md.push_str("| Chain ID | Latency |\n|---|---|\n");
        for cl in &chain_latencies {
            md.push_str(&format!(
                "| {} | {} |\n",
                cl.chain_id,
                fmt_time_ms_i64(cl.latency_ms)
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

    // Performance rating
    if let Some(eps) = events_per_second {
        if eps > 10_000.0 {
            insights.push(format!(
                "**Excellent performance** — processing {:.0} events/sec. The indexer is running optimally.",
                eps
            ));
        } else if eps > 5_000.0 {
            insights.push(format!(
                "**Very good performance** — processing {:.0} events/sec.",
                eps
            ));
        } else if eps > 1_000.0 {
            insights.push(format!(
                "**Good performance** — processing {:.0} events/sec. There may be room for optimization.",
                eps
            ));
        } else if eps > 500.0 {
            insights.push(format!(
                "**Performance could be improved** — only {:.0} events/sec. Review handler and loader durations below.",
                eps
            ));
        } else {
            insights.push(format!(
                "**Performance needs optimization** — only {:.0} events/sec. This indicates significant bottlenecks.",
                eps
            ));
        }
    }

    // Profiling vs processing time gap
    if let (Some(run_time), Some(processing_time)) =
        (perf.total_run_time, perf.total_time_elapsed.sum)
    {
        if run_time > 0.0 {
            let utilization = processing_time / run_time * 100.0;
            if utilization < 70.0 {
                insights.push(format!(
                    "**Processing utilization is low** ({:.0}%). The indexer spends {:.0}% of profiling time idle, likely waiting for event fetching. Ensure HyperSync is enabled for all supported networks and use field selection to prevent over-fetching.",
                    utilization,
                    100.0 - utilization,
                ));
            } else {
                insights.push(format!(
                    "Processing utilization: {:.0}% — event fetching is not a bottleneck.",
                    utilization,
                ));
            }
        }
    }

    // Batch size insights
    if let Some(mean_batch) = perf.batch_size.mean {
        if mean_batch < 100 {
            insights.push(format!(
                "**Small average batch size** ({}) — this suggests events are sparse or fetching is slow. For historical sync, batch sizes close to 5,000 are ideal.",
                mean_batch
            ));
        }
    }

    // Handler bottleneck
    if let (Some(handler_sum), Some(total_sum)) =
        (perf.handler_duration.sum, perf.total_time_elapsed.sum)
    {
        if total_sum > 0.0 {
            let handler_pct = handler_sum / total_sum * 100.0;
            if handler_pct > 50.0 {
                insights.push(format!(
                    "**Handlers are the main bottleneck** — {:.0}% of processing time. Move async operations to loaders using `Promise.all` for parallelization.",
                    handler_pct
                ));
            }
        }
    }

    // Loader bottleneck
    if let (Some(load_sum), Some(total_sum)) =
        (perf.load_duration.sum, perf.total_time_elapsed.sum)
    {
        if total_sum > 0.0 {
            let load_pct = load_sum / total_sum * 100.0;
            if load_pct > 40.0 {
                insights.push(format!(
                    "**Loaders are a significant bottleneck** — {:.0}% of processing time. Use `Promise.all` for multiple async operations and consider using the Effect API for external calls.",
                    load_pct
                ));
            }
        }
    }

    // DB write bottleneck
    if let (Some(db_sum), Some(total_sum)) =
        (perf.db_write_duration.sum, perf.total_time_elapsed.sum)
    {
        if total_sum > 0.0 {
            let db_pct = db_sum / total_sum * 100.0;
            if db_pct > 30.0 {
                insights.push(format!(
                    "**DB writes are a significant bottleneck** — {:.0}% of processing time. Consider reducing the number of entity writes or optimizing your schema.",
                    db_pct
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
            fmt_time_ms_i64(top.sum),
            second.label,
            fmt_time_ms_i64(second.sum),
        ));
    } else if let Some(top) = perf.handlers.first() {
        insights.push(format!(
            "**Slowest handler**: `{}` ({}).",
            top.label,
            fmt_time_ms_i64(top.sum),
        ));
    }

    // Effect insights
    for e in &effects {
        let total = e.calls_time + e.cache_load_time + e.queue_time;
        if e.queue_time > 0 && total > 0 {
            let queue_pct = e.queue_time as f64 / total as f64 * 100.0;
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

    // ── Raw metric counts (for AI consumption) ──
    md.push_str("## Raw Metric Summary\n\n");
    md.push_str("<details>\n<summary>Full metric values for AI analysis</summary>\n\n");
    md.push_str("```\n");
    md.push_str(&format!(
        "total_run_time_ms={}\n",
        perf.total_run_time.map_or("-".to_string(), |v| format!("{:.0}", v))
    ));
    md.push_str(&format!(
        "total_events={}\n",
        perf.batch_size.sum.map_or("-".to_string(), |v| v.to_string())
    ));
    md.push_str(&format!(
        "total_batches={}\n",
        perf.batch_size.number.map_or("-".to_string(), |v| v.to_string())
    ));
    md.push_str(&format!(
        "events_per_second={}\n",
        events_per_second.map_or("-".to_string(), |v| format!("{:.1}", v))
    ));
    md.push_str(&format!(
        "handler_sum_ms={}\n",
        perf.handler_duration.sum.map_or("-".to_string(), |v| format!("{:.0}", v))
    ));
    md.push_str(&format!(
        "loader_sum_ms={}\n",
        perf.load_duration.sum.map_or("-".to_string(), |v| format!("{:.0}", v))
    ));
    md.push_str(&format!(
        "db_write_sum_ms={}\n",
        perf.db_write_duration.sum.map_or("-".to_string(), |v| format!("{:.0}", v))
    ));
    md.push_str(&format!(
        "memory_mb={}\n",
        perf.resources.memory_bytes.map_or("-".to_string(), |v| format!("{:.1}", v / 1024.0 / 1024.0))
    ));
    md.push_str(&format!(
        "event_loop_lag_ms={}\n",
        perf.resources.event_loop_lag.map_or("-".to_string(), |v| format!("{:.2}", v * 1000.0))
    ));
    md.push_str("```\n\n");
    md.push_str("</details>\n");

    md
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
