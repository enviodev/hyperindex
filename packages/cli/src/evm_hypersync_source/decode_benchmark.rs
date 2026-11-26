//! How much a HyperSync page costs between the HTTP response and the page of
//! rows `get_items` returns: allocations, bytes allocated, peak memory held,
//! threads started and time, at each stage of the path.
//!
//! The page comes from the mock server pre-encoded, over real HTTP, so the
//! numbers cover only the client side. Run in release for meaningful times:
//!
//! ```text
//! cargo test --release --lib decode_benchmark -- --ignored --nocapture --test-threads=1
//! ```

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::config::{ClientConfig, SerializationFormat};
use super::topic_filter::TopicFilterInput;
use super::types::OnEventRegistrationInput;
use super::{EvmHyperSyncClient, ItemsQuery};
use crate::address_store::test_support::{evm_store, set_of};
use crate::address_store::AddressSet;
use crate::allocation_counter::{self, AllocationTotals};
use crate::chain_buffer::{ChainBuffer, ChainBufferConfig, RegistrationsInput};
use crate::mock_hypersync_server::MockHyperSyncServer;

const TRANSFER_TOPIC0: &str = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const FIRST_BLOCK: u64 = 20_000_000;
const REGISTERED_ADDRESSES: usize = 10_000;
const ITERATIONS: u32 = 5;

struct Scenario {
    name: &'static str,
    logs: usize,
    /// The logs spread evenly over this many blocks.
    blocks: usize,
    /// One log in this many comes from a registered address; the rest are
    /// what a wildcard query returns for client-side filtering to drop.
    kept_one_in: usize,
    client_filtered: bool,
}

const SCENARIOS: &[Scenario] = &[
    Scenario {
        name: "client-filtered, 1% kept",
        logs: 100_000,
        blocks: 10_000,
        kept_one_in: 100,
        client_filtered: true,
    },
    Scenario {
        name: "server-filtered, all kept",
        logs: 100_000,
        blocks: 10_000,
        kept_one_in: 1,
        client_filtered: false,
    },
];

