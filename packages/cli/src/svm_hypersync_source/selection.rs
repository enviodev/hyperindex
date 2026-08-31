use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use hypersync_client_solana::simple_types as simple;
use hypersync_solana_net_types::query as net;
use hypersync_solana_net_types::types::Address;
use napi_derive::napi;

use super::fields;
use super::mod_helpers::hex_to_bytes;
use super::types::required;
use crate::address_store::{Emitter, StoreInner};

/// One instruction call with the fields routing and item building read, lifted
/// out of the client's all-`Option` row once per instruction: base58 is
/// rendered here rather than at every account comparison. Discriminator
/// prefixes are sliced from `data` so the query does not fetch `d1`–`d8`.
/// `account_arguments` is empty when that column was not selected.
pub(crate) struct InstructionCall {
    pub slot: u64,
    pub transaction_index: u32,
    pub instruction_address: Vec<u32>,
    /// The invoked program's account, base58.
    pub executing_account: String,
    /// The instruction's account arguments, base58.
    pub account_arguments: Vec<String>,
    pub data: Vec<u8>,
    pub is_inner: bool,
    /// Success of the PARENT transaction, not of this invocation.
    pub tx_success: bool,
}

impl TryFrom<&simple::InstructionCall> for InstructionCall {
    type Error = anyhow::Error;

