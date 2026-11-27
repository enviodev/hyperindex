use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use arrow::array::RecordBatch;
use hyperfuel_net_types::hyperfuel_net_types_capnp::query_response;
use napi_derive::napi;
use reqwest::Method;

mod config;
pub(crate) mod selection;
#[cfg(test)]
mod served_page_tests;
mod types;

use crate::address_store::{AddressSet, StoreInner};
use crate::chain_buffer::fuel::{push_block, push_receipt, ReceiptInput};
use crate::chain_buffer::matching_fuel::{FuelMatcher, ReceiptMatchFields};
use crate::chain_buffer::page::{Page, PageData};
use crate::chain_buffer::{ChainBuffer, Ecosystem, FuelRegistrations};
use crate::hypersync_http::{
    classify_reply, locate_file, read_files_in_message, read_packed_message, HttpClient,
    HttpVersion, Reply,
};
use crate::request_stats::rate_limited_err;
use config::ClientConfig;
use hyperfuel_net_types as net_types;
use selection::{BuiltSelection, RegistrationKind};
use types::{push_unique, required, BlockColumns, ConvertError, ReceiptColumns, ReceiptRow};

const HTTP_REQ_TIMEOUT: Duration = Duration::from_secs(30);

#[napi]
pub struct FuelHyperSyncClient {
    http: HttpClient,
    fuel: Arc<FuelRegistrations>,
}

/// One HyperFuel page: the tables a page is built from.
struct FuelResponse {
    archive_height: Option<i64>,
    next_block: i64,
    blocks: Vec<RecordBatch>,
    receipts: Vec<RecordBatch>,
}

impl FuelHyperSyncClient {
    async fn query(&self, query: &net_types::Query) -> napi::Result<FuelResponse> {
        let fail = |e: anyhow::Error| request_err("Failed to get data from HyperFuel", e);
        let response = self
            .http
            .request(Method::POST, &["query", "arrow-ipc"])
            .map_err(fail)?
            .json(query)
            .send()
            .await
            .context("execute http req")
            .map_err(fail)?;
        match classify_reply(response).await.map_err(fail)? {
            Reply::Success(response) => {
                let message = read_packed_message(response, reader_options())
                    .await
                    .map_err(fail)?;
                decode_response(message).map_err(fail)
            }
            // A rate limit without a reset header still has to back off, or
            // the source would spin straight back into the closed window.
            Reply::RateLimited(info) => Err(rate_limited_err(
                info.suggested_wait_secs().unwrap_or(1) * 1000,
            )),
            Reply::PayloadTooLarge => Err(fail(anyhow::anyhow!(
                "http response status code 413 Payload Too Large"
            ))),
        }
    }
}

/// Bounded for untrusted network input: the traversal cap, 512 MiB, fits
/// large paginated payloads. A query hitting it should cover fewer blocks.
fn reader_options() -> capnp::message::ReaderOptions {
    let mut options = capnp::message::ReaderOptions::new();
    options
        .nesting_limit(64)
        .traversal_limit_in_words(Some(64 * 1024 * 1024));
    options
}

fn decode_response(
    message: capnp::message::Reader<capnp::serialize::OwnedSegments>,
) -> anyhow::Result<FuelResponse> {
    let (archive_height, next_block, blocks, receipts) = {
        let response = message
            .get_root::<query_response::Reader>()
            .context("get root")?;
        let archive_height = match response.get_archive_height() {
            -1 => None,
            height => Some(height),
        };
        let data = response.get_data().context("read data")?;
        (
            archive_height,
            i64::try_from(response.get_next_block()).context("convert next_block")?,
            locate_file(data.get_blocks().context("get block data")?),
            locate_file(data.get_receipts().context("get receipt data")?),
        )
    };
    let [blocks, receipts] = read_files_in_message(
        message.into_segments(),
        [(blocks, "block"), (receipts, "receipt")],
    )?;
    Ok(FuelResponse {
        archive_height,
        next_block,
        blocks,
        receipts,
    })
}

