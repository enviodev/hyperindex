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
const LOGS_PER_BLOCK: usize = 10;
const REGISTERED_ADDRESSES: usize = 10_000;
const ITERATIONS: u32 = 5;

struct Scenario {
    name: &'static str,
    logs: usize,
    /// One log in this many comes from a registered address; the rest are
    /// what a wildcard query returns for client-side filtering to drop.
    kept_one_in: usize,
    client_filtered: bool,
}

const SCENARIOS: &[Scenario] = &[
    Scenario {
        name: "client-filtered, 1% kept",
        logs: 100_000,
        kept_one_in: 100,
        client_filtered: true,
    },
    Scenario {
        name: "server-filtered, all kept",
        logs: 100_000,
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

fn transfer_page(scenario: &Scenario) -> Value {
    let block_count = scenario.logs.div_ceil(LOGS_PER_BLOCK);
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
                "block_number": FIRST_BLOCK + (index / LOGS_PER_BLOCK) as u64,
                "log_index": index % LOGS_PER_BLOCK,
                "transaction_index": index % LOGS_PER_BLOCK,
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
    (
        Indexer {
            client,
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
    /// The HTTP body read, unpacked and parsed into Arrow record batches.
    Arrow,
    /// The Arrow batches converted to `simple_types` rows.
    Rows,
    /// The whole of `get_items`: rows matched and the kept ones copied into
    /// the page's columns.
    GetItems,
    /// What `Arrow` does inside hypersync-client, one copy at a time: the body
    /// collected into one buffer,
    BodyCollected,
    /// then unpacked from Cap'n Proto's packed encoding,
    BodyUnpacked,
    /// then each table read by Arrow's `FileReader`, which copies its buffers.
    ArrowCopied,
    /// Prototype: the body unpacked as its chunks arrive, never held whole,
    StreamedUnpack,
    /// then Arrow's arrays laid over the unpacked message without copying.
    StreamedZeroCopyArrow,
}

impl Stage {
    fn name(self) -> &'static str {
        match self {
            Stage::Arrow => "fetch + arrow",
            Stage::Rows => "+ simple_types rows",
            Stage::GetItems => "+ match + page (get_items)",
            Stage::BodyCollected => "body collected",
            Stage::BodyUnpacked => "+ capnp unpacked",
            Stage::ArrowCopied => "+ arrow FileReader",
            Stage::StreamedUnpack => "streamed unpack",
            Stage::StreamedZeroCopyArrow => "+ zero-copy arrow",
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

fn read_file_zero_copy(file: &arrow::buffer::Buffer) -> Vec<arrow::array::RecordBatch> {
    let trailer_start = file.len() - 10;
    let footer_length =
        arrow::ipc::reader::read_footer_length(file[trailer_start..].try_into().unwrap()).unwrap();
    let footer =
        arrow::ipc::root_as_footer(&file[trailer_start - footer_length..trailer_start]).unwrap();
    let schema = Arc::new(arrow::ipc::convert::fb_to_schema(footer.schema().unwrap()));
    let decoder = arrow::ipc::reader::FileDecoder::new(schema, footer.version());
    footer
        .recordBatches()
        .unwrap()
        .iter()
        .filter_map(|block| {
            let length = block.bodyLength() as usize + block.metaDataLength() as usize;
            decoder
                .read_record_batch(
                    block,
                    &file.slice_with_length(block.offset() as usize, length),
                )
                .unwrap()
        })
        .collect()
}

fn log_rows(batches: &[arrow::array::RecordBatch]) -> usize {
    batches.iter().map(|batch| batch.num_rows()).sum()
}

/// A blocking reader over the chunks of a response body as they arrive, each
/// dropped once read.
struct ChunkReader {
    current: bytes::Bytes,
    chunks: tokio::sync::mpsc::Receiver<bytes::Bytes>,
}

impl std::io::Read for ChunkReader {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        use std::io::BufRead;
        let available = self.fill_buf()?;
        let length = available.len().min(out.len());
        out[..length].copy_from_slice(&available[..length]);
        self.consume(length);
        Ok(length)
    }
}

impl std::io::BufRead for ChunkReader {
    fn fill_buf(&mut self) -> std::io::Result<&[u8]> {
        while self.current.is_empty() {
            match self.chunks.blocking_recv() {
                Some(chunk) => self.current = chunk,
                None => break,
            }
        }
        Ok(&self.current)
    }

    fn consume(&mut self, length: usize) {
        bytes::Buf::advance(&mut self.current, length);
    }
}

/// Unpacks the body while it downloads: the packed body is never held whole,
/// only the unpacked message, in one allocation.
async fn read_message_streamed(
    indexer: &Indexer,
) -> capnp::message::Reader<capnp::serialize::OwnedSegments> {
    let mut response = post_query(indexer).await;
    let (sender, chunks) = tokio::sync::mpsc::channel(4);
    let unpack = tokio::task::spawn_blocking(move || {
        let reader = ChunkReader {
            current: bytes::Bytes::new(),
            chunks,
        };
        capnp::serialize_packed::read_message(reader, capnp_options()).unwrap()
    });
    while let Some(chunk) = response.chunk().await.unwrap() {
        sender.send(chunk).await.unwrap();
    }
    drop(sender);
    unpack.await.unwrap()
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
                .client
                .inner
                .get_arrow_with_rate_limit(&raw_query)
                .await
                .unwrap();
            drop(response);
            0
        }
        Stage::Rows => {
            let response = indexer
                .client
                .inner
                .get_with_rate_limit(&raw_query)
                .await
                .unwrap();
            drop(response);
            0
        }
        Stage::GetItems => {
            let block_count = scenario.logs.div_ceil(LOGS_PER_BLOCK) as i64;
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
        Stage::StreamedUnpack => {
            let message = read_message_streamed(indexer).await;
            table_files(&message);
            0
        }
        Stage::StreamedZeroCopyArrow => {
            let message = read_message_streamed(indexer).await;
            let files = table_files(&message).map(|file| (file.as_ptr() as usize, file.len()));
            // The table files stay where they are when the reader gives up
            // its segments: those own the one allocation they point into.
            let segments: Arc<capnp::serialize::OwnedSegments> = Arc::new(message.into_segments());
            let [blocks, transactions, logs] = files.map(|(pointer, length)| {
                let file = unsafe {
                    arrow::buffer::Buffer::from_custom_allocation(
                        std::ptr::NonNull::new(pointer as *mut u8).unwrap(),
                        length,
                        segments.clone(),
                    )
                };
                read_file_zero_copy(&file)
            });
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
    let segments = runtime
        .block_on(async move { read_message_streamed(&indexer).await })
        .into_segments();
    (0..segments.len())
        .map(|index| segments.get_segment(index as u32).unwrap().len())
        .sum()
}

fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_000_000.0)
}

#[test]
#[ignore = "benchmark: run on its own, in release, with --nocapture"]
fn decode_benchmark() {
    let mut report = vec![format!(
        "build: {}, {} CPUs, {} iterations per row, {} logs per block, {} registered addresses",
        if cfg!(debug_assertions) {
            "debug (times not representative)"
        } else {
            "release"
        },
        std::thread::available_parallelism().map_or(0, |count| count.get()),
        ITERATIONS,
        LOGS_PER_BLOCK,
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
            (Stage::StreamedUnpack, 1),
            (Stage::StreamedZeroCopyArrow, 1),
            (Stage::Arrow, 1),
            (Stage::Rows, 1),
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