    fn try_from(i: &simple::InstructionCall) -> Result<Self> {
        Ok(Self {
            slot: required(i.slot, "instruction.slot")?,
            transaction_index: required(i.transaction_index, "instruction.transaction_index")?,
            instruction_address: required(
                i.instruction_address.clone(),
                "instruction.instruction_address",
            )?,
            executing_account: required(i.executing_account, "instruction.executing_account")?
                .to_string(),
            account_arguments: i
                .account_arguments
                .as_ref()
                .map(|accounts| accounts.iter().map(|account| account.to_string()).collect())
                .unwrap_or_default(),
            data: required(i.data.clone(), "instruction.data")?,
            is_inner: required(i.is_inner, "instruction.is_inner")?,
            tx_success: required(i.tx_success, "instruction.tx_success")?,
        })
    }
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmAccountFilterInput {
    /// Positional account index (`a0`..`a9` on the wire).
    pub position: i64,
    /// Base58 pubkeys; the account at `position` must be one of them.
    pub values: Vec<String>,
}

/// The full per-(instruction, chain) registration crossing the boundary once
/// at client construction: routing identity, the fetch state queries are
/// built from, and the Borsh schema used for inline decoding.
#[napi(object)]
#[derive(Clone)]
pub struct SvmOnEventRegistrationInput {
    /// Chain-scoped sequential registration index; returned on every routed
    /// item so JS resolves the registration by array index.
    pub index: i64,
    pub instruction_name: String,
    /// Program name (the config's contract name).
    pub contract_name: String,
    /// Base58 program id. Empty means the config carries no real program
    /// (placeholder); such a registration is never fetched or routed.
    pub program_id: String,
    pub is_wildcard: bool,
    /// Earliest slot this registration accepts; absent is unrestricted. See
    /// `crate::registration_start_block`.
    pub start_block: Option<i64>,
    /// Hex-encoded discriminator. `None` matches every instruction in the
    /// program (lowest routing priority). Byte length is derived from the hex.
    pub discriminator: Option<String>,
    /// `None` matches both outer and inner (CPI-invoked) instructions.
    pub is_inner: Option<bool>,
    /// Disjunctive normal form: outer array is OR of AND-groups.
    pub account_filters: Vec<Vec<SvmAccountFilterInput>>,
    /// Selected transaction fields, camelCase (`Internal.svmTransactionField`).
    pub transaction_fields: Vec<String>,
    /// Selected block fields, camelCase (`Internal.svmBlockField`).
    pub block_fields: Vec<String>,
    /// Dotted account-activity field names from handler `fields.accountActivity`.
    pub account_activity_fields: Vec<String>,
    /// Selected log field names (`kind`, `message`).
    pub log_fields: Vec<String>,
    /// Selected instruction fields (`args`, `accounts`, `accountArguments`,
    /// `programId`, `data`, `path`, `isInner`).
    pub instruction_fields: Vec<String>,
    /// Positional account names from the Borsh schema, in declared order.
    /// Empty (with `args_json` absent) means no schema for this instruction.
    pub accounts: Vec<String>,
    /// Borsh args layout as `Vec<ArgDef>` JSON. Absent means no schema.
    pub args_json: Option<String>,
    /// Program-level nominal-type registry (`BTreeMap<String, ArgType>` JSON),
    /// duplicated on every instruction of the program.
    pub defined_types_json: Option<String>,
}

pub(crate) struct Registration {
    pub index: i64,
    pub contract_name: String,
    /// This registration's program in the chain's address store, resolved once
    /// at construction so the per-instruction gate is an index compare.
    pub contract_idx: u32,
    pub program_id: String,
    pub is_wildcard: bool,
    /// Earliest slot this registration accepts; `None` is unrestricted.
    pub start_block: Option<i64>,
    /// Decoded discriminator bytes; `None` = program-wide.
    pub discriminator: Option<Vec<u8>>,
    /// Original hex value for the query's `dN` filter.
    pub discriminator_hex: Option<String>,
    pub byte_len: usize,
    pub is_inner: Option<bool>,
    pub account_filters: Vec<Vec<(usize, Vec<String>)>>,
    pub transaction_columns: Vec<&'static str>,
    pub account_activity_columns: Vec<&'static str>,
    pub block_columns: Vec<&'static str>,
    pub log_columns: Vec<&'static str>,
    pub instruction_columns: Vec<&'static str>,
    /// `fields.instruction` contains `args` — Borsh decode is skipped otherwise.
    pub selects_args: bool,
}

impl Registration {
    fn parse(input: &SvmOnEventRegistrationInput, store: &StoreInner) -> Result<Self> {
        let discriminator = input
            .discriminator
            .as_deref()
            .filter(|d| !d.is_empty())
            .map(|d| hex_to_bytes(d).context("decode discriminator hex"))
            .transpose()?;
        let byte_len = match &discriminator {
            Some(bytes) => {
                anyhow::ensure!(
                    matches!(bytes.len(), 1 | 2 | 4 | 8),
                    "discriminator must be 1/2/4/8 bytes, got {} bytes",
                    bytes.len(),
                );
                bytes.len()
            }
            None => 0,
        };
        let account_filters = input
            .account_filters
            .iter()
            .map(|group| {
                group
                    .iter()
                    .map(|filter| {
                        let position = usize::try_from(filter.position)
                            .ok()
                            .filter(|p| *p <= 9)
                            .with_context(|| {
                                format!("account filter position {} out of a0..a9", filter.position)
                            })?;
                        Ok((position, filter.values.clone()))
                    })
                    .collect::<Result<Vec<_>>>()
            })
            .collect::<Result<Vec<_>>>()?;
        let transaction_columns = fields::transaction_query_columns(&input.transaction_fields)?;
        let account_activity_columns =
            fields::account_activity_query_columns(&input.account_activity_fields)?;
        let block_columns = fields::block_extra_columns(&input.block_fields)?;
        let log_columns = fields::log_query_columns(&input.log_fields)?;
        let instruction_columns = fields::instruction_query_columns(
            &input.instruction_fields,
            !account_filters.is_empty(),
        )?;
        let selects_args = fields::selects(&input.instruction_fields, "args");
        let contract_idx = store.contract_idx(&input.contract_name).with_context(|| {
            format!(
                "Program {} is missing from the chain's address store",
                input.contract_name
            )
        })?;
        Ok(Self {
            index: input.index,
            contract_name: input.contract_name.clone(),
            contract_idx,
            program_id: input.program_id.clone(),
            is_wildcard: input.is_wildcard,
            start_block: input.start_block,
            discriminator,
            discriminator_hex: input.discriminator.clone().filter(|d| !d.is_empty()),
            byte_len,
            is_inner: input.is_inner,
            account_filters,
            transaction_columns,
            account_activity_columns,
            block_columns,
            log_columns,
            instruction_columns,
            selects_args,
        })
    }

