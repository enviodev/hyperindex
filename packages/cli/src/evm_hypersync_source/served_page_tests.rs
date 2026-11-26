//! `get_items` against pages a local HyperSync server serves over real HTTP,
//! the client running with the indexer's defaults: Cap'n Proto, query caching
//! on. The benchmark at the end reports what a page costs; run it in release:
//!
//! ```text
//! cargo test --release --lib served_page_benchmark -- --ignored --nocapture --test-threads=1
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
    let blocks: Vec<Value> = (0..scenario.blocks as u64)
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
            let address = if index.is_multiple_of(scenario.kept_one_in) {
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
        "nextBlock": FIRST_BLOCK + scenario.blocks as u64,
        "archiveHeight": FIRST_BLOCK + scenario.blocks as u64,
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
    buffer: ChainBuffer,
    address_set: AddressSet,
    server: MockHyperSyncServer,
}

/// A client indexing Transfers of the registered addresses from `server`.
fn indexer_of(server: MockHyperSyncServer) -> Indexer {
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
            serialization_format: Some(SerializationFormat::CapnProto),
            enable_query_caching: Some(true),
            ..Default::default()
        },
        "test".to_string(),
        &buffer,
    )
    .unwrap();
    Indexer {
        client,
        buffer,
        address_set: set_of(&store, &["Token"]),
        server,
    }
}

/// An indexer whose server answers every query with `scenario`'s page, and
/// that page's encoded size.
fn serve_scenario(scenario: &Scenario) -> (Arc<Indexer>, usize) {
    let server = MockHyperSyncServer::new(Some(0), None).unwrap();
    let body_bytes = server.serve_fixed_page(&transfer_page(scenario)).unwrap();
    (Arc::new(indexer_of(server)), body_bytes)
}

fn items_query(scenario: &Scenario) -> ItemsQuery {
    ItemsQuery {
        from_block: FIRST_BLOCK as i64,
        to_block: Some((FIRST_BLOCK + scenario.blocks as u64) as i64 - 1),
        on_event_registration_indexes: vec![0],
        on_block_registration_indexes: vec![],
        on_transaction_registration_indexes: vec![],
        client_filtered_contracts: scenario.client_filtered.then(|| vec!["Token".to_string()]),
        reorgable_from: None,
    }
}

#[derive(Clone, Copy)]
enum Stage {
    /// The response read into Arrow record batches.
    Transport,
    /// The whole of `get_items`: logs matched on the columns and the kept rows
    /// copied into the page.
    GetItems,
}

/// Runs one page through `stage`, returning the logs the page kept.
async fn run_stage(indexer: &Indexer, scenario: &Scenario, stage: Stage) -> usize {
    match stage {
        Stage::Transport => {
            let query = hypersync_client::net_types::Query {
                from_block: FIRST_BLOCK,
                ..Default::default()
            };
            match indexer.client.transport.query(&query).await.unwrap() {
                super::transport::QueryOutcome::Response(_) => 0,
                super::transport::QueryOutcome::RateLimited(_) => panic!("rate limited"),
            }
        }
        Stage::GetItems => {
            let (_, page) = indexer
                .client
                .get_items(items_query(scenario), &indexer.address_set, &indexer.buffer)
                .await
                .unwrap();
            page.take().events.len()
        }
    }
}

struct Measurement {
    totals: AllocationTotals,
    threads_started: u64,
    duration: Duration,
    kept_logs: usize,
}