#[napi]
impl FuelHyperSyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        buffer: &ChainBuffer,
    ) -> napi::Result<FuelHyperSyncClient> {
        let fuel = buffer.shared().fuel().map_err(map_err)?;
        let http = HttpClient::new(
            &cfg.url,
            Some(cfg.api_token),
            user_agent,
            HttpVersion::Http2,
            HTTP_REQ_TIMEOUT,
        )
        .context("build client")
        .map_err(map_err)?;
        Ok(FuelHyperSyncClient { http, fuel })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let fail = |e: anyhow::Error| request_err("Failed to get HyperFuel height", e);
        let height: net_types::ArchiveHeight = self
            .http
            .get(&["height"])
            .await
            .map_err(fail)?
            .json()
            .await
            .context("read response body json")
            .map_err(fail)?;
        i64::try_from(height.height.unwrap_or(0))
            .context("convert height")
            .map_err(map_err)
    }

    #[napi]
    pub async fn get_event_items(
        &self,
        params: EventItemsQuery,
        address_set: &AddressSet,
    ) -> napi::Result<(EventItemsResponse, Page)> {
        let client_filtered = crate::client_filtered_contracts::ClientFilteredContracts::from_vec(
            params.client_filtered_contracts.clone().unwrap_or_default(),
        );
        let built = self
            .fuel
            .selection
            .build(&params.registration_indexes, address_set, &client_filtered)
            .map_err(map_err)?;

        let query = build_query(&params, &built)
            .context("build query")
            .map_err(map_err)?;
        let response = self.query(&query).await?;
        let page = {
            let matcher = &self.fuel.matcher;
            let store = matcher.read_store();
            build_page(&response.receipts, &response.blocks, matcher, &store)
        }
        .map_err(convert_error_to_napi)?;

        let items = EventItemsResponse {
            archive_height: response.archive_height,
            next_block: response.next_block,
        };
        Ok((items, Page::from_data(page)))
    }
}

/// The whole per-query input for `get_event_items`: the block range and the
/// partition's registration selection (by index). The partition's addresses
/// arrive separately, as the `AddressSet` handle. Receipt selections, field
/// selection, and matching are all derived internally from the registrations
/// passed at construction.
#[napi(object)]
pub struct EventItemsQuery {
    pub from_block: i64,
    /// Inclusive; `None` queries to the end of available data.
    pub to_block: Option<i64>,
    pub registration_indexes: Vec<i64>,
    /// Contract names to fetch address-free even though their registrations
    /// depend on addresses (client-side filtering). Absent or empty means every
    /// address-dependent contract is filtered server-side.
    pub client_filtered_contracts: Option<Vec<String>>,
}

/// What a page covered. Its rows are in the `Page` returned beside it.
#[napi(object, object_from_js = false)]
pub struct EventItemsResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
}

fn build_query(
    params: &EventItemsQuery,
    built: &BuiltSelection,
) -> anyhow::Result<net_types::Query> {
    let from_block = u64::try_from(params.from_block).context("from_block must be >= 0")?;
    let to_block = params
        .to_block
        // Inclusive on the boundary, exclusive on the wire.
        .map(|b| {
            u64::try_from(b)
                .context("to_block must be >= 0")?
                .checked_add(1)
                .context("to_block overflow")
        })
        .transpose()?;

    let mut receipt_fields = vec![
        "receipt_index",
        "receipt_type",
        "root_contract_id",
        "tx_id",
        "block_height",
    ];
    if built.needs_log_data {
        receipt_fields.extend(["data", "rb"]);
    }
    if built.needs_supply {
        receipt_fields.extend(["val", "sub_id"]);
    }
    if built.needs_transfer || built.needs_call {
        receipt_fields.extend(["amount", "asset_id", "to"]);
    }
    if built.needs_transfer {
        receipt_fields.push("to_address");
    }

    Ok(net_types::Query {
        from_block,
        to_block,
        receipts: built.receipt_selections.clone(),
        field_selection: net_types::FieldSelection {
            block: ["id", "height", "time"].map(str::to_string).into(),
            receipt: receipt_fields.into_iter().map(str::to_string).collect(),
            ..Default::default()
        },
        ..Default::default()
    })
}