    /// Whether an instruction belongs to this registration, discriminator
    /// aside: same program, at or after the registration's own start block, an
    /// allowed owner, the `isInner` constraint, and the
    /// registration's account filters — the filters are re-applied here so an
    /// instruction fetched for a sibling selection can't leak into a
    /// registration whose own filter rejects it.
    ///
    /// Owner rules mirror EVM's: a wildcard registration accepts any program
    /// address; a program-bound one needs the address to be in this partition's
    /// set for its own contract (or, when the contract is client-filtered, only
    /// in the store) and registered at or before the instruction's slot.
    fn matches_scope(
        &self,
        instr: &InstructionCall,
        address: &Emitter,
        force_wildcard: bool,
        store: &StoreInner,
    ) -> bool {
        self.program_id == instr.executing_account
            && address.matches_registration(
                store,
                self.contract_idx,
                self.is_wildcard,
                self.start_block,
                force_wildcard,
            )
            && self
                .is_inner
                .is_none_or(|is_inner| is_inner == instr.is_inner)
            && (self.account_filters.is_empty()
                || self.account_filters.iter().any(|group| {
                    group.iter().all(|(position, values)| {
                        instr
                            .account_arguments
                            .get(*position)
                            .is_some_and(|account| values.contains(account))
                    })
                }))
    }

    fn matches_discriminator(&self, data: &[u8]) -> bool {
        match &self.discriminator {
            Some(bytes) => {
                data.len() >= self.byte_len && &data[..self.byte_len] == bytes.as_slice()
            }
            None => false,
        }
    }
}

/// Parse one position's account-filter values into the wire pubkey type.
fn parse_accounts(values: Option<Vec<String>>, position: usize) -> Result<Vec<Address>> {
    super::query::parse_values(values, &format!("a{position}"))
}

/// One instruction selection of a built query, before conversion to the wire
/// type; `PartialEq` so identical selections from same-signature
/// registrations are deduplicated.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct BuiltInstructionSelection {
    program_id: String,
    discriminator_hex: Option<String>,
    byte_len: usize,
    accounts: [Option<Vec<String>>; 10],
    is_inner: Option<bool>,
}

impl BuiltInstructionSelection {
    fn into_net(self) -> Result<net::InstructionSelection> {
        let mut selection = net::InstructionSelection {
            executing_account: vec![self
                .program_id
                .parse()
                .map_err(|e| anyhow::anyhow!("{e}"))
                .with_context(|| format!("parse program id {:?}", self.program_id))?],
            is_inner: self.is_inner,
            // Instructions of a failed transaction had their state changes
            // rolled back, so they never reach a handler. Filtering them
            // server-side keeps them off the wire entirely.
            tx_success: Some(true),
            ..Default::default()
        };
        if let Some(d) = self.discriminator_hex {
            match self.byte_len {
                1 => selection.d1 = vec![d],
                2 => selection.d2 = vec![d],
                4 => selection.d4 = vec![d],
                8 => selection.d8 = vec![d],
                _ => {}
            }
        }
        let [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9] = self.accounts;
        selection.a0 = parse_accounts(a0, 0)?;
        selection.a1 = parse_accounts(a1, 1)?;
        selection.a2 = parse_accounts(a2, 2)?;
        selection.a3 = parse_accounts(a3, 3)?;
        selection.a4 = parse_accounts(a4, 4)?;
        selection.a5 = parse_accounts(a5, 5)?;
        selection.a6 = parse_accounts(a6, 6)?;
        selection.a7 = parse_accounts(a7, 7)?;
        selection.a8 = parse_accounts(a8, 8)?;
        selection.a9 = parse_accounts(a9, 9)?;
        Ok(selection)
    }
}

/// Everything a source query needs that depends on the partition's selection.
pub(crate) struct BuiltSelection {
    pub instruction_selections: Vec<net::InstructionSelection>,
    /// Union over the selection's registrations; always contains the
    /// slot/blockhash/block_time trio.
    pub block_columns: Vec<&'static str>,
    /// Union over the selection's registrations; non-empty only when a stored
    /// transaction record is actually read (then it carries the
    /// slot/transaction_index store key too).
    pub transaction_columns: Vec<&'static str>,
    /// Empty iff no registration selected any account-activity field.
    pub account_activity_columns: Vec<&'static str>,
    /// Empty iff no registration selected any log field.
    pub log_columns: Vec<&'static str>,
    /// Always at least the routing + always-on payload columns.
    pub instruction_columns: Vec<&'static str>,
    /// The selection's registrations sorted by index, for routing.
    pub registrations: Vec<Arc<Registration>>,
}

/// Builds per-query instruction selections and field unions from the
/// registrations passed at client construction, and routes returned
/// instructions back to them.
pub(crate) struct SelectionBuilder {
    registrations: HashMap<i64, Arc<Registration>>,
}

