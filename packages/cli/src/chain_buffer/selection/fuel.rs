use std::collections::HashMap;

use anyhow::{anyhow, Context, Result};
use hyperfuel_client::format::{Hash, Hex};
use hyperfuel_client::net_types;
use napi_derive::napi;

use crate::address_store::{AddressSet, StoreInner};
use crate::ecosystems::fuel::log_decoder::{parse_abi, LogDecoder};
use crate::registration_start_block::has_started;
use fuel_abi_types::abi::unified_program::UnifiedProgramABI;

// FuelVM receipt type codes.
const RECEIPT_CALL: u8 = 0;
const RECEIPT_LOG_DATA: u8 = 6;
const RECEIPT_TRANSFER: u8 = 7;
pub(crate) const RECEIPT_TRANSFER_OUT: u8 = 8;
const RECEIPT_MINT: u8 = 11;
const RECEIPT_BURN: u8 = 12;

// Only receipts from successful transactions are indexed.
const TX_STATUS_SUCCESS: u8 = 1;

/// Receipt kind of a registration, mirroring `Internal.fuelEventKind`.
/// `Transfer` covers both `Transfer` (to a contract) and `TransferOut`
/// (to a wallet address) receipts.
#[napi(string_enum)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum FuelEventKind {
    LogData,
    Mint,
    Burn,
    Transfer,
    Call,
}

/// Internal per-registration kind. Unlike the `FuelEventKind` boundary enum,
/// the `LogData` variant carries its parsed `rb` and decoder, so a LogData
/// registration can't exist without them and no other kind can carry a stray
/// one — the invalid states the napi input's `kind`+`log_id`+`abi` fields
/// could express are resolved once, at construction.
pub(crate) enum RegistrationKind {
    LogData { rb: u64, decoder: LogDecoder },
    Mint,
    Burn,
    Transfer,
    Call,
}

impl RegistrationKind {
    fn receipt_types(&self) -> &'static [u8] {
        match self {
            RegistrationKind::LogData { .. } => &[RECEIPT_LOG_DATA],
            RegistrationKind::Mint => &[RECEIPT_MINT],
            RegistrationKind::Burn => &[RECEIPT_BURN],
            RegistrationKind::Transfer => &[RECEIPT_TRANSFER, RECEIPT_TRANSFER_OUT],
            RegistrationKind::Call => &[RECEIPT_CALL],
        }
    }
}

/// The full per-(event, chain) registration crossing the boundary once at
/// client construction: matching identity plus the receipt-selection state
/// queries are built from.
#[napi(object)]
pub struct FuelOnEventRegistrationInput {
    /// Chain-scoped sequential registration index; returned on every matched
    /// item so JS resolves the registration by array index.
    pub index: i64,
    pub event_name: String,
    pub contract_name: String,
    pub is_wildcard: bool,
    /// Earliest block height this registration accepts; absent is unrestricted.
    /// See `crate::registration_start_block`.
    pub start_block: Option<i64>,
    pub kind: FuelEventKind,
    /// The LogData `rb` value as a decimal string (u64). Required for
    /// `LogData`, ignored otherwise.
    pub log_id: Option<String>,
    /// The contract's Fuel ABI JSON, which LogData `data` is decoded against.
    /// Required for `LogData`, ignored otherwise.
    pub abi: Option<serde_json::Value>,
}

pub(crate) struct Registration {
    pub index: i64,
    pub contract_name: String,
    /// This registration's contract in the chain's address store, resolved once
    /// at construction so the per-receipt gate is an index compare.
    pub contract_idx: u32,
    pub is_wildcard: bool,
    /// Earliest block height this registration accepts; `None` is unrestricted.
    pub start_block: Option<i64>,
    pub kind: RegistrationKind,
}

