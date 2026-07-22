use std::collections::HashMap;

use anyhow::{anyhow, Context, Result};
use hyperfuel_client::format::{Hash, Hex};
use hyperfuel_client::net_types;
use napi_derive::napi;

// FuelVM receipt type codes (see FuelSDK.receiptType on the JS side).
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
/// the `LogData` variant carries its parsed `rb`, so a LogData registration
/// can't exist without one and no other kind can carry a stray rb — the
/// invalid states the napi input's `kind`+`log_id` pair could express are
/// resolved once, at construction.
#[derive(Clone, Copy)]
pub(crate) enum RegistrationKind {
    LogData { rb: u64 },
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
/// client construction: routing identity plus the receipt-selection state
/// queries are built from.
#[napi(object)]
pub struct FuelOnEventRegistrationInput {
    /// Chain-scoped sequential registration index; returned on every routed
    /// item so JS resolves the registration by array index.
    pub index: i64,
    pub event_name: String,
    pub contract_name: String,
    pub is_wildcard: bool,
    pub kind: FuelEventKind,
    /// The LogData `rb` value as a decimal string (u64). Required for
    /// `LogData`, ignored otherwise.
    pub log_id: Option<String>,
}

pub(crate) struct Registration {
    pub index: i64,
    pub contract_name: String,
    pub is_wildcard: bool,
    pub kind: RegistrationKind,
}

impl Registration {
    /// Whether a receipt belongs to this registration: matching receipt type
    /// (and `rb` for LogData), emitted by an allowed contract — wildcard
    /// registrations accept any contract, contract-bound ones only their own.
    pub(crate) fn matches(
        &self,
        receipt_type: u8,
        rb: Option<u64>,
        contract_name: Option<&str>,
    ) -> bool {
        let kind_matches = match self.kind {
            RegistrationKind::LogData { rb: reg_rb } => {
                receipt_type == RECEIPT_LOG_DATA && rb == Some(reg_rb)
            }
            kind => kind.receipt_types().contains(&receipt_type),
        };
        kind_matches && (self.is_wildcard || contract_name == Some(self.contract_name.as_str()))
    }
}

/// Everything a source query needs that depends on the partition's selection
/// and current addresses.
pub(crate) struct BuiltSelection {
    pub receipt_selections: Vec<net_types::ReceiptSelection>,
    /// Inverted address index for routing (1:1 — each address belongs to one
    /// contract).
    pub contract_name_by_address: HashMap<String, String>,
    /// The selection's registrations sorted by index, for routing.
    pub registrations: Vec<std::sync::Arc<Registration>>,
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
    ) -> Result<Self> {
        let mut map = HashMap::new();
        for reg in registrations {
            let kind = match reg.kind {
                FuelEventKind::LogData => {
                    let log_id = reg.log_id.as_ref().with_context(|| {
                        format!("LogData registration {} is missing logId", reg.event_name)
                    })?;
                    let rb = log_id.parse::<u64>().with_context(|| {
                        format!("parse logId {} for event {}", log_id, reg.event_name)
                    })?;
                    RegistrationKind::LogData { rb }
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
            let parsed = Registration {
                index: reg.index,
                contract_name: reg.contract_name.clone(),
                is_wildcard: reg.is_wildcard,
                kind,
            };
            anyhow::ensure!(
                map.insert(reg.index, std::sync::Arc::new(parsed)).is_none(),
                "Duplicate registration index {} for event {}",
                reg.index,
                reg.event_name,
            );
        }
        Ok(Self { registrations: map })
    }

    pub(crate) fn build(
        &self,
        registration_indexes: &[i64],
        addresses_by_contract_name: &HashMap<String, Vec<String>>,
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

        let mut registrations = Vec::with_capacity(registration_indexes.len());
        let mut needs_log_data = false;
        let mut needs_supply = false;
        let mut needs_transfer = false;
        let mut needs_call = false;

        for id in registration_indexes {
            let reg = self
                .registrations
                .get(id)
                .with_context(|| format!("Unknown registration index {id} in query selection"))?;
            registrations.push(reg.clone());
            match reg.kind {
                RegistrationKind::LogData { .. } => needs_log_data = true,
                RegistrationKind::Mint | RegistrationKind::Burn => needs_supply = true,
                RegistrationKind::Transfer => needs_transfer = true,
                RegistrationKind::Call => needs_call = true,
            }
            match (reg.kind, reg.is_wildcard) {
                (RegistrationKind::LogData { rb }, true) => push_unique(&mut wildcard_rbs, rb),
                (RegistrationKind::LogData { rb }, false) => push_unique(
                    rbs_by_contract
                        .entry(reg.contract_name.as_str())
                        .or_default(),
                    rb,
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
            if !reg.is_wildcard && !ordered_contracts.contains(&reg.contract_name.as_str()) {
                ordered_contracts.push(reg.contract_name.as_str());
            }
        }
        // Deterministic item order per receipt, independent of the selection's
        // index order.
        registrations.sort_unstable_by_key(|reg| reg.index);

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
        for contract_name in ordered_contracts {
            let addresses = match addresses_by_contract_name.get(contract_name) {
                None => continue,
                Some(addresses) if addresses.is_empty() => continue,
                Some(addresses) => parse_root_contract_ids(addresses)?,
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

        // Routing needs the whole partition index, including contracts with no
        // selection in this query (their receipts still fall back to wildcards).
        let mut contract_name_by_address = HashMap::new();
        for (contract_name, addresses) in addresses_by_contract_name {
            for address in addresses {
                contract_name_by_address.insert(address.clone(), contract_name.clone());
            }
        }

        Ok(BuiltSelection {
            receipt_selections,
            contract_name_by_address,
            registrations,
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
            kind,
            log_id: log_id.map(str::to_string),
        }
    }

    fn addresses(entries: &[(&str, &[&str])]) -> HashMap<String, Vec<String>> {
        entries
            .iter()
            .map(|(name, addrs)| {
                (
                    name.to_string(),
                    addrs.iter().map(|a| a.to_string()).collect(),
                )
            })
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
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, "C1", FuelEventKind::LogData, false, Some("1")),
            reg(1, "C1", FuelEventKind::Mint, false, None),
            reg(2, "C1", FuelEventKind::Burn, false, None),
            reg(3, "C1", FuelEventKind::Transfer, false, None),
            reg(4, "C2", FuelEventKind::LogData, false, Some("3")),
            reg(5, "C2", FuelEventKind::Burn, false, None),
        ])
        .unwrap();
        let built = builder
            .build(
                &[0, 1, 2, 3, 4, 5],
                &addresses(&[("C1", &[ADDR_1, ADDR_2]), ("C2", &[ADDR_3])]),
            )
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
        assert_eq!(
            built.contract_name_by_address.get(ADDR_3),
            Some(&"C2".to_string())
        );
    }

    #[test]
    fn wildcard_selections_stay_address_free() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, "C1", FuelEventKind::Call, true, None),
            reg(1, "C1", FuelEventKind::LogData, true, Some("2")),
            reg(2, "C2", FuelEventKind::LogData, true, Some("3")),
        ])
        .unwrap();
        let built = builder.build(&[0, 1, 2], &HashMap::new()).unwrap();
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
        let builder =
            SelectionBuilder::from_registrations(&[reg(0, "C1", FuelEventKind::Mint, false, None)])
                .unwrap();
        let built = builder.build(&[0], &addresses(&[("C1", &[])])).unwrap();
        assert!(built.receipt_selections.is_empty());
    }