/// Names every column a registration of `kind` reads that the receipt lacks.
fn check_required(kind: &RegistrationKind, receipt: &ReceiptRow, missing: &mut Vec<String>) {
    match kind {
        RegistrationKind::LogData { .. } => {
            required(receipt.data, "receipt.data", missing);
        }
        RegistrationKind::Mint | RegistrationKind::Burn => {
            required(receipt.sub_id, "receipt.subId", missing);
            required(receipt.val, "receipt.val", missing);
        }
        RegistrationKind::Transfer | RegistrationKind::Call => {
            // TransferOut receipts carry the wallet recipient in
            // `to_address`; everything else uses `to`.
            let (recipient, recipient_name) =
                if receipt.receipt_type == selection::RECEIPT_TRANSFER_OUT {
                    (receipt.to_address, "receipt.toAddress")
                } else {
                    (receipt.to, "receipt.to")
                };
            required(receipt.amount, "receipt.amount", missing);
            required(receipt.asset_id, "receipt.assetId", missing);
            required(recipient, recipient_name, missing);
        }
    }
}

/// The hex text the store keeps for a kept receipt's ids, one buffer per field
/// reused across receipts.
#[derive(Default)]
struct ReceiptHex {
    tx_id: String,
    sub_id: String,
    asset_id: String,
    to: String,
    to_address: String,
}

fn write_optional_hex<'a>(out: &'a mut String, bytes: Option<&[u8]>) -> Option<&'a str> {
    bytes.map(|bytes| {
        crate::hex::write_hex(out, bytes);
        out.as_str()
    })
}

/// The page: every block of the response, for reorg detection and the
/// receipts' block fields, and the receipts some registration matches now,
/// matched where they sit in the response so a dropped one costs nothing. A
/// receipt without a `root_contract_id` has no emitter and is dropped.
/// Kind-required columns the source omitted for a matching registration
/// surface as `MissingFields`, as does a kept receipt's missing block.
fn build_page(
    receipts: &[RecordBatch],
    blocks: &[RecordBatch],
    matcher: &FuelMatcher,
    store: &StoreInner,
) -> Result<PageData, ConvertError> {
    let mut page = PageData::new(Ecosystem::Fuel);
    let mut heights = Vec::new();
    let mut rows = page.blocks.builder();
    for batch in blocks {
        let columns = BlockColumns::of(batch)?;
        for row in 0..batch.num_rows() {
            let block = columns.row(row)?;
            heights.push(block.height);
            push_block(&mut rows, block.height, Some(block.id), Some(block.time));
        }
    }
    page.add_blocks(rows.finish());
    heights.sort_unstable();

    let mut missing: Vec<String> = Vec::new();
    let mut registering_blocks = Vec::new();
    let mut hex = ReceiptHex::default();
    let mut rows = page.events.builder();
    for batch in receipts {
        let columns = ReceiptColumns::of(batch)?;
        for row in 0..batch.num_rows() {
            let receipt = columns.row(row)?;
            let Some(root_contract_id) = receipt.root_contract_id else {
                continue;
            };
            if root_contract_id.len() != 32 {
                return Err(ConvertError::Other(anyhow::anyhow!(
                    "receipt.rootContractId must be 32 bytes, got {}",
                    root_contract_id.len()
                )));
            }
            let fields = ReceiptMatchFields {
                receipt_type: receipt.receipt_type,
                rb: receipt.rb,
                root_contract_id,
                block_height: receipt.block_height,
            };
            let mut kept = false;
            let mut registers = false;
            matcher.for_each_match_of_fields(&fields, store, |registration| {
                kept = true;
                registers |= matcher.contract_registers.has(registration.index());
                check_required(&registration.registration.kind, &receipt, &mut missing);
            });
            if !kept {
                continue;
            }
            // Every kept receipt's block must resolve: JS reads it onto the
            // payload unconditionally.
            if heights.binary_search(&receipt.block_height).is_err() {
                push_unique(&mut missing, "block");
            }
            if registers {
                registering_blocks.push(receipt.block_height);
            }
            crate::hex::write_hex(&mut hex.tx_id, receipt.tx_id);
            push_receipt(
                &mut rows,
                &ReceiptInput {
                    block_height: receipt.block_height,
                    receipt_index: receipt.receipt_index,
                    receipt_type: receipt.receipt_type,
                    root_contract_id,
                    tx_id: &hex.tx_id,
                    rb: receipt.rb,
                    data: receipt.data,
                    val: receipt.val,
                    sub_id: write_optional_hex(&mut hex.sub_id, receipt.sub_id),
                    amount: receipt.amount,
                    asset_id: write_optional_hex(&mut hex.asset_id, receipt.asset_id),
                    to: write_optional_hex(&mut hex.to, receipt.to),
                    to_address: write_optional_hex(&mut hex.to_address, receipt.to_address),
                },
            )?;
        }
    }
    if !missing.is_empty() {
        return Err(ConvertError::MissingFields(missing));
    }
    page.add_events(rows.finish());
    page.add_registering_blocks(registering_blocks);
    Ok(page)
}

