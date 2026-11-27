//! `get_event_items` against a HyperFuel page served over HTTP, encoded the
//! way HyperFuel encodes one.

use std::sync::Arc;

use arrow::array::{ArrayRef, BinaryArray, Int64Array, RecordBatch, UInt64Array, UInt8Array};
use arrow::datatypes::Schema;

use super::config::ClientConfig;
use super::{EventItemsQuery, FuelHyperSyncClient};
use crate::address_store::test_support::{fuel_store, set_of};
use crate::allocation_counter;
use crate::chain_buffer::selection::fuel::{FuelEventKind, FuelOnEventRegistrationInput};
use crate::chain_buffer::{ChainBuffer, ChainBufferConfig, RegistrationsInput};
use crate::sources::testing::mock_hypersync_server::MockHyperSyncServer;

const CONTRACT: [u8; 32] = [0x12; 32];
const BLOCKS: u64 = 100;
const LOG_ID: u64 = 7;

/// An IPC file as HyperFuel writes one: every buffer ZSTD compressed.
fn ipc_file(schema: &Schema, batch: Option<&RecordBatch>) -> Vec<u8> {
    let options = arrow::ipc::writer::IpcWriteOptions::default()
        .try_with_compression(Some(arrow::ipc::CompressionType::ZSTD))
        .unwrap();
    let mut out = Vec::new();
    let mut writer =
        arrow::ipc::writer::FileWriter::try_new_with_options(&mut out, schema, options).unwrap();
    if let Some(batch) = batch {
        writer.write(batch).unwrap();
    }
    writer.finish().unwrap();
    drop(writer);
    out
}

fn table(columns: Vec<(&str, ArrayRef)>) -> Vec<u8> {
    let batch = RecordBatch::try_from_iter(columns).unwrap();
    ipc_file(&batch.schema(), Some(&batch))
}

/// One byte pattern per seed, so ids differ the way real ones do.
fn bytes_of(seed: u64, length: usize) -> Vec<u8> {
    (0..length as u64)
        .map(|position| (seed.wrapping_mul(2654435761).wrapping_add(position * 97) >> 3) as u8)
        .collect()
}

/// LogData receipts spread over the blocks, one in `kept_one_in` emitted by
/// the registered contract.
fn fuel_page(receipts: u64, kept_one_in: u64) -> Vec<u8> {
    let blocks = table(vec![
        (
            "id",
            Arc::new(BinaryArray::from_iter_values(
                (1..=BLOCKS).map(|height| bytes_of(height, 32)),
            )) as ArrayRef,
        ),
        (
            "height",
            Arc::new(UInt64Array::from_iter_values(1..=BLOCKS)) as ArrayRef,
        ),
        (
            "time",
            Arc::new(Int64Array::from_iter_values(
                (1..=BLOCKS as i64).map(|height| 1_700_000_000 + height),
            )) as ArrayRef,
        ),
    ]);
    let emitter = |index: u64| {
        if index.is_multiple_of(kept_one_in) {
            CONTRACT.to_vec()
        } else {
            bytes_of(1 << 40 | index, 32)
        }
    };
    let receipts = table(vec![
        (
            "receipt_index",
            Arc::new(UInt64Array::from_iter_values(0..receipts)) as ArrayRef,
        ),
        (
            "root_contract_id",
            Arc::new(BinaryArray::from_iter_values((0..receipts).map(emitter))) as ArrayRef,
        ),
        (
            "tx_id",
            Arc::new(BinaryArray::from_iter_values(
                (0..receipts).map(|index| bytes_of(2 << 40 | index, 32)),
            )) as ArrayRef,
        ),
        (
            "block_height",
            Arc::new(UInt64Array::from_iter_values(
                (0..receipts).map(|index| 1 + index * BLOCKS / receipts),
            )) as ArrayRef,
        ),
        (
            "receipt_type",
            Arc::new(UInt8Array::from_iter_values((0..receipts).map(|_| 6))) as ArrayRef,
        ),
        (
            "rb",
            Arc::new(UInt64Array::from_iter_values((0..receipts).map(|_| LOG_ID))) as ArrayRef,
        ),
        (
            "data",
            Arc::new(BinaryArray::from_iter_values(
                (0..receipts).map(|index| bytes_of(3 << 40 | index, 8)),
            )) as ArrayRef,
        ),
    ]);
    let empty = ipc_file(&Schema::empty(), None);

    let mut message = capnp::message::Builder::new_default();
    {
        let mut response = message
            .init_root::<hyperfuel_net_types::hyperfuel_net_types_capnp::query_response::Builder>(
        );
        response.set_archive_height(BLOCKS as i64);
        response.set_next_block(BLOCKS + 1);
        let mut data = response.init_data();
        data.set_blocks(&blocks);
        data.set_transactions(&empty);
        data.set_receipts(&receipts);
        data.set_inputs(&empty);
        data.set_outputs(&empty);
    }
    let mut out = Vec::new();
    capnp::serialize_packed::write_message(&mut out, &message).unwrap();
    out
}

