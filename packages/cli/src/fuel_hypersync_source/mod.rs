use std::collections::HashSet;

use anyhow::Context;
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;

mod config;
mod selection;
mod types;

use crate::address_store::{AddressSet, AddressStore, SetCache, StoreInner};
use config::ClientConfig;
use hyperfuel_client::format::{Hash, Hex};
use hyperfuel_client::net_types;
use selection::{
    BuiltSelection, FuelOnEventRegistrationInput, ReceiptAddress, RegistrationKind,
    SelectionBuilder,
};
use types::{convert_response, Block, ConvertError, RawReceipt};

#[napi]
pub struct FuelHyperSyncClient {
    inner: hyperfuel_client::Client,
    selection_builder: SelectionBuilder,
    /// The chain's address index, shared with the fetch state. Read by the
    /// per-receipt owner gate.
    address_store: std::sync::Arc<std::sync::RwLock<StoreInner>>,
}

#[napi]
impl FuelHyperSyncClient {
    #[napi(factory)]
    pub fn new(
        cfg: ClientConfig,
        user_agent: String,
        event_registrations: Vec<FuelOnEventRegistrationInput>,
        address_store: &AddressStore,
    ) -> napi::Result<FuelHyperSyncClient> {
        let handle = address_store.handle();
        let selection_builder = {
            let store = handle.read().unwrap();
            SelectionBuilder::from_registrations(&event_registrations, &store)
                .context("build selection builder")
                .map_err(map_err)?
        };
        let client_config: hyperfuel_client::ClientConfig =
            cfg.try_into().context("build config").map_err(map_err)?;
        let inner = hyperfuel_client::Client::new_with_agent(client_config, user_agent)
            .context("build client")
            .map_err(map_err)?;
        Ok(FuelHyperSyncClient {
            inner,
            selection_builder,
            address_store: handle,
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
    ) -> napi::Result<EventItemsResponse> {
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

        // Materialise the set's cache before taking the store guard: `cache()`
        // lazily initialises by reading the same lock, and a writer queued
        // between the two reads would deadlock the pair.
        let set_cache = address_set.cache().clone();
        let items = {
            let store = self.address_store.read().unwrap();
            route_receipts(
                raw.receipts,
                &raw.blocks,
                &built,
                &set_cache,
                &client_filtered,
                &store,
            )
            .map_err(convert_error_to_napi)?
        };

        Ok(EventItemsResponse {
            archive_height: raw.archive_height,
            next_block: raw.next_block,
            blocks: raw.blocks,
            items,
        })
    }
}

/// The whole per-query input for `get_event_items`: the block range and the
/// partition's registration selection (by index). The partition's addresses
/// arrive separately, as the `AddressSet` handle. Receipt selections, field
/// selection, and routing are all derived internally from the registrations
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

/// One routed receipt. The receipt's kind-specific columns are flattened so
/// JS builds params without a tagged receipt union: LogData carries `data`
/// (decoded in JS against the contract ABI), Mint/Burn carry `val`/`subId`,
/// Transfer/TransferOut/Call carry `amount`/`assetId`/`to` — with
/// TransferOut's wallet recipient normalised into `to`.
#[napi(object)]
pub struct EventItem {
    /// The registration this receipt routed to, as passed to the client
    /// constructor. Receipts that route nowhere never cross the boundary.
    pub on_event_registration_index: i64,
    pub receipt_index: i64,
    pub tx_id: String,
    /// Height of the block this receipt belongs to. The block itself is
    /// carried once, deduplicated, in `EventItemsResponse.blocks`.
    pub block_height: i64,
    pub src_address: String,
    pub data: Option<String>,
    pub sub_id: Option<String>,
    pub val: Option<BigInt>,
    pub amount: Option<BigInt>,
    pub asset_id: Option<String>,
    pub to: Option<String>,
}

#[napi(object)]
pub struct EventItemsResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    /// The page's blocks, one per height. Items reference them by
    /// `block_height`; presence for every routed item is validated here.
    pub blocks: Vec<Block>,
    pub items: Vec<EventItem>,
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

/// Fans each receipt out to every registration of the selection it matches
/// and flattens the kind-specific columns onto the items. A receipt without a
/// `root_contract_id` (no contract context for `srcAddress`) is dropped, as is
/// one that routes to no registration. Kind-required columns the source
/// omitted surface as `MissingFields` — never as garbage params.
fn route_receipts(
    receipts: Vec<RawReceipt>,
    blocks: &[Block],
    built: &BuiltSelection,
    set_cache: &SetCache,
    client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
    address_store: &StoreInner,
) -> Result<Vec<EventItem>, ConvertError> {
    let present_block_heights: HashSet<i64> = blocks.iter().map(|b| b.height).collect();
    let mut items = Vec::with_capacity(receipts.len());
    let mut missing: Vec<String> = Vec::new();

    for receipt in receipts {
        let src_address = match &receipt.root_contract_id {
            Some(address) => address.clone(),
            None => continue,
        };
        // A malformed root contract id can't be any registered address, so the
        // receipt only reaches wildcard registrations.
        let contract_id = Hash::decode_hex(&src_address).ok();
        let key: &[u8] = contract_id.as_deref().map_or(&[], |bytes| &bytes[..]);
        let address = ReceiptAddress {
            key,
            contract_name: set_cache.owner_of(key),
            block_height: receipt.block_height,
        };

        for reg in &built.registrations {
            if !reg.matches(
                receipt.receipt_type,
                receipt.rb,
                &address,
                client_filtered.applies(&reg.contract_name),
                address_store,
            ) {
                continue;
            }
            // Every routed item's block must resolve — JS reads it
            // unconditionally onto the payload.
            if !present_block_heights.contains(&receipt.block_height) {
                push_unique(&mut missing, "block");
            }
            let require_hex = |value: &Option<String>, name: &str, missing: &mut Vec<String>| {
                if value.is_none() {
                    push_unique(missing, name);
                }
                value.clone()
            };
            let require_u64 = |value: Option<u64>, name: &str, missing: &mut Vec<String>| {
                if value.is_none() {
                    push_unique(missing, name);
                }
                value.map(BigInt::from)
            };
            let item = match reg.kind {
                RegistrationKind::LogData { .. } => EventItem {
                    on_event_registration_index: reg.index,
                    receipt_index: receipt.receipt_index,
                    tx_id: receipt.tx_id.clone(),
                    block_height: receipt.block_height,
                    src_address: src_address.clone(),
                    data: require_hex(&receipt.data, "receipt.data", &mut missing),
                    sub_id: None,
                    val: None,
                    amount: None,
                    asset_id: None,
                    to: None,
                },
                RegistrationKind::Mint | RegistrationKind::Burn => EventItem {
                    on_event_registration_index: reg.index,
                    receipt_index: receipt.receipt_index,
                    tx_id: receipt.tx_id.clone(),
                    block_height: receipt.block_height,
                    src_address: src_address.clone(),
                    data: None,
                    sub_id: require_hex(&receipt.sub_id, "receipt.subId", &mut missing),
                    val: require_u64(receipt.val, "receipt.val", &mut missing),
                    amount: None,
                    asset_id: None,
                    to: None,
                },
                RegistrationKind::Transfer | RegistrationKind::Call => {
                    // TransferOut receipts carry the wallet recipient in
                    // `to_address`; everything else uses `to`.
                    let (recipient, recipient_name) =
                        if receipt.receipt_type == selection::RECEIPT_TRANSFER_OUT {
                            (&receipt.to_address, "receipt.toAddress")
                        } else {
                            (&receipt.to, "receipt.to")
                        };
                    EventItem {
                        on_event_registration_index: reg.index,
                        receipt_index: receipt.receipt_index,
                        tx_id: receipt.tx_id.clone(),
                        block_height: receipt.block_height,
                        src_address: src_address.clone(),
                        data: None,
                        sub_id: None,
                        val: None,
                        amount: require_u64(receipt.amount, "receipt.amount", &mut missing),
                        asset_id: require_hex(&receipt.asset_id, "receipt.assetId", &mut missing),
                        to: require_hex(recipient, recipient_name, &mut missing),
                    }
                }
            };
            items.push(item);
        }
    }

    if !missing.is_empty() {
        return Err(ConvertError::MissingFields(missing));
    }
    Ok(items)
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
    use crate::address_store::test_support::{fuel_store, set_of};

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
        }
    }