/// Only the first line, so the error stays readable when the indexer surfaces
/// it on retries.
fn request_err(prefix: &str, e: anyhow::Error) -> napi::Error {
    let message = format!("{e}");
    let summary = message.lines().next().unwrap_or(message.as_str());
    napi::Error::from_reason(format!("{prefix}: {summary}"))
}

/// Encodes `ConvertError::MissingFields` as a JSON payload in the napi
/// error's message — the same protocol as hypersync_source, which the
/// ReScript side recovers via JSON.parse and a `kind` dispatch.
fn convert_error_to_napi(err: ConvertError) -> napi::Error {
    match err {
        ConvertError::MissingFields(fields) => {
            let payload = serde_json::json!({
                "kind": "MissingFields",
                "fields": fields,
            })
            .to_string();
            napi::Error::new(napi::Status::InvalidArg, payload)
        }
        ConvertError::Other(e) => map_err(e),
    }
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

#[cfg(test)]
mod tests {
    use super::selection::FuelEventKind;
    use super::*;
    use crate::address_store::test_support::fuel_store;
    use crate::address_store::AddressStore;
    use crate::chain_buffer::fuel::ReceiptView;
    use crate::chain_buffer::matching::ContractRegisters;
    use crate::js_value::test_value::JsValue;
    use selection::FuelOnEventRegistrationInput;

    #[test]
    fn convert_error_serializes_as_expected_json() {
        let err =
            ConvertError::MissingFields(vec!["receipt.txId".to_string(), "block.time".to_string()]);
        let napi_err = convert_error_to_napi(err);
        let parsed: serde_json::Value =
            serde_json::from_str(&napi_err.reason).expect("payload must be JSON");
        assert_eq!(parsed["kind"], "MissingFields");
        assert_eq!(parsed["fields"][0], "receipt.txId");
        assert_eq!(parsed["fields"][1], "block.time");
    }

    const ADDR: &str = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcde1";

    fn reg_input(
        index: i64,
        contract_name: &str,
        kind: FuelEventKind,
        is_wildcard: bool,
        log_id: Option<&str>,
    ) -> FuelOnEventRegistrationInput {
        FuelOnEventRegistrationInput {
            index,
            event_name: format!("E{index}"),
            contract_name: contract_name.to_string(),
            is_wildcard,
            start_block: None,
            kind,
            log_id: log_id.map(str::to_string),
            abi: log_id.map(|id| crate::fuel::log_decoder::test_abi(id, "u8")),
        }
    }

    /// A receipt as a test writes one: ids in the hex the store keeps.
    struct RawReceipt {
        receipt_index: u64,
        root_contract_id: Option<String>,
        tx_id: String,
        block_height: u64,
        receipt_type: u8,
        data: Option<Vec<u8>>,
        rb: Option<u64>,
        val: Option<u64>,
        sub_id: Option<String>,
        amount: Option<u64>,
        asset_id: Option<String>,
        to: Option<String>,
        to_address: Option<String>,
    }

    struct Block {
        id: String,
        height: u64,
        time: i64,
    }

    fn raw_receipt(receipt_type: u8) -> RawReceipt {
        RawReceipt {
            receipt_index: 3,
            root_contract_id: Some(ADDR.to_string()),
            tx_id: "0x0a".to_string(),
            block_height: 42,
            receipt_type,
            data: Some(vec![0x01]),
            rb: Some(7),
            val: Some(100),
            sub_id: Some("0x5b".to_string()),
            amount: Some(5),
            asset_id: Some("0xa5".to_string()),
            to: Some("0x70".to_string()),
            to_address: Some("0x77".to_string()),
        }
    }

    fn block_42() -> Block {
        Block {
            id: "0xb10c".to_string(),
            height: 42,
            time: 1745179292,
        }
    }

    fn hex_bytes(text: &Option<String>) -> Option<Vec<u8>> {
        text.as_deref()
            .map(|text| crate::hex::decode_prefixed(text, "fixture").unwrap())
    }

    /// The tables the server would send for `receipts` and `blocks`.
    fn tables(receipts: &[RawReceipt], blocks: &[Block]) -> (RecordBatch, RecordBatch) {
        use arrow::array::{ArrayRef, BinaryArray, Int64Array, UInt64Array, UInt8Array};
        let binary = |values: Vec<Option<Vec<u8>>>| -> ArrayRef {
            std::sync::Arc::new(BinaryArray::from_iter(values))
        };
        let u64s = |values: Vec<Option<u64>>| -> ArrayRef {
            std::sync::Arc::new(UInt64Array::from(values))
        };
        let receipts = RecordBatch::try_from_iter([
            (
                "receipt_index",
                u64s(receipts.iter().map(|r| Some(r.receipt_index)).collect()),
            ),
            (
                "root_contract_id",
                binary(
                    receipts
                        .iter()
                        .map(|r| hex_bytes(&r.root_contract_id))
                        .collect(),
                ),
            ),
            (
                "tx_id",
                binary(
                    receipts
                        .iter()
                        .map(|r| hex_bytes(&Some(r.tx_id.clone())))
                        .collect(),
                ),
            ),
            (
                "block_height",
                u64s(receipts.iter().map(|r| Some(r.block_height)).collect()),
            ),
            (
                "receipt_type",
                std::sync::Arc::new(UInt8Array::from_iter_values(
                    receipts.iter().map(|r| r.receipt_type),
                )) as ArrayRef,
            ),
            (
                "data",
                binary(receipts.iter().map(|r| r.data.clone()).collect()),
            ),
            ("rb", u64s(receipts.iter().map(|r| r.rb).collect())),
            ("val", u64s(receipts.iter().map(|r| r.val).collect())),
            (
                "sub_id",
                binary(receipts.iter().map(|r| hex_bytes(&r.sub_id)).collect()),
            ),
            ("amount", u64s(receipts.iter().map(|r| r.amount).collect())),
            (
                "asset_id",
                binary(receipts.iter().map(|r| hex_bytes(&r.asset_id)).collect()),
            ),
            (
                "to",
                binary(receipts.iter().map(|r| hex_bytes(&r.to)).collect()),
            ),
            (
                "to_address",
                binary(receipts.iter().map(|r| hex_bytes(&r.to_address)).collect()),
            ),
        ])
        .unwrap();
        let blocks = RecordBatch::try_from_iter([
            (
                "id",
                binary(
                    blocks
                        .iter()
                        .map(|b| hex_bytes(&Some(b.id.clone())))
                        .collect(),
                ),
            ),
            (
                "height",
                u64s(blocks.iter().map(|b| Some(b.height)).collect()),
            ),
            (
                "time",
                std::sync::Arc::new(Int64Array::from_iter_values(blocks.iter().map(|b| b.time)))
                    as ArrayRef,
            ),
        ])
        .unwrap();
        (receipts, blocks)
    }

    /// `build_page` over rows written as a test writes them, laid out as the
    /// tables the server would send.
    fn build_rows(
        receipts: &[RawReceipt],
        blocks: &[Block],
        matcher: &FuelMatcher,
        store: &StoreInner,
    ) -> Result<PageData, ConvertError> {
        let (receipts, blocks) = tables(receipts, blocks);
        build_page(&[receipts], &[blocks], matcher, store)
    }

    /// The matcher over `registrations`, with the store it reads.
    fn build(
        registrations: &[FuelOnEventRegistrationInput],
        addresses: &[(&str, &[&str])],
    ) -> (AddressStore, FuelMatcher) {
        let store = fuel_store(addresses);
        let matcher = FuelMatcher::new(
            registrations,
            ContractRegisters::from_indexes(&[0]).unwrap(),
            &store,
        )
        .unwrap();
        (store, matcher)
    }

    struct Matched {
        on_event_registration_index: i64,
        params: crate::js_value::JsTape,
    }

    /// The page's receipts as a build reads them: each kept receipt matched
    /// and decoded under every registration it belongs to.
    fn route(
        matcher: &FuelMatcher,
        receipts: Vec<RawReceipt>,
    ) -> Result<Vec<Matched>, ConvertError> {
        let store = matcher.read_store();
        let page = build_rows(&receipts, &[block_42()], matcher, &store)?;
        let mut items = Vec::new();
        for row in page.events.rows_in_block_range(0, 1 << 30) {
            let view = ReceiptView::of_row(&row).unwrap();
            matcher.for_each_match(&view, &store, |registration| {
                if let Some(params) = crate::chain_buffer::decode::fuel::params(
                    &registration.registration.kind,
                    &view,
                ) {
                    items.push(Matched {
                        on_event_registration_index: registration.registration.index,
                        params,
                    });
                }
            });
        }
        Ok(items)
    }

    #[test]
    fn routes_transfer_out_recipient_into_to() {
        let (_store, matcher) = build(
            &[reg_input(0, "C", FuelEventKind::Transfer, true, None)],
            &[("C", &[])],
        );
        let items = route(&matcher, vec![raw_receipt(8)]).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| (i.on_event_registration_index, JsValue::of(&i.params)))
                .collect::<Vec<_>>(),
            vec![(
                0,
                JsValue::obj([
                    ("to", JsValue::str("0x77")),
                    ("assetId", JsValue::str("0xa5")),
                    ("amount", JsValue::uint(5u64)),
                ])
            )]
        );
    }

    #[test]
    fn builds_supply_params_from_mint_receipt() {
        let (_store, matcher) = build(
            &[reg_input(0, "C", FuelEventKind::Mint, true, None)],
            &[("C", &[])],
        );
        let items = route(&matcher, vec![raw_receipt(11)]).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| (i.on_event_registration_index, JsValue::of(&i.params)))
                .collect::<Vec<_>>(),
            vec![(
                0,
                JsValue::obj([
                    ("subId", JsValue::str("0x5b")),
                    ("amount", JsValue::uint(100u64)),
                ])
            )]
        );
    }

    #[test]
    fn fans_out_to_wildcard_and_owned_registration() {
        let (_store, matcher) = build(
            &[
                reg_input(0, "Owned", FuelEventKind::Mint, false, None),
                reg_input(1, "W", FuelEventKind::Mint, true, None),
            ],
            &[("Owned", &[ADDR]), ("W", &[])],
        );
        let items = route(&matcher, vec![raw_receipt(11)]).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| i.on_event_registration_index)
                .collect::<Vec<_>>(),
            vec![0, 1]
        );
    }

    #[test]
    fn log_data_its_abi_rejects_drops_only_that_registration() {
        let mut logs_u64 = reg_input(1, "C", FuelEventKind::LogData, true, Some("7"));
        logs_u64.abi = Some(crate::fuel::log_decoder::test_abi("7", "u64"));
        let (_store, matcher) = build(
            &[
                reg_input(0, "C", FuelEventKind::LogData, true, Some("7")),
                logs_u64,
            ],
            &[("C", &[])],
        );
        // One data byte: a u8 for registration 0, too short for 1's u64.
        let mut empty = raw_receipt(6);
        empty.data = Some(Vec::new());
        let items = route(&matcher, vec![raw_receipt(6), empty]).unwrap();
        assert_eq!(
            items
                .into_iter()
                .map(|i| (i.on_event_registration_index, JsValue::of(&i.params)))
                .collect::<Vec<_>>(),
            vec![(0, JsValue::Num(1.0))]
        );
    }

    #[test]
    fn a_page_keeps_matched_receipts_once_and_names_the_blocks_a_contract_register_runs_on() {
        // Registration 0 has a contractRegister (see `build`); 1 doesn't.
        let (_store, matcher) = build(
            &[
                reg_input(0, "C", FuelEventKind::Mint, true, None),
                reg_input(1, "C", FuelEventKind::Mint, true, None),
                reg_input(2, "C", FuelEventKind::Burn, true, None),
            ],
            &[("C", &[])],
        );
        let store = matcher.read_store();
        let mut burn = raw_receipt(12);
        burn.receipt_index = 4;
        let mut transfer = raw_receipt(7);
        transfer.receipt_index = 5;
        let page = build_rows(
            &[raw_receipt(11), burn, transfer],
            &[block_42()],
            &matcher,
            &store,
        )
        .unwrap();
        assert_eq!(
            (page.events.len(), page.registering_blocks.clone()),
            (2, vec![42])
        );
    }

    #[test]
    fn unmatched_receipt_is_dropped() {
        let (_store, matcher) = build(
            &[reg_input(0, "C", FuelEventKind::LogData, true, Some("9"))],
            &[("C", &[])],
        );
        // rb 7 doesn't match the registration's logId 9.
        let items = route(&matcher, vec![raw_receipt(6)]).unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn missing_kind_required_column_is_typed_error() {
        let (_store, matcher) = build(
            &[reg_input(0, "C", FuelEventKind::Mint, true, None)],
            &[("C", &[])],
        );
        let mut receipt = raw_receipt(11);
        receipt.val = None;
        match route(&matcher, vec![receipt]) {
            Err(ConvertError::MissingFields(fields)) => {
                assert_eq!(fields, vec!["receipt.val".to_string()])
            }
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }

    #[test]
    fn missing_transfer_columns_are_all_named_in_one_error() {
        let (_store, matcher) = build(
            &[reg_input(0, "C", FuelEventKind::Transfer, true, None)],
            &[("C", &[])],
        );
        let mut receipt = raw_receipt(7);
        receipt.amount = None;
        receipt.asset_id = None;
        receipt.to = None;
        match route(&matcher, vec![receipt]) {
            Err(ConvertError::MissingFields(fields)) => assert_eq!(
                fields,
                vec![
                    "receipt.amount".to_string(),
                    "receipt.assetId".to_string(),
                    "receipt.to".to_string(),
                ]
            ),
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }

    #[test]
    fn missing_block_for_routed_receipt_is_typed_error() {
        let (_store, matcher) = build(
            &[reg_input(0, "C", FuelEventKind::Mint, true, None)],
            &[("C", &[])],
        );
        let store = matcher.read_store();
        match build_rows(&[raw_receipt(11)], &[], &matcher, &store) {
            Err(ConvertError::MissingFields(fields)) => {
                assert_eq!(fields, vec!["block".to_string()])
            }
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }
}