struct Fuel {
    client: FuelHyperSyncClient,
    address_set: crate::address_store::AddressSet,
    _server: MockHyperSyncServer,
}

fn serve(receipts: u64, kept_one_in: u64) -> Arc<Fuel> {
    let server = MockHyperSyncServer::new(Some(BLOCKS as i64), None).unwrap();
    server.serve_fixed_body(fuel_page(receipts, kept_one_in));
    let contract = crate::hex::to_hex(&CONTRACT);
    let store = fuel_store(&[("C", &[contract.as_str()])]);
    let registration = FuelOnEventRegistrationInput {
        index: 0,
        event_name: "E0".to_string(),
        contract_name: "C".to_string(),
        is_wildcard: false,
        start_block: None,
        kind: FuelEventKind::LogData,
        log_id: Some(LOG_ID.to_string()),
        abi: Some(crate::ecosystems::fuel::log_decoder::test_abi(
            &LOG_ID.to_string(),
            "u64",
        )),
    };
    let buffer = ChainBuffer::make(
        ChainBufferConfig {
            registrations: RegistrationsInput::Fuel {
                registrations: vec![registration],
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
    let client = FuelHyperSyncClient::new(
        ClientConfig {
            url: server.url(),
            api_token: "00000000-0000-0000-0000-000000000000".to_string(),
            http_req_timeout_millis: 10_000,
        },
        "test".to_string(),
        &buffer,
    )
    .unwrap();
    Arc::new(Fuel {
        client,
        address_set: set_of(&store, &["C"]),
        _server: server,
    })
}

async fn kept_receipts(fuel: Arc<Fuel>) -> usize {
    let (_, page) = fuel
        .client
        .get_event_items(
            EventItemsQuery {
                from_block: 1,
                to_block: Some(BLOCKS as i64),
                registration_indexes: vec![0],
                client_filtered_contracts: Some(vec!["C".to_string()]),
            },
            &fuel.address_set,
        )
        .await
        .unwrap();
    page.take().events.len()
}

// https://github.com/enviodev/hyperindex/issues/1865
#[test]
fn a_dropped_receipt_costs_no_allocations() {
    let allocations = |receipts: u64, kept_one_in: u64| {
        let fuel = serve(receipts, kept_one_in);
        let kept = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(kept_receipts(fuel.clone()));
        let totals = allocation_counter::allocations_of(|| kept_receipts(fuel.clone()));
        (kept, totals.allocations)
    };
    // The same blocks and kept receipts on both pages: only the dropped ones
    // differ, so whatever they cost is the difference.
    let (few_kept, few_allocations) = allocations(2_000, 2);
    let (many_kept, many_allocations) = allocations(21_000, 21);
    let extra_dropped = (21_000 - many_kept) - (2_000 - few_kept);
    let allocations_per_extra_dropped_receipt =
        (many_allocations as f64 - few_allocations as f64) / extra_dropped as f64;
    assert!(
        few_kept == many_kept && allocations_per_extra_dropped_receipt < 0.01,
        "kept {few_kept} and {many_kept} receipts; {allocations_per_extra_dropped_receipt:.2} \
         allocations per extra dropped receipt"
    );
}

/// The live server read through this client: a page of LogData receipts and
/// their blocks.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "live: needs ENVIO_API_TOKEN and network access to fuel.hypersync.xyz"]
async fn live_page_reads_receipts_and_blocks() {
    let store = fuel_store(&[("C", &[])]);
    let buffer = ChainBuffer::make(
        ChainBufferConfig {
            registrations: RegistrationsInput::Fuel {
                registrations: vec![],
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
    let client = FuelHyperSyncClient::new(
        ClientConfig {
            url: "https://fuel.hypersync.xyz".to_string(),
            api_token: std::env::var("ENVIO_API_TOKEN").unwrap(),
            http_req_timeout_millis: 30_000,
        },
        "hyperindex-live-test".to_string(),
        &buffer,
    )
    .unwrap();
    let query: hyperfuel_net_types::Query = serde_json::from_value(serde_json::json!({
        "from_block": 10_000_000,
        "to_block": 10_010_000,
        "receipts": [{"receipt_type": [6]}],
        "field_selection": {
            "block": ["id", "height", "time"],
            "receipt": ["receipt_index", "receipt_type", "root_contract_id", "tx_id",
                        "block_height", "data", "rb"],
        },
    }))
    .unwrap();
    let response = client.query(&query).await.unwrap();
    let rows = |batches: &[RecordBatch]| batches.iter().map(RecordBatch::num_rows).sum::<usize>();
    let (blocks, receipts) = (rows(&response.blocks), rows(&response.receipts));
    let first_receipt = super::types::ReceiptColumns::of(&response.receipts[0])
        .unwrap()
        .row(0)
        .map(|receipt| (receipt.receipt_type, receipt.tx_id.len()))
        .unwrap();
    assert!(
        blocks > 0 && receipts > 0 && first_receipt == (6, 32),
        "{blocks} blocks, {receipts} receipts, first receipt {first_receipt:?}"
    );
}