impl Registration {
    /// Whether a receipt belongs to this registration: matching receipt type
    /// (and `rb` for LogData), at or after the registration's own start block,
    /// and either wildcard or emitted by a contract the store holds for the
    /// registration's contract at the receipt's block.
    pub(crate) fn matches(
        &self,
        receipt_type: u8,
        rb: Option<u64>,
        emitter: &[u8],
        block: i64,
        store: &StoreInner,
    ) -> bool {
        let kind_matches = match &self.kind {
            RegistrationKind::LogData { rb: reg_rb, .. } => {
                receipt_type == RECEIPT_LOG_DATA && rb == Some(*reg_rb)
            }
            kind => kind.receipt_types().contains(&receipt_type),
        };
        kind_matches
            && has_started(self.start_block, block)
            && (self.is_wildcard || store.is_indexed_at(emitter, self.contract_idx, block))
    }
}

/// Parses every registration once: its kind, with the LogData decoder built
/// from the contract's ABI, and its contract in the address store.
pub(crate) fn parse_registrations(
    registrations: &[FuelOnEventRegistrationInput],
    store: &StoreInner,
) -> Result<Vec<Registration>> {
    // Every LogData registration carries its contract's whole ABI; parse each
    // distinct one once.
    let mut programs: Vec<(&serde_json::Value, UnifiedProgramABI)> = Vec::new();
    let mut parsed: Vec<Registration> = Vec::with_capacity(registrations.len());
    for reg in registrations {
        let kind = match reg.kind {
            FuelEventKind::LogData => {
                let log_id = reg.log_id.as_ref().with_context(|| {
                    format!("LogData registration {} is missing logId", reg.event_name)
                })?;
                let rb = log_id.parse::<u64>().with_context(|| {
                    format!("parse logId {} for event {}", log_id, reg.event_name)
                })?;
                let abi = reg.abi.as_ref().with_context(|| {
                    format!("LogData registration {} is missing abi", reg.event_name)
                })?;
                let program_idx = match programs.iter().position(|(seen, _)| *seen == abi) {
                    Some(idx) => idx,
                    None => {
                        let program = parse_abi(abi).with_context(|| {
                            format!("parse the ABI of contract {}", reg.contract_name)
                        })?;
                        programs.push((abi, program));
                        programs.len() - 1
                    }
                };
                let decoder =
                    LogDecoder::new(&programs[program_idx].1, log_id).with_context(|| {
                        format!("build the LogData decoder for event {}", reg.event_name)
                    })?;
                RegistrationKind::LogData { rb, decoder }
            }
            FuelEventKind::Call => {
                anyhow::ensure!(
                    reg.is_wildcard,
                    "Call receipt indexing currently supported only in wildcard mode"
                );
                RegistrationKind::Call
            }
            FuelEventKind::Mint => RegistrationKind::Mint,
            FuelEventKind::Burn => RegistrationKind::Burn,
            FuelEventKind::Transfer => RegistrationKind::Transfer,
        };
        let contract_idx = store.contract_idx(&reg.contract_name).with_context(|| {
            format!(
                "Contract {} is missing from the chain's address store",
                reg.contract_name
            )
        })?;
        anyhow::ensure!(
            parsed.iter().all(|seen| seen.index != reg.index),
            "Duplicate registration index {} for event {}",
            reg.index,
            reg.event_name,
        );
        parsed.push(Registration {
            index: reg.index,
            contract_name: reg.contract_name.clone(),
            contract_idx,
            is_wildcard: reg.is_wildcard,
            start_block: reg.start_block,
            kind,
        });
    }
    Ok(parsed)
}

/// Everything a source query needs that depends on the partition's selection
/// and current addresses.
pub(crate) struct BuiltSelection {
    pub receipt_selections: Vec<net_types::ReceiptSelection>,
    /// Which receipt columns the selection's kinds read, so the field
    /// selection only requests what item building needs.
    pub needs_log_data: bool,
    pub needs_supply: bool,
    pub needs_transfer: bool,
    pub needs_call: bool,
}

fn parse_root_contract_ids(addresses: &[String]) -> Result<Vec<Hash>> {
    addresses
        .iter()
        .map(|a| Hash::decode_hex(a).map_err(|e| anyhow!("failed to parse contract id {a}: {e:?}")))
        .collect()
}