/// Hashes and addresses are as good as random on a real chain, and Cap'n
/// Proto's packing shrinks zero bytes, so counters would make the response
/// body unrealistically small.
fn random_hex(seed: u64, bytes: usize) -> String {
    let mut state = seed;
    let mut out = String::with_capacity(2 + bytes * 2);
    out.push_str("0x");
    while out.len() < 2 + bytes * 2 {
        // splitmix64
        state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut word = state;
        word = (word ^ (word >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        word = (word ^ (word >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        word ^= word >> 31;
        out.push_str(&format!("{word:016x}"));
    }
    out.truncate(2 + bytes * 2);
    out
}

fn registered_address(index: usize) -> String {
    random_hex(index as u64, 20)
}

fn unregistered_address(index: usize) -> String {
    random_hex((1 << 40) + index as u64, 20)
}

fn topic_of_address(address: &str) -> String {
    format!("0x{:0>64}", &address[2..])
}

fn block_of_log(scenario: &Scenario, index: usize) -> u64 {
    FIRST_BLOCK + (index * scenario.blocks / scenario.logs) as u64
}

fn transfer_page(scenario: &Scenario) -> Value {
    let block_count = scenario.blocks;
    let blocks: Vec<Value> = (0..block_count as u64)
        .map(|offset| {
            let number = FIRST_BLOCK + offset;
            json!({
                "number": number,
                "timestamp": 1_700_000_000 + offset * 12,
                "hash": random_hex((2 << 40) + number, 32),
            })
        })
        .collect();
    let logs: Vec<Value> = (0..scenario.logs)
        .map(|index| {
            let address = if index % scenario.kept_one_in == 0 {
                registered_address(index / scenario.kept_one_in % REGISTERED_ADDRESSES)
            } else {
                unregistered_address(index)
            };
            json!({
                "block_number": block_of_log(scenario, index),
                "log_index": index,
                "transaction_index": index,
                "address": address,
                "topic0": TRANSFER_TOPIC0,
                "topic1": topic_of_address(&unregistered_address(index + 1)),
                "topic2": topic_of_address(&unregistered_address(index + 2)),
                "data": random_hex((3 << 40) + index as u64, 32),
            })
        })
        .collect();
    json!({
        "nextBlock": FIRST_BLOCK + block_count as u64,
        "archiveHeight": FIRST_BLOCK + block_count as u64,
        "blocks": blocks,
        "logs": logs,
    })
}

fn transfer_registration() -> OnEventRegistrationInput {
    OnEventRegistrationInput {
        index: 0,
        sighash: Some(TRANSFER_TOPIC0.to_string()),
        topic_count: 3,
        event_name: "Transfer".to_string(),
        contract_name: "Token".to_string(),
        is_wildcard: false,
        depends_on_addresses: true,
        start_block: None,
        params: vec![],
        topic_filters: vec![TopicFilterInput {
            topic0: Some(vec![TRANSFER_TOPIC0.to_string()]),
            topic1: Some(vec![]),
            topic2: Some(vec![]),
            topic3: Some(vec![]),
        }],
        block_fields: vec![],
        transaction_fields: vec![],
    }
}

struct Indexer {
    client: EvmHyperSyncClient,
    /// hypersync-client, which the transport replaced, to measure against.
    baseline: hypersync_client::Client,
    buffer: ChainBuffer,
    address_set: AddressSet,
    /// For the stages that read the response themselves.
    http: reqwest::Client,
    url: String,
    _server: MockHyperSyncServer,
}

fn make_indexer(scenario: &Scenario) -> (Indexer, usize) {
    let server = MockHyperSyncServer::new(Some(0), None).unwrap();
    let body_bytes = server.serve_fixed_page(&transfer_page(scenario)).unwrap();

    let addresses: Vec<String> = (0..REGISTERED_ADDRESSES).map(registered_address).collect();
    let address_refs: Vec<&str> = addresses.iter().map(String::as_str).collect();
    let store = evm_store(&[("Token", &address_refs)]);
    let buffer = ChainBuffer::make(
        ChainBufferConfig {
            registrations: RegistrationsInput::Evm {
                registrations: vec![transfer_registration()],
            },
            should_checksum: false,
            contract_register_indexes: vec![],
            block_handlers: vec![],
            transaction_masks: vec![],
            event_block_masks: vec![],
            transaction_registrations: vec![],
        },
        &store,
    )
    .unwrap();
    let client = EvmHyperSyncClient::new(
        ClientConfig {
            url: server.url(),
            api_token: "00000000-0000-0000-0000-000000000000".to_string(),
            // What the indexer runs with by default.
            serialization_format: Some(SerializationFormat::CapnProto),
            enable_query_caching: Some(true),
            ..Default::default()
        },
        "benchmark".to_string(),
        &buffer,
    )
    .unwrap();
    let address_set = set_of(&store, &["Token"]);
    let baseline = hypersync_client::Client::new_with_agent(
        hypersync_client::ClientConfig {
            url: server.url(),
            api_token: "00000000-0000-0000-0000-000000000000".to_string(),
            serialization_format: hypersync_client::SerializationFormat::CapnProto {
                should_cache_queries: true,
            },
            ..Default::default()
        },
        "benchmark",
    )
    .unwrap();
    (
        Indexer {
            client,
            baseline,
            buffer,
            address_set,
            http: reqwest::Client::new(),
            url: server.url(),
            _server: server,
        },
        body_bytes,
    )
}

#[derive(Clone, Copy)]
enum Stage {
    /// What hypersync-client does to reach Arrow, one copy at a time: the body
    /// collected into one buffer,
    BodyCollected,
    /// then unpacked from Cap'n Proto's packed encoding,
    BodyUnpacked,
    /// then each table read by Arrow's `FileReader`, which copies its buffers.
    ArrowCopied,
    /// hypersync-client: the HTTP body read, unpacked and parsed into Arrow
    /// record batches,
    Arrow,
    /// then converted to `simple_types` rows.
    Rows,
    /// The transport: the body unpacked as it downloads, Arrow read in place.
    Transport,
    /// The whole of `get_items`: logs matched on the columns and the kept
    /// rows copied into the page.
    GetItems,
}

impl Stage {
    fn name(self) -> &'static str {
        match self {
            Stage::BodyCollected => "body collected",
            Stage::BodyUnpacked => "+ capnp unpacked",
            Stage::ArrowCopied => "+ arrow FileReader",
            Stage::Arrow => "hypersync-client: arrow",
            Stage::Rows => "+ simple_types rows",
            Stage::Transport => "transport: arrow",
            Stage::GetItems => "+ match + page (get_items)",
        }
    }
}

async fn post_query(indexer: &Indexer) -> reqwest::Response {
    // The fixed page answers any query.
    indexer
        .http
        .post(format!("{}/query/arrow-ipc", indexer.url))
        .body("{}")
        .send()
        .await
        .unwrap()
}

fn capnp_options() -> capnp::message::ReaderOptions {
    let mut options = capnp::message::ReaderOptions::new();
    options
        .nesting_limit(i32::MAX)
        .traversal_limit_in_words(None);
    options
}

/// The Arrow IPC files of the response's block, transaction and log tables.
fn table_files<S: capnp::message::ReaderSegments>(
    message: &capnp::message::Reader<S>,
) -> [&[u8]; 3] {
    let data = message
        .get_root::<hypersync_net_types::hypersync_net_types_capnp::query_response::Reader>()
        .unwrap()
        .get_data()
        .unwrap();
    [
        data.get_blocks().unwrap(),
        data.get_transactions().unwrap(),
        data.get_logs().unwrap(),
    ]
}

fn read_file_copied(file: &[u8]) -> Vec<arrow::array::RecordBatch> {
    arrow::ipc::reader::FileReader::try_new(std::io::Cursor::new(file), None)
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

fn log_rows(batches: &[arrow::array::RecordBatch]) -> usize {
    batches.iter().map(|batch| batch.num_rows()).sum()
}

/// Runs one page through `stage`, returning the logs the page kept, or for the
/// stages that stop at Arrow, the log rows read.
async fn run_stage(indexer: &Indexer, scenario: &Scenario, stage: Stage) -> usize {
    let raw_query = hypersync_client::net_types::Query {
        from_block: FIRST_BLOCK,
        ..Default::default()
    };
    match stage {
        Stage::Arrow => {
            let response = indexer
                .baseline
                .get_arrow_with_rate_limit(&raw_query)
                .await
                .unwrap();
            drop(response);
            0
        }
        Stage::Rows => {
            let response = indexer
                .baseline
                .get_with_rate_limit(&raw_query)
                .await
                .unwrap();
            drop(response);
            0
        }
        Stage::Transport => {
            let outcome = indexer.client.transport.query(&raw_query).await.unwrap();
            let super::transport::QueryOutcome::Response(response) = outcome else {
                panic!("rate limited")
            };
            assert_eq!(log_rows(&response.logs), scenario.logs);
            0
        }
        Stage::GetItems => {
            let block_count = scenario.blocks as i64;
            let (_, page) = indexer
                .client
                .get_items(
                    ItemsQuery {
                        from_block: FIRST_BLOCK as i64,
                        to_block: Some(FIRST_BLOCK as i64 + block_count - 1),
                        on_event_registration_indexes: vec![0],
                        on_block_registration_indexes: vec![],
                        on_transaction_registration_indexes: vec![],
                        client_filtered_contracts: scenario
                            .client_filtered
                            .then(|| vec!["Token".to_string()]),
                        reorgable_from: None,
                    },
                    &indexer.address_set,
                    &indexer.buffer,
                )
                .await
                .unwrap();
            let kept = page.take().events.len();
            drop(page);
            kept
        }
        Stage::BodyCollected => {
            let body = post_query(indexer).await.bytes().await.unwrap();
            assert!(!body.is_empty());
            0
        }
        Stage::BodyUnpacked => {
            let body = post_query(indexer).await.bytes().await.unwrap();
            let message =
                capnp::serialize_packed::read_message(&body[..], capnp_options()).unwrap();
            table_files(&message);
            0
        }
        Stage::ArrowCopied => {
            let body = post_query(indexer).await.bytes().await.unwrap();
            let message =
                capnp::serialize_packed::read_message(&body[..], capnp_options()).unwrap();
            let [blocks, transactions, logs] = table_files(&message).map(read_file_copied);
            drop((blocks, transactions));
            assert_eq!(log_rows(&logs), scenario.logs);
            0
        }
    }
}

struct Measurement {
    totals: AllocationTotals,
    threads_started: u64,
    duration: Duration,
    kept_logs: usize,
}

/// Each measurement gets a fresh runtime, so threads an earlier one left idle
/// can't hide the threads this one starts.
fn make_runtime(threads_started: &Arc<AtomicU64>) -> tokio::runtime::Runtime {
    // The runtime napi gives the addon: tokio's defaults, a worker per CPU.
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .on_thread_start({
            let threads_started = threads_started.clone();
            move || {
                allocation_counter::count_this_thread();
                threads_started.fetch_add(1, Ordering::Relaxed);
            }
        })
        .build()
        .unwrap()
}

/// Runs `concurrency` pages at once per iteration; totals are per page, the
/// peak is of all of them together.
fn measure(
    indexer: &Arc<Indexer>,
    scenario: &'static Scenario,
    stage: Stage,
    concurrency: usize,
) -> Measurement {
    let _exclusive = allocation_counter::measure_exclusively();
    let threads_started = Arc::new(AtomicU64::new(0));
    let runtime = make_runtime(&threads_started);
    let run = |concurrency: usize| {
        let tasks: Vec<_> = (0..concurrency)
            .map(|_| {
                let indexer = indexer.clone();
                runtime.spawn(async move { run_stage(&indexer, scenario, stage).await })
            })
            .collect();
        runtime.block_on(async {
            let mut kept = 0;
            for task in tasks {
                kept = task.await.unwrap();
            }
            kept
        })
    };
    // Warm up: connection, cached query id, buffers the client keeps.
    run(1);

    let mut sum = AllocationTotals {
        allocations: 0,
        allocated_bytes: 0,
        peak_live_bytes: 0,
    };
    let threads_before = threads_started.load(Ordering::Relaxed);
    let mut duration = Duration::ZERO;
    let mut kept_logs = 0;
    for _ in 0..ITERATIONS {
        allocation_counter::reset();
        let started = Instant::now();
        kept_logs = run(concurrency);
        duration += started.elapsed();
        let totals = allocation_counter::totals();
        sum.allocations += totals.allocations;
        sum.allocated_bytes += totals.allocated_bytes;
        sum.peak_live_bytes = sum.peak_live_bytes.max(totals.peak_live_bytes);
    }
    let pages = ITERATIONS as u64 * concurrency as u64;
    Measurement {
        totals: AllocationTotals {
            allocations: sum.allocations / pages,
            allocated_bytes: sum.allocated_bytes / pages,
            peak_live_bytes: sum.peak_live_bytes,
        },
        threads_started: threads_started.load(Ordering::Relaxed) - threads_before,
        duration: duration / ITERATIONS,
        kept_logs,
    }
}

const CONCURRENT_PAGES: usize = 16;

fn unpacked_message_bytes(indexer: &Arc<Indexer>) -> usize {
    use capnp::message::ReaderSegments;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    let indexer = indexer.clone();
    let body = runtime
        .block_on(async move { post_query(&indexer).await.bytes().await })
        .unwrap();
    let segments = capnp::serialize_packed::read_message(&body[..], capnp_options())
        .unwrap()
        .into_segments();
    (0..segments.len())
        .map(|index| segments.get_segment(index as u32).unwrap().len())
        .sum()
}

fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_000_000.0)
}

// https://github.com/enviodev/hyperindex/issues/1865
#[test]
fn a_dropped_log_costs_no_allocations() {
    const FEW_DROPPED: Scenario = Scenario {
        name: "1,000 dropped",
        logs: 2_000,
        blocks: 1_000,
        kept_one_in: 2,
        client_filtered: true,
    };
    const MANY_DROPPED: Scenario = Scenario {
        name: "20,000 dropped",
        logs: 21_000,
        blocks: 1_000,
        kept_one_in: 21,
        client_filtered: true,
    };
    let allocations = |scenario: &'static Scenario| {
        let (indexer, _) = make_indexer(scenario);
        let measurement = measure(&Arc::new(indexer), scenario, Stage::GetItems, 1);
        (measurement.kept_logs, measurement.totals.allocations)
    };
    let (few_kept, few_allocations) = allocations(&FEW_DROPPED);
    let (many_kept, many_allocations) = allocations(&MANY_DROPPED);
    let extra_dropped = (MANY_DROPPED.logs - many_kept) - (FEW_DROPPED.logs - few_kept);
    let allocations_per_extra_dropped_log =
        (many_allocations as f64 - few_allocations as f64) / extra_dropped as f64;
    // The same blocks and kept logs on both pages: only the dropped logs
    // differ, so whatever they cost is the difference.
    assert!(
        few_kept == many_kept && allocations_per_extra_dropped_log < 0.01,
        "kept {few_kept} and {many_kept} logs; {allocations_per_extra_dropped_log:.2} allocations \
         per extra dropped log"
    );
}

#[test]
#[ignore = "benchmark: run on its own, in release, with --nocapture"]
fn decode_benchmark() {
    let mut report = vec![format!(
        "build: {}, {} CPUs, {} iterations per row, {} registered addresses",
        if cfg!(debug_assertions) {
            "debug (times not representative)"
        } else {
            "release"
        },
        std::thread::available_parallelism().map_or(0, |count| count.get()),
        ITERATIONS,
        REGISTERED_ADDRESSES
    )];
    for scenario in SCENARIOS {
        let (indexer, body_bytes) = make_indexer(scenario);
        let indexer = Arc::new(indexer);
        report.push(String::new());
        report.push(format!(
            "{}: {} logs, response body {}",
            scenario.name,
            scenario.logs,
            megabytes(body_bytes as u64)
        ));
        report.push(format!(
            "  {:<28} {:>12} {:>10} {:>12} {:>10} {:>11} {:>8} {:>10} {:>9}",
            "stage",
            "allocations",
            "per log",
            "allocated",
            "÷ body",
            "peak held",
            "÷ body",
            "time",
            "threads+"
        ));
        report.push(format!(
            "  unpacked message: {}",
            megabytes(unpacked_message_bytes(&indexer) as u64)
        ));
        for (stage, concurrency) in [
            (Stage::BodyCollected, 1),
            (Stage::BodyUnpacked, 1),
            (Stage::ArrowCopied, 1),
            (Stage::Arrow, 1),
            (Stage::Rows, 1),
            (Stage::Transport, 1),
            (Stage::GetItems, 1),
            (Stage::GetItems, CONCURRENT_PAGES),
        ] {
            let measurement = measure(&indexer, scenario, stage, concurrency);
            let totals = measurement.totals;
            let label = if concurrency == 1 {
                stage.name().to_string()
            } else {
                format!("  {concurrency} pages at once")
            };
            report.push(format!(
                "  {:<28} {:>12} {:>10.1} {:>12} {:>9.1}x {:>11} {:>7.1}x {:>8.1}ms {:>9}",
                label,
                totals.allocations,
                totals.allocations as f64 / scenario.logs as f64,
                megabytes(totals.allocated_bytes),
                totals.allocated_bytes as f64 / body_bytes as f64,
                megabytes(totals.peak_live_bytes),
                totals.peak_live_bytes as f64 / body_bytes as f64,
                measurement.duration.as_secs_f64() * 1000.0,
                measurement.threads_started,
            ));
            if let (Stage::GetItems, 1) = (stage, concurrency) {
                report.push(format!("  kept logs: {}", measurement.kept_logs));
            }
        }
    }
    println!("\n{}\n", report.join("\n"));
}

/// The process's own view of itself: resident memory now and at its peak,
/// and its thread count.
fn process_status() -> (u64, u64, u64) {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let field = |name: &str| {
        status
            .lines()
            .find_map(|line| line.strip_prefix(name))
            .and_then(|rest| rest.split_whitespace().next())
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap()
    };
    (
        field("VmRSS:") * 1024,
        field("VmHWM:") * 1024,
        field("Threads:"),
    )
}

/// What bounding the runtime buys: resident memory, threads and time for many
/// pages at once on a runtime sized for a large host against a bounded one.
/// Resident memory is per process, so each configuration runs on its own:
///
/// ```text
/// RUNTIME=unbounded DECODE=transport ROUNDS=10 cargo test --release --lib runtime_bounding_benchmark -- --ignored --nocapture
/// ```
///
/// `RUNTIME` is `unbounded` (32 workers, tokio's default blocking pool) or
/// `bounded` (4 workers, 4 blocking threads); `DECODE` is `transport`
/// (`get_items`) or `baseline` (hypersync-client's rows).
#[test]
#[ignore = "benchmark: one configuration per process, in release, with --nocapture"]
fn runtime_bounding_benchmark() {
    const PAGES_AT_ONCE: usize = 32;
    let rounds: usize = std::env::var("ROUNDS").map_or(10, |rounds| rounds.parse().unwrap());
    static SCENARIO: Scenario = Scenario {
        name: "client-filtered, 1% kept",
        logs: 100_000,
        blocks: 10_000,
        kept_one_in: 100,
        client_filtered: true,
    };
    let runtime_kind = std::env::var("RUNTIME").unwrap_or_else(|_| "unbounded".to_string());
    let decode = std::env::var("DECODE").unwrap_or_else(|_| "transport".to_string());
    let stage = match decode.as_str() {
        "transport" => Stage::GetItems,
        "baseline" => Stage::Rows,
        other => panic!("unknown DECODE {other}"),
    };
    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.enable_all();
    match runtime_kind.as_str() {
        "unbounded" => builder.worker_threads(32),
        "bounded" => builder.worker_threads(4).max_blocking_threads(4),
        other => panic!("unknown RUNTIME {other}"),
    };
    let runtime = builder.build().unwrap();

    let (indexer, _) = make_indexer(&SCENARIO);
    let indexer = Arc::new(indexer);
    let (rss_before, _, _) = process_status();
    let mut max_threads = 0;
    let started = Instant::now();
    for _ in 0..rounds {
        let tasks: Vec<_> = (0..PAGES_AT_ONCE)
            .map(|_| {
                let indexer = indexer.clone();
                runtime.spawn(async move { run_stage(&indexer, &SCENARIO, stage).await })
            })
            .collect();
        runtime.block_on(async {
            for task in tasks {
                task.await.unwrap();
            }
        });
        max_threads = max_threads.max(process_status().2);
    }
    let elapsed = started.elapsed();
    let (rss_after, rss_peak, _) = process_status();
    println!(
        "\nRUNTIME={runtime_kind} DECODE={decode}: {} pages in {:.2}s, threads up to {max_threads}, \
         RSS {} before, {} after, peak {}\n",
        PAGES_AT_ONCE * rounds,
        elapsed.as_secs_f64(),
        megabytes(rss_before),
        megabytes(rss_after),
        megabytes(rss_peak),
    );
}