    fn raw_receipt(receipt_type: u8) -> RawReceipt {
        RawReceipt {
            receipt_index: 3,
            root_contract_id: Some(ADDR.to_string()),
            tx_id: "0xtx".to_string(),
            block_height: 42,
            receipt_type,
            data: Some("0x01".to_string()),
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
            id: "0xblock".to_string(),
            height: 42,
            time: 1745179292,
        }
    }

    /// Builds a selection and keeps its store and set alive — routing reads
    /// both. `addresses` must cover every contract the registrations name.
    fn build(
        registrations: &[FuelOnEventRegistrationInput],
        indexes: &[i64],
        addresses: &[(&str, &[&str])],
    ) -> (AddressStore, AddressSet, BuiltSelection) {
        let store = fuel_store(addresses);
        let names: Vec<&str> = addresses.iter().map(|(name, _)| *name).collect();
        let set = set_of(&store, &names);
        let built =
            SelectionBuilder::from_registrations(registrations, &store.handle().read().unwrap())
                .unwrap()
                .build(indexes, &set, &Default::default())
                .unwrap();
        (store, set, built)
    }

    fn route(
        store: &AddressStore,
        set: &AddressSet,
        built: &BuiltSelection,
        receipts: Vec<RawReceipt>,
    ) -> Result<Vec<EventItem>, ConvertError> {
        let address_store = store.handle();
        let address_store = address_store.read().unwrap();
        route_receipts(
            receipts,
            &[block_42()],
            built,
            set.cache(),
            &Default::default(),
            &address_store,
        )
    }