impl SelectionBuilder {
    pub(crate) fn from_registrations(
        registrations: &[SvmOnEventRegistrationInput],
        store: &StoreInner,
    ) -> Result<Self> {
        let mut map = HashMap::new();
        for reg in registrations {
            let parsed = Registration::parse(reg, store)
                .with_context(|| format!("parse registration for {}", reg.instruction_name))?;
            anyhow::ensure!(
                map.insert(reg.index, Arc::new(parsed)).is_none(),
                "Duplicate registration index {} for instruction {}",
                reg.index,
                reg.instruction_name,
            );
        }
        Ok(Self { registrations: map })
    }

    pub(crate) fn build(&self, registration_indexes: &[i64]) -> Result<BuiltSelection> {
        let mut selections: Vec<BuiltInstructionSelection> = Vec::new();
        // The always-fetched trio: `slot` keys the page's blocks, and the
        // consumer reads time/hash off every block (reorg detection, item
        // timestamps).
        let mut block_columns = fields::BLOCK_KEYS.to_vec();
        let mut transaction_columns: Vec<&'static str> = Vec::new();
        let mut account_activity_columns: Vec<&'static str> = Vec::new();
        let mut log_columns: Vec<&'static str> = Vec::new();
        let mut instruction_columns = fields::INSTRUCTION_REQUIRED.to_vec();
        let mut registrations = Vec::with_capacity(registration_indexes.len());

        for id in registration_indexes {
            let reg = self
                .registrations
                .get(id)
                .with_context(|| format!("Unknown registration index {id} in query selection"))?;
            registrations.push(reg.clone());

            for &column in &reg.block_columns {
                fields::push_unique(&mut block_columns, column);
            }
            for &column in &reg.transaction_columns {
                fields::push_unique(&mut transaction_columns, column);
            }
            for &column in &reg.account_activity_columns {
                fields::push_unique(&mut account_activity_columns, column);
            }
            for &column in &reg.log_columns {
                fields::push_unique(&mut log_columns, column);
            }
            for &column in &reg.instruction_columns {
                fields::push_unique(&mut instruction_columns, column);
            }

            // Placeholder configs carry no real program — skip rather than
            // ship a degenerate match-all selection.
            if reg.program_id.is_empty() {
                continue;
            }
            // Each AND-group becomes its own selection; groups sharing the
            // same `(programId, dN)` are OR-ed by the wire protocol. An empty
            // outer array emits one selection with no account filtering.
            let groups: &[Vec<(usize, Vec<String>)>] = if reg.account_filters.is_empty() {
                &[Vec::new()]
            } else {
                &reg.account_filters
            };
            for group in groups {
                let mut selection = BuiltInstructionSelection {
                    program_id: reg.program_id.clone(),
                    discriminator_hex: reg.discriminator_hex.clone(),
                    byte_len: reg.byte_len,
                    is_inner: reg.is_inner,
                    ..Default::default()
                };
                for (position, values) in group {
                    selection.accounts[*position] = Some(values.clone());
                }
                if !selections.contains(&selection) {
                    selections.push(selection);
                }
            }
        }
        // Deterministic item order per instruction, independent of the
        // selection's index order.
        registrations.sort_unstable_by_key(|reg| reg.index);

        Ok(BuiltSelection {
            instruction_selections: selections
                .into_iter()
                .map(BuiltInstructionSelection::into_net)
                .collect::<Result<Vec<_>>>()?,
            block_columns,
            transaction_columns,
            account_activity_columns,
            log_columns,
            instruction_columns,
            registrations,
        })
    }
}

