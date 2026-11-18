use anyhow::Context;
use napi_derive::napi;

mod config;
pub(crate) mod selection;
mod types;

use crate::address_store::{AddressSet, AddressStore, StoreInner};
use crate::chain_buffer::fuel::{push_block, push_receipt, ReceiptInput, ReceiptView};
use crate::chain_buffer::matching_fuel::FuelMatcher;
use crate::chain_buffer::page::{Page, PageData};
use crate::chain_buffer::Ecosystem;
use crate::hex::decode_prefixed;
use config::ClientConfig;
use hyperfuel_client::format::{Hash, Hex};
use hyperfuel_client::net_types;
use selection::{BuiltSelection, FuelOnEventRegistrationInput, RegistrationKind, SelectionBuilder};
use types::{convert_response, Block, ConvertError, RawReceipt};

#[napi]
pub struct FuelHyperSyncClient {
    inner: hyperfuel_client::Client,
    selection_builder: SelectionBuilder,
    matcher: FuelMatcher,
}

#[napi]
impl FuelHyperSyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_registrations: Vec<FuelOnEventRegistrationInput>,
        contract_register_indexes: Vec<i64>,
        address_store: &AddressStore,
    ) -> napi::Result<FuelHyperSyncClient> {
        let selection_builder = {
            let handle = address_store.handle();
            let store = handle.read().unwrap();
            SelectionBuilder::from_registrations(&event_registrations, &store)
                .context("build selection builder")
                .map_err(map_err)?
        };
        let matcher = FuelMatcher::new(
            &event_registrations,
            &contract_register_indexes,
            address_store,
        )
        .context("build matcher")
        .map_err(map_err)?;
        let client_config: hyperfuel_client::ClientConfig =
            cfg.try_into().context("build config").map_err(map_err)?;
        let inner = hyperfuel_client::Client::new_with_agent(client_config, user_agent)
            .context("build client")
            .map_err(map_err)?;
        Ok(FuelHyperSyncClient {
            inner,
            selection_builder,
            matcher,
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let height = self
            .inner
            .get_height()
            .await
            .map_err(|e| request_err("Failed to get HyperFuel height", e))?;
        height.try_into().context("convert height").map_err(map_err)
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
            .selection_builder
            .build(&params.registration_indexes, address_set, &client_filtered)
            .map_err(map_err)?;

        let query = build_query(&params, &built)
            .context("build query")
            .map_err(map_err)?;
        let res = self
            .inner
            .get_arrow(&query)
            .await
            .map_err(|e| request_err("Failed to get data from HyperFuel", e))?;
        let raw = convert_response(res).map_err(convert_error_to_napi)?;
        let page = tokio::task::block_in_place(|| {
            let store = self.matcher.read_store();
            build_page(&raw.receipts, &raw.blocks, &self.matcher, &store)
        })
        .map_err(convert_error_to_napi)?;

        let response = EventItemsResponse {
            archive_height: raw.archive_height,
            next_block: raw.next_block,
        };
        Ok((response, Page::from_data(page)))
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

fn push_unique(missing: &mut Vec<String>, name: &str) {
    if !missing.iter().any(|m| m == name) {
        missing.push(name.to_string());
    }
}

fn required<T>(value: Option<T>, name: &str, missing: &mut Vec<String>) -> Option<T> {
    if value.is_none() {
        push_unique(missing, name);
    }
    value
}

fn receipt_view<'a>(receipt: &'a RawReceipt, root_contract_id: &'a [u8]) -> ReceiptView<'a> {
    ReceiptView {
        block_height: receipt.block_height as u64,
        receipt_index: receipt.receipt_index as u64,
        receipt_type: receipt.receipt_type,
        root_contract_id,
        tx_id: receipt.tx_id.as_bytes(),
        rb: receipt.rb,
        data: receipt.data.as_deref(),
        val: receipt.val,
        sub_id: receipt.sub_id.as_deref().map(str::as_bytes),
        amount: receipt.amount,
        asset_id: receipt.asset_id.as_deref().map(str::as_bytes),
        to: receipt.to.as_deref().map(str::as_bytes),
        to_address: receipt.to_address.as_deref().map(str::as_bytes),
    }
}

/// Names every column a registration of `kind` reads that the receipt lacks.
fn check_required(kind: &RegistrationKind, receipt: &RawReceipt, missing: &mut Vec<String>) {
    match kind {
        RegistrationKind::LogData { .. } => {
            required(receipt.data.as_ref(), "receipt.data", missing);
        }
        RegistrationKind::Mint | RegistrationKind::Burn => {
            required(receipt.sub_id.as_ref(), "receipt.subId", missing);
            required(receipt.val, "receipt.val", missing);
        }
        RegistrationKind::Transfer | RegistrationKind::Call => {
            // TransferOut receipts carry the wallet recipient in
            // `to_address`; everything else uses `to`.
            let (recipient, recipient_name) =
                if receipt.receipt_type == selection::RECEIPT_TRANSFER_OUT {
                    (&receipt.to_address, "receipt.toAddress")
                } else {
                    (&receipt.to, "receipt.to")
                };
            required(receipt.amount, "receipt.amount", missing);
            required(receipt.asset_id.as_ref(), "receipt.assetId", missing);
            required(recipient.as_ref(), recipient_name, missing);
        }
    }
}

/// The page: every block of the response, for reorg detection and the
/// receipts' block fields, and the receipts some registration matches now.
/// A receipt without a `root_contract_id` has no emitter and is dropped.
/// Kind-required columns the source omitted for a matching registration
/// surface as `MissingFields`, as does a kept receipt's missing block.
fn build_page(
    receipts: &[RawReceipt],
    blocks: &[Block],
    matcher: &FuelMatcher,
    store: &StoreInner,
) -> Result<PageData, ConvertError> {
    let mut page = PageData::new(Ecosystem::Fuel);
    let heights: std::collections::HashSet<i64> = blocks.iter().map(|block| block.height).collect();
    let mut rows = page.blocks.builder();
    for block in blocks {
        let height = u64::try_from(block.height).context("block.height negative")?;
        let id = decode_prefixed(&block.id, "block.id")?;
        push_block(&mut rows, height, Some(&id), Some(block.time));
    }
    page.add_blocks(rows.finish());

    let mut missing: Vec<String> = Vec::new();
    let mut registering_blocks = Vec::new();
    let mut rows = page.events.builder();
    for receipt in receipts {
        let Some(root_contract_id) = &receipt.root_contract_id else {
            continue;
        };
        let root_contract_id = Hash::decode_hex(root_contract_id)
            .with_context(|| format!("receipt.rootContractId {root_contract_id}"))?;
        let view = receipt_view(receipt, &root_contract_id[..]);
        let mut kept = false;
        let mut registers = false;
        matcher.for_each_match(&view, store, |registration| {
            kept = true;
            registers |= registration.has_contract_register;
            check_required(&registration.registration.kind, receipt, &mut missing);
        });
        if !kept {
            continue;
        }
        // Every kept receipt's block must resolve: JS reads it onto the
        // payload unconditionally.
        if !heights.contains(&receipt.block_height) {
            push_unique(&mut missing, "block");
        }
        if registers {
            registering_blocks.push(view.block_height);
        }
        push_receipt(
            &mut rows,
            &ReceiptInput {
                block_height: view.block_height,
                receipt_index: view.receipt_index,
                receipt_type: receipt.receipt_type,
                root_contract_id: &root_contract_id[..],
                tx_id: &receipt.tx_id,
                rb: receipt.rb,
                data: receipt.data.as_deref(),
                val: receipt.val,
                sub_id: receipt.sub_id.as_deref(),
                amount: receipt.amount,
                asset_id: receipt.asset_id.as_deref(),
                to: receipt.to.as_deref(),
                to_address: receipt.to_address.as_deref(),
            },
        )?;
    }
    if !missing.is_empty() {
        return Err(ConvertError::MissingFields(missing));
    }
    page.add_events(rows.finish());
    page.add_registering_blocks(registering_blocks);
    Ok(page)
}

/// The client embeds a `{:?}` debug dump in its error message; keep only the
/// first line so it stays readable when the indexer surfaces it on retries.
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
    use crate::js_value::test_value::JsValue;

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

    fn raw_receipt(receipt_type: u8) -> RawReceipt {
        RawReceipt {
            receipt_index: 3,
            root_contract_id: Some(ADDR.to_string()),
            tx_id: "0xtx".to_string(),
            block_height: 42,
            receipt_type,
            data: Some(vec![0x01]),
            rb: Some(7),
            val: Some(100),
            sub_id: Some("0xsub".to_string()),
            amount: Some(5),
            asset_id: Some("0xasset".to_string()),
            to: Some("0xto".to_string()),
            to_address: Some("0xwallet".to_string()),
        }
    }

    fn block_42() -> Block {
        Block {
            id: "0xb10c".to_string(),
            height: 42,
            time: 1745179292,
        }
    }

    /// The matcher over `registrations`, with the store it reads.
    fn build(
        registrations: &[FuelOnEventRegistrationInput],
        addresses: &[(&str, &[&str])],
    ) -> (AddressStore, FuelMatcher) {
        let store = fuel_store(addresses);
        let matcher = FuelMatcher::new(registrations, &[0], &store).unwrap();
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
        let page = build_page(&receipts, &[block_42()], matcher, &store)?;
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
                    ("to", JsValue::str("0xwallet")),
                    ("assetId", JsValue::str("0xasset")),
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
                    ("subId", JsValue::str("0xsub")),
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
        let page = build_page(
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
        match build_page(&[raw_receipt(11)], &[], &matcher, &store) {
            Err(ConvertError::MissingFields(fields)) => {
                assert_eq!(fields, vec!["block".to_string()])
            }
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }
}