/// Runs `concurrency` pages at once per iteration, on a fresh runtime so
/// threads an earlier measurement left idle can't hide the ones this one
/// starts. Totals are per page; the peak is of all of them together.
fn measure(
    indexer: &Arc<Indexer>,
    scenario: &'static Scenario,
    stage: Stage,
    concurrency: usize,
) -> Measurement {
    let _exclusive = allocation_counter::measure_exclusively();
    let threads_started = Arc::new(AtomicU64::new(0));
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .on_thread_start({
            let threads_started = threads_started.clone();
            move || {
                allocation_counter::count_this_thread();
                threads_started.fetch_add(1, Ordering::Relaxed);
            }
        })
        .build()
        .unwrap();
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
        let (indexer, _) = serve_scenario(scenario);
        let measurement = measure(&indexer, scenario, Stage::GetItems, 1);
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

// https://github.com/enviodev/hyperindex/issues/1865
#[test]
fn pages_in_flight_start_no_threads() {
    const SCENARIO: Scenario = Scenario {
        name: "1% kept",
        logs: 2_000,
        blocks: 100,
        kept_one_in: 100,
        client_filtered: true,
    };
    let (indexer, _) = serve_scenario(&SCENARIO);
    let measurement = measure(&indexer, &SCENARIO, Stage::GetItems, 16);
    assert_eq!(measurement.threads_started, 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_cached_query_falls_back_to_the_full_query() {
    const SCENARIO: Scenario = Scenario {
        name: "one block",
        logs: 1,
        blocks: 1,
        kept_one_in: 1,
        client_filtered: false,
    };
    let server = MockHyperSyncServer::new(Some(FIRST_BLOCK as i64 + 1), None).unwrap();
    // The first query isn't cached yet, so it's uploaded and answered by the
    // first page. The second goes by its id, which the server fails.
    server
        .push_response(transfer_page(&SCENARIO).to_string())
        .unwrap();
    server
        .push_response(json!({"status": 500, "body": "cache unavailable"}).to_string())
        .unwrap();
    server
        .push_response(transfer_page(&SCENARIO).to_string())
        .unwrap();
    let indexer = indexer_of(server);
    let mut kept = Vec::new();
    for _ in 0..2 {
        let (_, page) = indexer
            .client
            .get_items(
                items_query(&SCENARIO),
                &indexer.address_set,
                &indexer.buffer,
            )
            .await
            .unwrap();
        kept.push(page.take().events.len());
    }
    assert_eq!((kept, indexer.server.take_uploads().len()), (vec![1, 1], 2));
}

fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_000_000.0)
}

#[test]
#[ignore = "benchmark: run on its own, in release, with --nocapture"]
fn served_page_benchmark() {
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
    const CONCURRENT_PAGES: usize = 16;
    let mut report = vec![format!(
        "build: {}, {} CPUs, {} iterations per row",
        if cfg!(debug_assertions) {
            "debug (times not representative)"
        } else {
            "release"
        },
        std::thread::available_parallelism().map_or(0, |count| count.get()),
        ITERATIONS,
    )];
    for scenario in SCENARIOS {
        let (indexer, body_bytes) = serve_scenario(scenario);
        report.push(format!(
            "\n{}: {} logs, response body {}",
            scenario.name,
            scenario.logs,
            megabytes(body_bytes as u64)
        ));
        report.push(format!(
            "  {:<20} {:>12} {:>12} {:>11} {:>10} {:>9} {:>6}",
            "stage", "allocations", "allocated", "peak held", "time", "threads+", "kept"
        ));
        for (label, stage, concurrency) in [
            ("transport", Stage::Transport, 1),
            ("get_items", Stage::GetItems, 1),
            ("get_items x16", Stage::GetItems, CONCURRENT_PAGES),
        ] {
            let measurement = measure(&indexer, scenario, stage, concurrency);
            report.push(format!(
                "  {:<20} {:>12} {:>12} {:>11} {:>8.1}ms {:>9} {:>6}",
                label,
                measurement.totals.allocations,
                megabytes(measurement.totals.allocated_bytes),
                megabytes(measurement.totals.peak_live_bytes),
                measurement.duration.as_secs_f64() * 1000.0,
                measurement.threads_started,
                measurement.kept_logs,
            ));
        }
    }
    println!("\n{}\n", report.join("\n"));
}