    #[test]
    fn selection_subset_excludes_other_registrations() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, "C1", FuelEventKind::Mint, false, None),
            reg(1, "C1", FuelEventKind::Burn, false, None),
        ])
        .unwrap();
        let built = builder
            .build(&[1], &addresses(&[("C1", &[ADDR_1])]))
            .unwrap();
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
        let err =
            SelectionBuilder::from_registrations(&[reg(0, "C1", FuelEventKind::Call, false, None)])
                .err()
                .unwrap();
        assert!(format!("{err:#}")
            .contains("Call receipt indexing currently supported only in wildcard mode"));
    }

    #[test]
    fn log_data_without_log_id_errors() {
        let err = SelectionBuilder::from_registrations(&[reg(
            0,
            "C1",
            FuelEventKind::LogData,
            false,
            None,
        )])
        .err()
        .unwrap();
        assert!(format!("{err:#}").contains("missing logId"));
    }

    #[test]
    fn routing_fans_out_to_wildcards_and_owned_contract() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, "Owned", FuelEventKind::Mint, false, None),
            reg(1, "W", FuelEventKind::Mint, true, None),
            reg(2, "Other", FuelEventKind::Mint, false, None),
        ])
        .unwrap();
        let built = builder
            .build(&[0, 1, 2], &addresses(&[("Owned", &[ADDR_1])]))
            .unwrap();
        let route = |contract_name: Option<&str>| -> Vec<i64> {
            built
                .registrations
                .iter()
                .filter(|reg| reg.matches(RECEIPT_MINT, None, contract_name))
                .map(|reg| reg.index)
                .collect()
        };
        assert_eq!((route(Some("Owned")), route(None)), (vec![0, 1], vec![1]));
    }

    #[test]
    fn transfer_matches_both_transfer_and_transfer_out() {
        let builder = SelectionBuilder::from_registrations(&[reg(
            0,
            "C",
            FuelEventKind::Transfer,
            true,
            None,
        )])
        .unwrap();
        let built = builder.build(&[0], &HashMap::new()).unwrap();
        let reg = &built.registrations[0];
        assert_eq!(
            (
                reg.matches(RECEIPT_TRANSFER, None, None),
                reg.matches(RECEIPT_TRANSFER_OUT, None, None),
                reg.matches(RECEIPT_MINT, None, None),
            ),
            (true, true, false)
        );
    }

    #[test]
    fn log_data_routes_by_rb() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, "C", FuelEventKind::LogData, true, Some("1")),
            reg(1, "C", FuelEventKind::LogData, true, Some("2")),
        ])
        .unwrap();
        let built = builder.build(&[0, 1], &HashMap::new()).unwrap();
        let routed: Vec<i64> = built
            .registrations
            .iter()
            .filter(|reg| reg.matches(RECEIPT_LOG_DATA, Some(2), None))
            .map(|reg| reg.index)
            .collect();
        assert_eq!(routed, vec![1]);
    }

    #[test]
    fn every_selection_filters_to_successful_tx_status() {
        // Only receipts from successful transactions are indexed, so every
        // built selection — wildcard, contract-bound receipt types, and
        // contract-bound rb — must carry `tx_status = [1]`.
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, "C1", FuelEventKind::Mint, false, None),
            reg(1, "C1", FuelEventKind::LogData, false, Some("1")),
            reg(2, "W", FuelEventKind::Call, true, None),
            reg(3, "W", FuelEventKind::LogData, true, Some("2")),
        ])
        .unwrap();
        let built = builder
            .build(&[0, 1, 2, 3], &addresses(&[("C1", &[ADDR_1])]))
            .unwrap();
        assert!(built
            .receipt_selections
            .iter()
            .all(|s| s.tx_status == vec![TX_STATUS_SUCCESS]));
    }
}