    #[test]
    fn routes_transfer_out_recipient_into_to() {
        let (store, set, built) = build(
            &[reg_input(0, "C", FuelEventKind::Transfer, true, None)],
            &[0],
            &[("C", &[])],
        );
        let items = route(&store, &set, &built, vec![raw_receipt(8)]).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| (i.on_event_registration_index, i.to.as_deref()))
                .collect::<Vec<_>>(),
            vec![(0, Some("0xwallet"))]
        );
    }

    #[test]
    fn fans_out_to_wildcard_and_owned_registration() {
        let (store, set, built) = build(
            &[
                reg_input(0, "Owned", FuelEventKind::Mint, false, None),
                reg_input(1, "W", FuelEventKind::Mint, true, None),
            ],
            &[0, 1],
            &[("Owned", &[ADDR]), ("W", &[])],
        );
        let items = route(&store, &set, &built, vec![raw_receipt(11)]).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| i.on_event_registration_index)
                .collect::<Vec<_>>(),
            vec![0, 1]
        );
    }

    #[test]
    fn unrouted_receipt_is_dropped() {
        let (store, set, built) = build(
            &[reg_input(0, "C", FuelEventKind::LogData, true, Some("9"))],
            &[0],
            &[("C", &[])],
        );
        // rb 7 doesn't match the registration's logId 9.
        let items = route(&store, &set, &built, vec![raw_receipt(6)]).unwrap();
        assert!(items.is_empty());
    }

    #[test]
    fn missing_kind_required_column_is_typed_error() {
        let (store, set, built) = build(
            &[reg_input(0, "C", FuelEventKind::Mint, true, None)],
            &[0],
            &[("C", &[])],
        );
        let mut receipt = raw_receipt(11);
        receipt.val = None;
        match route(&store, &set, &built, vec![receipt]) {
            Err(ConvertError::MissingFields(fields)) => {
                assert_eq!(fields, vec!["receipt.val".to_string()])
            }
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }

    #[test]
    fn missing_block_for_routed_receipt_is_typed_error() {
        let (store, set, built) = build(
            &[reg_input(0, "C", FuelEventKind::Mint, true, None)],
            &[0],
            &[("C", &[])],
        );
        let address_store = store.handle();
        let address_store = address_store.read().unwrap();
        match route_receipts(
            vec![raw_receipt(11)],
            &[],
            &built,
            set.cache(),
            &Default::default(),
            &address_store,
        ) {
            Err(ConvertError::MissingFields(fields)) => {
                assert_eq!(fields, vec!["block".to_string()])
            }
            Err(ConvertError::Other(e)) => panic!("unexpected ConvertError::Other: {e:?}"),
            Ok(_) => panic!("expected MissingFields, got Ok"),
        }
    }
}