/// Routes an instruction to the selection's registrations, probing declared
/// discriminator byte lengths longest-first (d8/d4/d2/d1): the first length
/// with any full match wins and the instruction fans out to every
/// registration matching at that length. Program-wide registrations (no
/// discriminator) are the final fallback when no discriminator-keyed
/// registration matched.
pub(crate) fn route_instruction(
    registrations: &[Arc<Registration>],
    instr: &InstructionCall,
    address: &Emitter,
    client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
    store: &StoreInner,
) -> Vec<Arc<Registration>> {
    let scoped = |reg: &Registration| {
        reg.matches_scope(
            instr,
            address,
            client_filtered.applies(&reg.contract_name),
            store,
        )
    };
    for byte_len in [8usize, 4, 2, 1] {
        let matched: Vec<Arc<Registration>> = registrations
            .iter()
            .filter(|reg| {
                reg.byte_len == byte_len && reg.matches_discriminator(&instr.data) && scoped(reg)
            })
            .cloned()
            .collect();
        if !matched.is_empty() {
            return matched;
        }
    }
    registrations
        .iter()
        .filter(|reg| reg.discriminator.is_none() && scoped(reg))
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::{set_of, svm_store};
    use crate::address_store::{AddressSet, AddressStore};

    const PROG_A: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";
    const PROG_B: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
    const ACCOUNT_1: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    const ACCOUNT_2: &str = "So11111111111111111111111111111111111111112";

    fn reg(
        index: i64,
        program_id: &str,
        discriminator: Option<&str>,
        is_wildcard: bool,
    ) -> SvmOnEventRegistrationInput {
        SvmOnEventRegistrationInput {
            index,
            instruction_name: format!("I{index}"),
            contract_name: format!("P_{program_id}"),
            program_id: program_id.to_string(),
            is_wildcard,
            start_block: None,
            discriminator: discriminator.map(str::to_string),
            is_inner: None,
            account_filters: vec![],
            transaction_fields: vec![],
            block_fields: vec![],
            account_activity_fields: vec![],
            log_fields: vec![],
            instruction_fields: vec![],
            accounts: vec![],
            args_json: None,
            defined_types_json: None,
        }
    }

    fn instruction(program_id: &str, data: &[u8]) -> InstructionCall {
        InstructionCall {
            slot: 0,
            transaction_index: 0,
            instruction_address: vec![0],
            executing_account: program_id.to_string(),
            account_arguments: vec![],
            data: data.to_vec(),
            is_inner: false,
            tx_success: true,
        }
    }

    /// Builds a selection with the store and set a real query carries. `owned`
    /// names the (program name, program id) pairs the chain has registered;
    /// every other program exists as a contract holding no addresses, which is
    /// what a wildcard-only program looks like.
    fn build(
        regs: &[SvmOnEventRegistrationInput],
        indexes: &[i64],
        owned: &[(&str, &str)],
    ) -> (AddressStore, AddressSet, BuiltSelection) {
        let mut entries: Vec<(&str, &[&str])> = Vec::new();
        for reg in regs {
            if !entries.iter().any(|(name, _)| *name == reg.contract_name) {
                entries.push((reg.contract_name.as_str(), &[]));
            }
        }
        // Registered programs replace their empty entry.
        let owned_slices: Vec<[&str; 1]> = owned.iter().map(|(_, id)| [*id]).collect();
        for ((name, _), addresses) in owned.iter().zip(owned_slices.iter()) {
            match entries.iter_mut().find(|(entry, _)| entry == name) {
                Some(entry) => entry.1 = &addresses[..],
                None => entries.push((name, &addresses[..])),
            }
        }
        let store = svm_store(&entries);
        let names: Vec<&str> = entries.iter().map(|(name, _)| *name).collect();
        let set = set_of(&store, &names);
        let built = SelectionBuilder::from_registrations(regs, &store.handle().read().unwrap())
            .unwrap()
            .build(indexes)
            .unwrap();
        (store, set, built)
    }

    fn route_indexes(
        store: &AddressStore,
        set: &AddressSet,
        built: &BuiltSelection,
        instr: &InstructionCall,
    ) -> Vec<i64> {
        let address_store = store.handle();
        let address_store = address_store.read().unwrap();
        let key = instr.executing_account.as_bytes();
        let address = Emitter {
            key,
            owners: set.cache().owners_of(key),
            block: instr.slot as i64,
        };
        route_instruction(
            &built.registrations,
            instr,
            &address,
            &Default::default(),
            &address_store,
        )
        .iter()
        .map(|reg| reg.index)
        .collect()
    }

    #[test]
    fn discriminator_becomes_the_matching_dn_filter() {
        let (_store, _set, built) = build(
            &[
                reg(0, PROG_A, Some("0x21"), false),
                reg(1, PROG_A, Some("0x0102030405060708"), false),
            ],
            &[0, 1],
            &[],
        );
        let views: Vec<(Vec<Address>, Vec<String>, Vec<String>)> = built
            .instruction_selections
            .iter()
            .map(|s| (s.executing_account.clone(), s.d1.clone(), s.d8.clone()))
            .collect();
        let prog_a = PROG_A.parse::<Address>().unwrap();
        assert_eq!(
            views,
            vec![
                (vec![prog_a], vec!["0x21".to_string()], vec![]),
                (vec![prog_a], vec![], vec!["0x0102030405060708".to_string()]),
            ]
        );
    }

    #[test]
    fn account_filter_groups_fan_out_to_separate_selections() {
        let mut input = reg(0, PROG_A, Some("0x0c"), false);
        input.account_filters = vec![
            vec![SvmAccountFilterInput {
                position: 1,
                values: vec![ACCOUNT_1.to_string()],
            }],
            vec![SvmAccountFilterInput {
                position: 2,
                values: vec![ACCOUNT_2.to_string()],
            }],
        ];
        let (_store, _set, built) = build(&[input], &[0], &[]);
        let views: Vec<(Vec<Address>, Vec<Address>)> = built
            .instruction_selections
            .iter()
            .map(|s| (s.a1.clone(), s.a2.clone()))
            .collect();
        assert_eq!(
            views,
            vec![
                (vec![ACCOUNT_1.parse().unwrap()], vec![]),
                (vec![], vec![ACCOUNT_2.parse().unwrap()]),
            ]
        );
    }

    #[test]
    fn every_selection_filters_out_failed_transactions() {
        // The instructions of a failed transaction were rolled back, so they
        // are filtered server-side rather than dropped after the fetch.
        let (_store, _set, built) = build(&[reg(0, PROG_A, Some("0x21"), false)], &[0], &[]);
        assert_eq!(
            built
                .instruction_selections
                .iter()
                .map(|s| s.tx_success)
                .collect::<Vec<_>>(),
            vec![Some(true)]
        );
    }

    #[test]
    fn empty_program_id_emits_no_selection() {
        let (_store, _set, built) = build(&[reg(0, "", Some("0x21"), false)], &[0], &[]);
        assert!(built.instruction_selections.is_empty());
    }

    #[test]
    fn identical_selections_are_deduplicated() {
        let (_store, _set, built) = build(
            &[
                reg(0, PROG_A, Some("0x21"), false),
                reg(1, PROG_A, Some("0x21"), true),
            ],
            &[0, 1],
            &[],
        );
        assert_eq!(built.instruction_selections.len(), 1);
    }

    #[test]
    fn field_unions() {
        let mut a = reg(0, PROG_A, Some("0x21"), false);
        a.transaction_fields = vec!["signature".to_string(), "transactionIndex".to_string()];
        a.block_fields = vec!["height".to_string(), "slot".to_string()];
        a.log_fields = vec!["kind".to_string(), "message".to_string()];
        let mut b = reg(1, PROG_A, Some("0x22"), false);
        b.account_activity_fields = vec!["token.mint".to_string()];
        let (_store, _set, built) = build(&[a, b], &[0, 1], &[]);
        assert_eq!(
            (
                built.block_columns.clone(),
                built.transaction_columns.clone(),
                built.account_activity_columns.clone(),
                built.log_columns.clone(),
                built.instruction_columns.clone(),
            ),
            (
                vec!["slot", "blockhash", "block_time", "block_height"],
                vec!["slot", "transaction_index", "transaction_id"],
                vec!["slot", "transaction_index", "account", "mint"],
                vec![
                    "slot",
                    "transaction_index",
                    "instruction_address",
                    "kind",
                    "message"
                ],
                fields::INSTRUCTION_REQUIRED.to_vec(),
            )
        );
    }

    #[test]
    fn account_activity_without_transaction_fields_fetches_no_transaction_columns() {
        let mut input = reg(0, PROG_A, Some("0x21"), false);
        input.transaction_fields = vec!["transactionIndex".to_string()];
        input.account_activity_fields = vec!["token.mint".to_string(), "lamports.post".to_string()];
        let (_store, _set, built) = build(&[input], &[0], &[]);
        assert_eq!(
            (
                built.transaction_columns.clone(),
                built.account_activity_columns.clone(),
            ),
            (
                vec![],
                vec![
                    "slot",
                    "transaction_index",
                    "account",
                    "mint",
                    "post_balance"
                ],
            )
        );
    }

    #[test]
    fn address_only_account_activity_still_fetches_the_table() {
        let mut input = reg(0, PROG_A, Some("0x21"), false);
        input.account_activity_fields = vec!["address".to_string()];
        let (_store, _set, built) = build(&[input], &[0], &[]);
        assert_eq!(
            built.account_activity_columns,
            vec!["slot", "transaction_index", "account"]
        );
    }

    #[test]
    fn accounts_selection_fetches_account_arguments() {
        let mut input = reg(0, PROG_A, Some("0x21"), false);
        input.instruction_fields = vec!["accounts".to_string()];
        let (_store, _set, built) = build(&[input], &[0], &[]);
        let mut expected = fields::INSTRUCTION_REQUIRED.to_vec();
        expected.push("account_arguments");
        assert_eq!(built.instruction_columns, expected);
    }

    #[test]
    fn account_keys_still_fetch_the_key_list() {
        let mut input = reg(0, PROG_A, Some("0x21"), false);
        input.transaction_fields = vec!["accountKeys".to_string()];
        let (_store, _set, built) = build(&[input], &[0], &[]);
        assert_eq!(
            built.transaction_columns,
            vec!["slot", "transaction_index", "account_keys"]
        );
        assert!(built.account_activity_columns.is_empty());
    }

    #[test]
    fn routes_longest_discriminator_first() {
        // A d1 registration (0x0f) and a d8 registration starting with 0x0f:
        // an instruction carrying the full 8-byte prefix routes to the d8
        // registration only.
        let (store, set, built) = build(
            &[
                reg(0, PROG_A, Some("0x0f"), true),
                reg(1, PROG_A, Some("0x0fffffffffffffff"), true),
            ],
            &[0, 1],
            &[],
        );
        let long = instruction(PROG_A, &[0x0f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
        let short = instruction(PROG_A, &[0x0f, 0x00]);
        assert_eq!(
            (
                route_indexes(&store, &set, &built, &long),
                route_indexes(&store, &set, &built, &short),
            ),
            (vec![1], vec![0])
        );
    }

    #[test]
    fn program_wide_registration_is_the_fallback() {
        let (store, set, built) = build(
            &[
                reg(0, PROG_A, Some("0x21"), true),
                reg(1, PROG_A, None, true),
            ],
            &[0, 1],
            &[],
        );
        let keyed = instruction(PROG_A, &[0x21]);
        let other = instruction(PROG_A, &[0x22]);
        assert_eq!(
            (
                route_indexes(&store, &set, &built, &keyed),
                route_indexes(&store, &set, &built, &other),
            ),
            (vec![0], vec![1])
        );
    }

    #[test]
    fn fans_out_to_wildcard_and_owned_registration() {
        let mut owned = reg(0, PROG_A, Some("0x21"), false);
        owned.contract_name = "Owned".to_string();
        let wildcard = reg(1, PROG_A, Some("0x21"), true);
        let mut other = reg(2, PROG_A, Some("0x21"), false);
        other.contract_name = "Other".to_string();
        let regs = [owned, wildcard, other];
        let instr = instruction(PROG_A, &[0x21]);
        // PROG_A registered for "Owned": its registration plus the wildcard.
        let (store, set, built) = build(&regs, &[0, 1, 2], &[("Owned", PROG_A)]);
        let with_owner = route_indexes(&store, &set, &built, &instr);
        // Nothing registered: the wildcard only — no fallback into
        // program-bound registrations.
        let (store, set, built) = build(&regs, &[0, 1, 2], &[]);
        let without_owner = route_indexes(&store, &set, &built, &instr);
        assert_eq!((with_owner, without_owner), (vec![0, 1], vec![1]));
    }

    #[test]
    fn program_registered_after_the_instruction_slot_is_dropped() {
        // SVM gets the same temporal gate as EVM and Fuel: an instruction from
        // before the program's registration slot never reaches its handler.
        let mut owned = reg(0, PROG_A, Some("0x21"), false);
        owned.contract_name = "Owned".to_string();
        let store = AddressStore::new_svm(vec![crate::address_store::AddressStoreContract {
            name: "Owned".to_string(),
            start_block: None,
            depends_on_addresses: true,
        }])
        .unwrap();
        store.register_seed(vec![crate::address_store::AddressRegistration {
            address: PROG_A.to_string(),
            contract_name: "Owned".to_string(),
            registration_block: 70,
        }]);
        let set = set_of(&store, &["Owned"]);
        let built = SelectionBuilder::from_registrations(
            std::slice::from_ref(&owned),
            &store.handle().read().unwrap(),
        )
        .unwrap()
        .build(&[0])
        .unwrap();
        let at = |slot: u64| {
            let mut instr = instruction(PROG_A, &[0x21]);
            instr.slot = slot;
            route_indexes(&store, &set, &built, &instr)
        };
        assert_eq!((at(69), at(70)), (Vec::<i64>::new(), vec![0]));
    }

    #[test]
    fn registration_start_block_holds_back_only_its_own_registration() {
        // Two registrations of one instruction on one program: one unrestricted,
        // one starting at slot 100. The address store's start block is
        // program-wide, so only this per-registration gate separates them.
        let mut open = reg(0, PROG_A, Some("0x21"), false);
        open.contract_name = "Owned".to_string();
        let mut restricted = reg(1, PROG_A, Some("0x21"), false);
        restricted.contract_name = "Owned".to_string();
        restricted.start_block = Some(100);
        let (store, set, built) = build(&[open, restricted], &[0, 1], &[("Owned", PROG_A)]);
        let at = |slot: u64| {
            let mut instr = instruction(PROG_A, &[0x21]);
            instr.slot = slot;
            route_indexes(&store, &set, &built, &instr)
        };
        assert_eq!((at(99), at(100)), (vec![0], vec![0, 1]));
    }

    #[test]
    fn routing_scoped_to_program() {
        let (store, set, built) = build(
            &[
                reg(0, PROG_A, Some("0x21"), true),
                reg(1, PROG_B, Some("0x21"), true),
            ],
            &[0, 1],
            &[],
        );
        let instr = instruction(PROG_B, &[0x21]);
        assert_eq!(route_indexes(&store, &set, &built, &instr), vec![1]);
    }

    #[test]
    fn account_filters_reapplied_in_routing() {
        let mut filtered = reg(0, PROG_A, Some("0x21"), true);
        filtered.account_filters = vec![vec![SvmAccountFilterInput {
            position: 1,
            values: vec![ACCOUNT_1.to_string()],
        }]];
        let (store, set, built) = build(&[filtered], &[0], &[]);
        let mut matching = instruction(PROG_A, &[0x21]);
        matching.account_arguments = vec![ACCOUNT_2.to_string(), ACCOUNT_1.to_string()];
        let mut rejected = instruction(PROG_A, &[0x21]);
        rejected.account_arguments = vec![ACCOUNT_1.to_string(), ACCOUNT_2.to_string()];
        assert_eq!(
            (
                route_indexes(&store, &set, &built, &matching),
                route_indexes(&store, &set, &built, &rejected),
            ),
            (vec![0], vec![])
        );
    }

    #[test]
    fn is_inner_constraint_reapplied_in_routing() {
        let mut outer_only = reg(0, PROG_A, Some("0x21"), true);
        outer_only.is_inner = Some(false);
        let (store, set, built) = build(&[outer_only], &[0], &[]);
        let outer = instruction(PROG_A, &[0x21]);
        let mut inner = instruction(PROG_A, &[0x21]);
        inner.is_inner = true;
        assert_eq!(
            (
                route_indexes(&store, &set, &built, &outer),
                route_indexes(&store, &set, &built, &inner),
            ),
            (vec![0], vec![])
        );
    }

    #[test]
    fn selection_subset_excludes_other_registrations() {
        let (store, set, built) = build(
            &[
                reg(0, PROG_A, Some("0x21"), true),
                reg(1, PROG_A, Some("0x22"), true),
            ],
            &[1],
            &[],
        );
        let instr = instruction(PROG_A, &[0x21]);
        assert_eq!(
            route_indexes(&store, &set, &built, &instr),
            Vec::<i64>::new()
        );
    }

    #[test]
    fn unknown_registration_index_errors() {
        let store = svm_store(&[]);
        let builder =
            SelectionBuilder::from_registrations(&[], &store.handle().read().unwrap()).unwrap();
        let err = builder.build(&[7]).err().unwrap();
        assert!(format!("{err:#}").contains("Unknown registration index 7"));
    }

    #[test]
    fn discriminator_must_be_1_2_4_or_8_bytes() {
        let store = svm_store(&[(&format!("P_{PROG_A}"), &[])]);
        let err = SelectionBuilder::from_registrations(
            &[reg(0, PROG_A, Some("0x212223"), true)],
            &store.handle().read().unwrap(),
        )
        .err()
        .unwrap();
        assert!(format!("{err:#}").contains("discriminator must be 1/2/4/8 bytes"));
    }
}