fn push_unique<T: PartialEq + Copy>(values: &mut Vec<T>, value: T) {
    if !values.contains(&value) {
        values.push(value);
    }
}

/// Builds per-query receipt selections from the registrations passed at client
/// construction. Registrations are keyed by their chain-scoped sequential
/// index; a query names the indexes of its partition's selection plus the
/// partition's current addresses per contract.
pub(crate) struct SelectionBuilder {
    registrations: HashMap<i64, std::sync::Arc<Registration>>,
}

impl SelectionBuilder {
    pub(crate) fn from_registrations(
        registrations: &[FuelOnEventRegistrationInput],
        store: &StoreInner,
    ) -> Result<Self> {
        Ok(Self {
            registrations: parse_registrations(registrations, store)?
                .into_iter()
                .map(|reg| (reg.index, std::sync::Arc::new(reg)))
                .collect(),
        })
    }

    pub(crate) fn build(
        &self,
        registration_indexes: &[i64],
        address_set: &AddressSet,
        client_filtered: &crate::address_store::client_filtered_contracts::ClientFilteredContracts,
    ) -> Result<BuiltSelection> {
        // Wildcard registrations pool into address-free selections; the rest
        // group per contract so one contract's query can't fetch a sibling's
        // receipts.
        let mut wildcard_receipt_types: Vec<u8> = Vec::new();
        let mut wildcard_rbs: Vec<u64> = Vec::new();
        let mut receipt_types_by_contract: HashMap<&str, Vec<u8>> = HashMap::new();
        let mut rbs_by_contract: HashMap<&str, Vec<u64>> = HashMap::new();
        // First-appearance order of address-bound contracts, so the built
        // query is stable across calls.
        let mut ordered_contracts: Vec<&str> = Vec::new();

        let mut needs_log_data = false;
        let mut needs_supply = false;
        let mut needs_transfer = false;
        let mut needs_call = false;

        for id in registration_indexes {
            let reg = self
                .registrations
                .get(id)
                .with_context(|| format!("Unknown registration index {id} in query selection"))?;
            match &reg.kind {
                RegistrationKind::LogData { .. } => needs_log_data = true,
                RegistrationKind::Mint | RegistrationKind::Burn => needs_supply = true,
                RegistrationKind::Transfer => needs_transfer = true,
                RegistrationKind::Call => needs_call = true,
            }
            // A client-filtered contract is fetched address-free — the query
            // carries none of its addresses — so its receipt types pool with the
            // wildcards. Matching gates the over-fetched receipts on the store
            // alone (`force_wildcard`); dropping them from the query instead
            // would mean never fetching the contract at all.
            let address_free = reg.is_wildcard || client_filtered.applies(&reg.contract_name);
            match (&reg.kind, address_free) {
                (RegistrationKind::LogData { rb, .. }, true) => push_unique(&mut wildcard_rbs, *rb),
                (RegistrationKind::LogData { rb, .. }, false) => push_unique(
                    rbs_by_contract
                        .entry(reg.contract_name.as_str())
                        .or_default(),
                    *rb,
                ),
                (kind, true) => {
                    for &receipt_type in kind.receipt_types() {
                        push_unique(&mut wildcard_receipt_types, receipt_type);
                    }
                }
                (kind, false) => {
                    let bucket = receipt_types_by_contract
                        .entry(reg.contract_name.as_str())
                        .or_default();
                    for &receipt_type in kind.receipt_types() {
                        push_unique(bucket, receipt_type);
                    }
                }
            }
            if !address_free && !ordered_contracts.contains(&reg.contract_name.as_str()) {
                ordered_contracts.push(reg.contract_name.as_str());
            }
        }

        let mut receipt_selections: Vec<net_types::ReceiptSelection> = Vec::new();
        if !wildcard_receipt_types.is_empty() {
            receipt_selections.push(net_types::ReceiptSelection {
                receipt_type: wildcard_receipt_types,
                tx_status: vec![TX_STATUS_SUCCESS],
                ..Default::default()
            });
        }
        if !wildcard_rbs.is_empty() {
            receipt_selections.push(net_types::ReceiptSelection {
                receipt_type: vec![RECEIPT_LOG_DATA],
                rb: wildcard_rbs,
                tx_status: vec![TX_STATUS_SUCCESS],
                ..Default::default()
            });
        }
        let rendered = address_set.render();
        for contract_name in ordered_contracts {
            let addresses = match rendered.slice(contract_name) {
                Some(slice) if !slice.addresses.is_empty() => {
                    parse_root_contract_ids(&slice.addresses)?
                }
                _ => continue,
            };
            if let Some(receipt_types) = receipt_types_by_contract.remove(contract_name) {
                receipt_selections.push(net_types::ReceiptSelection {
                    root_contract_id: addresses.clone(),
                    receipt_type: receipt_types,
                    tx_status: vec![TX_STATUS_SUCCESS],
                    ..Default::default()
                });
            }
            if let Some(rbs) = rbs_by_contract.remove(contract_name) {
                receipt_selections.push(net_types::ReceiptSelection {
                    root_contract_id: addresses,
                    receipt_type: vec![RECEIPT_LOG_DATA],
                    rb: rbs,
                    tx_status: vec![TX_STATUS_SUCCESS],
                    ..Default::default()
                });
            }
        }

        Ok(BuiltSelection {
            receipt_selections,
            needs_log_data,
            needs_supply,
            needs_transfer,
            needs_call,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::{fuel_store, set_of};
    use crate::address_store::AddressStore;

    const ADDR_1: &str = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcde1";
    const ADDR_2: &str = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcde2";
    const ADDR_3: &str = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcde3";

    fn reg(
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
            abi: log_id.map(|id| crate::ecosystems::fuel::log_decoder::test_abi(id, "u8")),
        }
    }

    /// A store over `entries` plus a set spanning all of them — the pair a
    /// query is built and matched from. Keep the store alive: the set borrows it.
    fn addresses(entries: &[(&str, &[&str])]) -> (AddressStore, AddressSet) {
        let store = fuel_store(entries);
        let names: Vec<&str> = entries.iter().map(|(name, _)| *name).collect();
        let set = set_of(&store, &names);
        (store, set)
    }

    /// Contract ids as 32 raw bytes — the store's key.
    fn key_of(address: &str) -> Hash {
        Hash::decode_hex(address).unwrap()
    }

    /// A contract id no contract holds.
    const UNOWNED_KEY: [u8; 32] = [0xff; 32];

    /// Every registration, as the matcher reads them.
    fn parsed(regs: &[FuelOnEventRegistrationInput], store: &AddressStore) -> Vec<Registration> {
        parse_registrations(regs, &store.handle().read().unwrap()).unwrap()
    }

    /// The indexes of the registrations a receipt matches.
    fn matched(
        regs: &[Registration],
        store: &AddressStore,
        receipt_type: u8,
        rb: Option<u64>,
        emitter: &[u8],
        block: i64,
    ) -> Vec<i64> {
        let guard = store.handle();
        let guard = guard.read().unwrap();
        regs.iter()
            .filter(|reg| reg.matches(receipt_type, rb, emitter, block, &guard))
            .map(|reg| reg.index)
            .collect()
    }

    fn selection_view(
        s: &net_types::ReceiptSelection,
    ) -> (Vec<String>, Vec<u8>, Vec<u64>, Vec<u8>) {
        (
            s.root_contract_id.iter().map(Hex::encode_hex).collect(),
            s.receipt_type.clone(),
            s.rb.clone(),
            s.tx_status.clone(),
        )
    }

    #[test]
    fn groups_receipt_types_and_rbs_per_contract() {
        let regs = [
            reg(0, "C1", FuelEventKind::LogData, false, Some("1")),
            reg(1, "C1", FuelEventKind::Mint, false, None),
            reg(2, "C1", FuelEventKind::Burn, false, None),
            reg(3, "C1", FuelEventKind::Transfer, false, None),
            reg(4, "C2", FuelEventKind::LogData, false, Some("3")),
            reg(5, "C2", FuelEventKind::Burn, false, None),
        ];
        let (store, set) = addresses(&[("C1", &[ADDR_1, ADDR_2]), ("C2", &[ADDR_3])]);
        let builder =
            SelectionBuilder::from_registrations(&regs, &store.handle().read().unwrap()).unwrap();
        let built = builder
            .build(&[0, 1, 2, 3, 4, 5], &set, &Default::default())
            .unwrap();
        assert_eq!(
            built
                .receipt_selections
                .iter()
                .map(selection_view)
                .collect::<Vec<_>>(),
            vec![
                (
                    vec![ADDR_1.to_string(), ADDR_2.to_string()],
                    vec![
                        RECEIPT_MINT,
                        RECEIPT_BURN,
                        RECEIPT_TRANSFER,
                        RECEIPT_TRANSFER_OUT
                    ],
                    vec![],
                    vec![TX_STATUS_SUCCESS],
                ),
                (
                    vec![ADDR_1.to_string(), ADDR_2.to_string()],
                    vec![RECEIPT_LOG_DATA],
                    vec![1],
                    vec![TX_STATUS_SUCCESS],
                ),
                (
                    vec![ADDR_3.to_string()],
                    vec![RECEIPT_BURN],
                    vec![],
                    vec![TX_STATUS_SUCCESS],
                ),
                (
                    vec![ADDR_3.to_string()],
                    vec![RECEIPT_LOG_DATA],
                    vec![3],
                    vec![TX_STATUS_SUCCESS],
                ),
            ]
        );
    }

    #[test]
    fn wildcard_selections_stay_address_free() {
        let (store, set) = addresses(&[("C1", &[]), ("C2", &[])]);
        let builder = SelectionBuilder::from_registrations(
            &[
                reg(0, "C1", FuelEventKind::Call, true, None),
                reg(1, "C1", FuelEventKind::LogData, true, Some("2")),
                reg(2, "C2", FuelEventKind::LogData, true, Some("3")),
            ],
            &store.handle().read().unwrap(),
        )
        .unwrap();
        let built = builder
            .build(&[0, 1, 2], &set, &Default::default())
            .unwrap();
        assert_eq!(
            built
                .receipt_selections
                .iter()
                .map(selection_view)
                .collect::<Vec<_>>(),
            vec![
                (vec![], vec![RECEIPT_CALL], vec![], vec![TX_STATUS_SUCCESS]),
                (
                    vec![],
                    vec![RECEIPT_LOG_DATA],
                    vec![2, 3],
                    vec![TX_STATUS_SUCCESS],
                ),
            ]
        );
    }

    #[test]
    fn contract_without_addresses_is_skipped() {
        let (store, set) = addresses(&[("C1", &[])]);
        let builder = SelectionBuilder::from_registrations(
            &[reg(0, "C1", FuelEventKind::Mint, false, None)],
            &store.handle().read().unwrap(),
        )
        .unwrap();
        let built = builder.build(&[0], &set, &Default::default()).unwrap();
        assert!(built.receipt_selections.is_empty());
    }

    #[test]
    fn client_filtered_contract_is_fetched_address_free() {
        // A contract switched to client-side filtering carries none of its
        // addresses in the query, so its receipt types have to pool with the
        // wildcards. Leaving them out of the selection would mean never
        // fetching the contract at all, while matching — which accepts its
        // receipts under `force_wildcard` — waited for receipts that were
        // never requested.
        let store = fuel_store(&[("C1", &[ADDR_1]), ("C2", &[ADDR_2])]);
        let set = set_of(&store, &["C2"]);
        let builder = SelectionBuilder::from_registrations(
            &[
                reg(0, "C1", FuelEventKind::Mint, false, None),
                reg(1, "C1", FuelEventKind::LogData, false, Some("1")),
                reg(2, "C2", FuelEventKind::Mint, false, None),
            ],
            &store.handle().read().unwrap(),
        )
        .unwrap();
        let client_filtered =
            crate::address_store::client_filtered_contracts::ClientFilteredContracts::from_vec(
                vec!["C1".to_string()],
            );
        let built = builder.build(&[0, 1, 2], &set, &client_filtered).unwrap();

        let regs = parsed(&[reg(0, "C1", FuelEventKind::Mint, false, None)], &store);
        // The store alone decides: the partition's set holds no C1 address.
        let route_forced =
            |key: &Hash| !matched(&regs, &store, RECEIPT_MINT, None, &key[..], 0).is_empty();
        let addr_1 = key_of(ADDR_1);
        let addr_2 = key_of(ADDR_2);
        assert_eq!(
            (
                built
                    .receipt_selections
                    .iter()
                    .map(selection_view)
                    .collect::<Vec<_>>(),
                route_forced(&addr_1),
                // Registered, but for C2 — still not C1's receipt.
                route_forced(&addr_2),
            ),
            (
                vec![
                    (vec![], vec![RECEIPT_MINT], vec![], vec![TX_STATUS_SUCCESS]),
                    (
                        vec![],
                        vec![RECEIPT_LOG_DATA],
                        vec![1],
                        vec![TX_STATUS_SUCCESS],
                    ),
                    (
                        vec![ADDR_2.to_string()],
                        vec![RECEIPT_MINT],
                        vec![],
                        vec![TX_STATUS_SUCCESS],
                    ),
                ],
                true,
                false,
            )
        );
    }

    #[test]
    fn selection_subset_excludes_other_registrations() {
        let (store, set) = addresses(&[("C1", &[ADDR_1])]);
        let builder = SelectionBuilder::from_registrations(
            &[
                reg(0, "C1", FuelEventKind::Mint, false, None),
                reg(1, "C1", FuelEventKind::Burn, false, None),
            ],
            &store.handle().read().unwrap(),
        )
        .unwrap();
        let built = builder.build(&[1], &set, &Default::default()).unwrap();
        assert_eq!(
            built
                .receipt_selections
                .iter()
                .map(selection_view)
                .collect::<Vec<_>>(),
            vec![(
                vec![ADDR_1.to_string()],
                vec![RECEIPT_BURN],
                vec![],
                vec![TX_STATUS_SUCCESS]
            )]
        );
    }

    #[test]
    fn non_wildcard_call_errors() {
        let (store, _set) = addresses(&[("C1", &[])]);
        let err = SelectionBuilder::from_registrations(
            &[reg(0, "C1", FuelEventKind::Call, false, None)],
            &store.handle().read().unwrap(),
        )
        .err()
        .unwrap();
        assert!(format!("{err:#}")
            .contains("Call receipt indexing currently supported only in wildcard mode"));
    }

    #[test]
    fn log_data_without_log_id_errors() {
        let (store, _set) = addresses(&[("C1", &[])]);
        let err = SelectionBuilder::from_registrations(
            &[reg(0, "C1", FuelEventKind::LogData, false, None)],
            &store.handle().read().unwrap(),
        )
        .err()
        .unwrap();
        assert!(format!("{err:#}").contains("missing logId"));
    }

    #[test]
    fn routing_fans_out_to_wildcards_and_owned_contract() {
        let store = fuel_store(&[("Owned", &[ADDR_1]), ("W", &[]), ("Other", &[])]);
        let regs = parsed(
            &[
                reg(0, "Owned", FuelEventKind::Mint, false, None),
                reg(1, "W", FuelEventKind::Mint, true, None),
                reg(2, "Other", FuelEventKind::Mint, false, None),
            ],
            &store,
        );
        let owned_key = key_of(ADDR_1);
        assert_eq!(
            (
                matched(&regs, &store, RECEIPT_MINT, None, &owned_key[..], 0),
                matched(&regs, &store, RECEIPT_MINT, None, &UNOWNED_KEY, 0),
            ),
            (vec![0, 1], vec![1])
        );
    }

    #[test]
    fn contract_registered_after_the_receipt_block_is_dropped() {
        // Fuel gets the same temporal gate as EVM: a receipt from before the
        // contract's registration block never reaches its handler.
        let store = AddressStore::new_fuel(vec![crate::address_store::AddressStoreContract {
            name: "Owned".to_string(),
            start_block: None,
            depends_on_addresses: true,
        }])
        .unwrap();
        store
            .register_batch(vec![crate::address_store::AddressRegistration {
                address: ADDR_1.to_string(),
                contract_name: "Owned".to_string(),
                registration_block: 50,
            }])
            .unwrap();
        let regs = parsed(&[reg(0, "Owned", FuelEventKind::Mint, false, None)], &store);
        let owned_key = key_of(ADDR_1);
        assert_eq!(
            (
                matched(&regs, &store, RECEIPT_MINT, None, &owned_key[..], 49),
                matched(&regs, &store, RECEIPT_MINT, None, &owned_key[..], 50),
            ),
            (vec![], vec![0])
        );
    }

    #[test]
    fn registration_start_block_holds_back_only_its_own_registration() {
        // Two registrations of one event on one contract: one unrestricted, one
        // starting at height 100. The address store's start block is
        // contract-wide, so only this per-registration gate separates them.
        let mut restricted = reg(1, "Owned", FuelEventKind::Mint, false, None);
        restricted.start_block = Some(100);
        let store = fuel_store(&[("Owned", &[ADDR_1])]);
        let regs = parsed(
            &[
                reg(0, "Owned", FuelEventKind::Mint, false, None),
                restricted,
            ],
            &store,
        );
        let owned_key = key_of(ADDR_1);
        let at = |block| matched(&regs, &store, RECEIPT_MINT, None, &owned_key[..], block);
        assert_eq!((at(99), at(100)), (vec![0], vec![0, 1]));
    }

    #[test]
    fn transfer_matches_both_transfer_and_transfer_out() {
        let store = fuel_store(&[("C", &[])]);
        let regs = parsed(&[reg(0, "C", FuelEventKind::Transfer, true, None)], &store);
        let any =
            |receipt_type| !matched(&regs, &store, receipt_type, None, &UNOWNED_KEY, 0).is_empty();
        assert_eq!(
            (
                any(RECEIPT_TRANSFER),
                any(RECEIPT_TRANSFER_OUT),
                any(RECEIPT_MINT),
            ),
            (true, true, false)
        );
    }

    #[test]
    fn log_data_routes_by_rb() {
        let store = fuel_store(&[("C", &[])]);
        let regs = parsed(
            &[
                reg(0, "C", FuelEventKind::LogData, true, Some("1")),
                reg(1, "C", FuelEventKind::LogData, true, Some("2")),
            ],
            &store,
        );
        assert_eq!(
            matched(&regs, &store, RECEIPT_LOG_DATA, Some(2), &UNOWNED_KEY, 0),
            vec![1]
        );
    }

    #[test]
    fn every_selection_filters_to_successful_tx_status() {
        // Only receipts from successful transactions are indexed, so every
        // built selection — wildcard, contract-bound receipt types, and
        // contract-bound rb — must carry `tx_status = [1]`.
        let (store, set) = addresses(&[("C1", &[ADDR_1]), ("W", &[])]);
        let builder = SelectionBuilder::from_registrations(
            &[
                reg(0, "C1", FuelEventKind::Mint, false, None),
                reg(1, "C1", FuelEventKind::LogData, false, Some("1")),
                reg(2, "W", FuelEventKind::Call, true, None),
                reg(3, "W", FuelEventKind::LogData, true, Some("2")),
            ],
            &store.handle().read().unwrap(),
        )
        .unwrap();
        let built = builder
            .build(&[0, 1, 2, 3], &set, &Default::default())
            .unwrap();
        assert!(built
            .receipt_selections
            .iter()
            .all(|s| s.tx_status == vec![TX_STATUS_SUCCESS]));
    }
}
