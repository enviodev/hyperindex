use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use hypersync_client_solana::simple_types as simple;
use hypersync_solana_net_types::query as net;
use napi_derive::napi;

use super::mod_helpers::hex_to_bytes;

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
    /// Hex-encoded discriminator. `None` matches every instruction in the
    /// program (lowest routing priority).
    pub discriminator: Option<String>,
    /// Discriminator length in bytes (1/2/4/8); 0 when no discriminator.
    pub discriminator_byte_len: i64,
    /// `None` matches both outer and inner (CPI-invoked) instructions.
    pub is_inner: Option<bool>,
    pub include_logs: bool,
    /// Disjunctive normal form: outer array is OR of AND-groups.
    pub account_filters: Vec<Vec<SvmAccountFilterInput>>,
    /// Selected transaction fields, camelCase (`Internal.svmTransactionField`).
    pub transaction_fields: Vec<String>,
    /// Selected block fields, camelCase (`Internal.svmBlockField`).
    pub block_fields: Vec<String>,
    /// Positional account names from the Borsh schema, in declared order.
    /// Empty (with `args_json` absent) means no schema for this instruction.
    pub accounts: Vec<String>,
    /// Borsh args layout as `Vec<ArgDef>` JSON. Absent means no schema.
    pub args_json: Option<String>,
    /// Program-level nominal-type registry (`BTreeMap<String, ArgType>` JSON),
    /// duplicated on every instruction of the program.
    pub defined_types_json: Option<String>,
}

/// Maps a selected transaction field to the extra query column it needs.
/// `transactionIndex` is always fetched as the store key, and `tokenBalances`
/// lives in a separate table, so neither adds a transaction column.
fn transaction_field_column(field: &str) -> Result<Option<&'static str>> {
    Ok(match field {
        "transactionIndex" | "tokenBalances" => None,
        "signatures" => Some("signatures"),
        "feePayer" => Some("fee_payer"),
        "success" => Some("success"),
        "err" => Some("err"),
        "fee" => Some("fee"),
        "computeUnitsConsumed" => Some("compute_units_consumed"),
        "accountKeys" => Some("account_keys"),
        "recentBlockhash" => Some("recent_blockhash"),
        "version" => Some("version"),
        other => anyhow::bail!("unknown transaction field {other:?}"),
    })
}

/// Maps a selected block field to its query column. slot/time/hash are always
/// fetched (as slot/block_time/blockhash), so they add no extra column.
fn block_field_column(field: &str) -> Result<Option<&'static str>> {
    Ok(match field {
        "slot" | "time" | "hash" => None,
        "height" => Some("block_height"),
        "parentSlot" => Some("parent_slot"),
        "parentHash" => Some("parent_blockhash"),
        other => anyhow::bail!("unknown block field {other:?}"),
    })
}

pub(crate) struct Registration {
    pub index: i64,
    pub contract_name: String,
    pub program_id: String,
    pub is_wildcard: bool,
    /// Decoded discriminator bytes; `None` = program-wide.
    pub discriminator: Option<Vec<u8>>,
    /// Original hex value for the query's `dN` filter.
    pub discriminator_hex: Option<String>,
    pub byte_len: usize,
    pub is_inner: Option<bool>,
    pub include_logs: bool,
    pub account_filters: Vec<Vec<(usize, Vec<String>)>>,
    pub transaction_columns: Vec<&'static str>,
    pub needs_token_balances: bool,
    pub block_columns: Vec<&'static str>,
}

impl Registration {
    fn parse(input: &SvmOnEventRegistrationInput) -> Result<Self> {
        let discriminator = input
            .discriminator
            .as_deref()
            .filter(|d| !d.is_empty())
            .map(|d| hex_to_bytes(d).context("decode discriminator hex"))
            .transpose()?;
        let byte_len = usize::try_from(input.discriminator_byte_len)
            .context("discriminator_byte_len out of range")?;
        if let Some(bytes) = &discriminator {
            anyhow::ensure!(
                matches!(byte_len, 1 | 2 | 4 | 8) && bytes.len() == byte_len,
                "discriminator byte length must be 1/2/4/8 and match the value, got {} bytes declared as {}",
                bytes.len(),
                byte_len,
            );
        }
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
        let mut transaction_columns = Vec::new();
        let mut needs_token_balances = false;
        for field in &input.transaction_fields {
            if field == "tokenBalances" {
                needs_token_balances = true;
            }
            if let Some(column) = transaction_field_column(field)? {
                if !transaction_columns.contains(&column) {
                    transaction_columns.push(column);
                }
            }
        }
        let mut block_columns = Vec::new();
        for field in &input.block_fields {
            if let Some(column) = block_field_column(field)? {
                if !block_columns.contains(&column) {
                    block_columns.push(column);
                }
            }
        }
        Ok(Self {
            index: input.index,
            contract_name: input.contract_name.clone(),
            program_id: input.program_id.clone(),
            is_wildcard: input.is_wildcard,
            discriminator,
            discriminator_hex: input.discriminator.clone().filter(|d| !d.is_empty()),
            byte_len,
            is_inner: input.is_inner,
            include_logs: input.include_logs,
            account_filters,
            transaction_columns,
            needs_token_balances,
            block_columns,
        })
    }

    /// Whether an instruction belongs to this registration, discriminator
    /// aside: same program, an allowed owner (wildcard registrations accept
    /// any program address, program-bound ones only their own contract), the
    /// `isInner` constraint, and the registration's account filters — the
    /// filters are re-applied here so an instruction fetched for a sibling
    /// selection can't leak into a registration whose own filter rejects it.
    fn matches_scope(&self, instr: &simple::Instruction, contract_name: Option<&str>) -> bool {
        self.program_id == instr.program_id
            && (self.is_wildcard || contract_name == Some(self.contract_name.as_str()))
            && self
                .is_inner
                .is_none_or(|is_inner| is_inner == instr.is_inner)
            && (self.account_filters.is_empty()
                || self.account_filters.iter().any(|group| {
                    group.iter().all(|(position, values)| {
                        instr
                            .accounts
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
    fn into_net(self) -> net::InstructionSelection {
        let mut selection = net::InstructionSelection {
            program_id: vec![self.program_id],
            is_inner: self.is_inner,
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
        selection.a0 = a0.unwrap_or_default();
        selection.a1 = a1.unwrap_or_default();
        selection.a2 = a2.unwrap_or_default();
        selection.a3 = a3.unwrap_or_default();
        selection.a4 = a4.unwrap_or_default();
        selection.a5 = a5.unwrap_or_default();
        selection.a6 = a6.unwrap_or_default();
        selection.a7 = a7.unwrap_or_default();
        selection.a8 = a8.unwrap_or_default();
        selection.a9 = a9.unwrap_or_default();
        selection
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
    pub needs_token_balances: bool,
    pub needs_logs: bool,
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
    ) -> Result<Self> {
        let mut map = HashMap::new();
        for reg in registrations {
            let parsed = Registration::parse(reg)
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
        let mut block_columns = vec!["slot", "blockhash", "block_time"];
        let mut transaction_columns: Vec<&'static str> = Vec::new();
        let mut needs_token_balances = false;
        let mut needs_logs = false;
        let mut registrations = Vec::with_capacity(registration_indexes.len());

        for id in registration_indexes {
            let reg = self
                .registrations
                .get(id)
                .with_context(|| format!("Unknown registration index {id} in query selection"))?;
            registrations.push(reg.clone());

            for &column in &reg.block_columns {
                if !block_columns.contains(&column) {
                    block_columns.push(column);
                }
            }
            for &column in &reg.transaction_columns {
                if !transaction_columns.contains(&column) {
                    transaction_columns.push(column);
                }
            }
            needs_token_balances = needs_token_balances || reg.needs_token_balances;
            needs_logs = needs_logs || reg.include_logs;

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
        // The transaction table is fetched only when a selected field is read
        // off a stored transaction record; the store key columns ride along.
        if !transaction_columns.is_empty() {
            transaction_columns.splice(0..0, ["slot", "transaction_index"]);
        }
        // Deterministic item order per instruction, independent of the
        // selection's index order.
        registrations.sort_unstable_by_key(|reg| reg.index);

        Ok(BuiltSelection {
            instruction_selections: selections
                .into_iter()
                .map(BuiltInstructionSelection::into_net)
                .collect(),
            block_columns,
            transaction_columns,
            needs_token_balances,
            needs_logs,
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
    instr: &simple::Instruction,
    contract_name: Option<&str>,
) -> Vec<Arc<Registration>> {
    for byte_len in [8usize, 4, 2, 1] {
        let matched: Vec<Arc<Registration>> = registrations
            .iter()
            .filter(|reg| {
                reg.byte_len == byte_len
                    && reg.matches_discriminator(&instr.data)
                    && reg.matches_scope(instr, contract_name)
            })
            .cloned()
            .collect();
        if !matched.is_empty() {
            return matched;
        }
    }
    registrations
        .iter()
        .filter(|reg| reg.discriminator.is_none() && reg.matches_scope(instr, contract_name))
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROG_A: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";
    const PROG_B: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
    const ACCOUNT_1: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    const ACCOUNT_2: &str = "So11111111111111111111111111111111111111112";

    fn reg(
        index: i64,
        program_id: &str,
        discriminator: Option<&str>,
        byte_len: i64,
        is_wildcard: bool,
    ) -> SvmOnEventRegistrationInput {
        SvmOnEventRegistrationInput {
            index,
            instruction_name: format!("I{index}"),
            contract_name: format!("P_{program_id}"),
            program_id: program_id.to_string(),
            is_wildcard,
            discriminator: discriminator.map(str::to_string),
            discriminator_byte_len: byte_len,
            is_inner: None,
            include_logs: false,
            account_filters: vec![],
            transaction_fields: vec![],
            block_fields: vec![],
            accounts: vec![],
            args_json: None,
            defined_types_json: None,
        }
    }

    fn instruction(program_id: &str, data: &[u8]) -> simple::Instruction {
        simple::Instruction {
            program_id: program_id.to_string(),
            data: data.to_vec(),
            is_committed: true,
            ..Default::default()
        }
    }

    fn route_indexes(
        built: &BuiltSelection,
        instr: &simple::Instruction,
        contract_name: Option<&str>,
    ) -> Vec<i64> {
        route_instruction(&built.registrations, instr, contract_name)
            .iter()
            .map(|reg| reg.index)
            .collect()
    }

    #[test]
    fn discriminator_becomes_the_matching_dn_filter() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, PROG_A, Some("0x21"), 1, false),
            reg(1, PROG_A, Some("0x0102030405060708"), 8, false),
        ])
        .unwrap();
        let built = builder.build(&[0, 1]).unwrap();
        let views: Vec<(Vec<String>, Vec<String>, Vec<String>)> = built
            .instruction_selections
            .iter()
            .map(|s| (s.program_id.clone(), s.d1.clone(), s.d8.clone()))
            .collect();
        assert_eq!(
            views,
            vec![
                (vec![PROG_A.to_string()], vec!["0x21".to_string()], vec![]),
                (
                    vec![PROG_A.to_string()],
                    vec![],
                    vec!["0x0102030405060708".to_string()]
                ),
            ]
        );
    }

    #[test]
    fn account_filter_groups_fan_out_to_separate_selections() {
        let mut input = reg(0, PROG_A, Some("0x0c"), 1, false);
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
        let builder = SelectionBuilder::from_registrations(&[input]).unwrap();
        let built = builder.build(&[0]).unwrap();
        let views: Vec<(Vec<String>, Vec<String>)> = built
            .instruction_selections
            .iter()
            .map(|s| (s.a1.clone(), s.a2.clone()))
            .collect();
        assert_eq!(
            views,
            vec![
                (vec![ACCOUNT_1.to_string()], vec![]),
                (vec![], vec![ACCOUNT_2.to_string()]),
            ]
        );
    }

    #[test]
    fn empty_program_id_emits_no_selection() {
        let builder =
            SelectionBuilder::from_registrations(&[reg(0, "", Some("0x21"), 1, false)]).unwrap();
        let built = builder.build(&[0]).unwrap();
        assert!(built.instruction_selections.is_empty());
    }

    #[test]
    fn identical_selections_are_deduplicated() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, PROG_A, Some("0x21"), 1, false),
            reg(1, PROG_A, Some("0x21"), 1, true),
        ])
        .unwrap();
        let built = builder.build(&[0, 1]).unwrap();
        assert_eq!(built.instruction_selections.len(), 1);
    }

    #[test]
    fn field_unions_and_flags() {
        let mut a = reg(0, PROG_A, Some("0x21"), 1, false);
        a.transaction_fields = vec!["signatures".to_string(), "transactionIndex".to_string()];
        a.block_fields = vec!["height".to_string(), "slot".to_string()];
        a.include_logs = true;
        let mut b = reg(1, PROG_A, Some("0x22"), 1, false);
        b.transaction_fields = vec!["tokenBalances".to_string()];
        let builder = SelectionBuilder::from_registrations(&[a, b]).unwrap();
        let built = builder.build(&[0, 1]).unwrap();
        assert_eq!(
            (
                built.block_columns.clone(),
                built.transaction_columns.clone(),
                built.needs_token_balances,
                built.needs_logs,
            ),
            (
                vec!["slot", "blockhash", "block_time", "block_height"],
                vec!["slot", "transaction_index", "signatures"],
                true,
                true,
            )
        );
    }

    #[test]
    fn token_balances_or_transaction_index_alone_fetch_no_transaction_columns() {
        let mut input = reg(0, PROG_A, Some("0x21"), 1, false);
        input.transaction_fields =
            vec!["transactionIndex".to_string(), "tokenBalances".to_string()];
        let builder = SelectionBuilder::from_registrations(&[input]).unwrap();
        let built = builder.build(&[0]).unwrap();
        assert_eq!(
            (
                built.transaction_columns.clone(),
                built.needs_token_balances
            ),
            (vec![], true)
        );
    }

    #[test]
    fn routes_longest_discriminator_first() {
        // A d1 registration (0x0f) and a d8 registration starting with 0x0f:
        // an instruction carrying the full 8-byte prefix routes to the d8
        // registration only.
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, PROG_A, Some("0x0f"), 1, true),
            reg(1, PROG_A, Some("0x0fffffffffffffff"), 8, true),
        ])
        .unwrap();
        let built = builder.build(&[0, 1]).unwrap();
        let long = instruction(PROG_A, &[0x0f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
        let short = instruction(PROG_A, &[0x0f, 0x00]);
        assert_eq!(
            (
                route_indexes(&built, &long, None),
                route_indexes(&built, &short, None),
            ),
            (vec![1], vec![0])
        );
    }

    #[test]
    fn program_wide_registration_is_the_fallback() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, PROG_A, Some("0x21"), 1, true),
            reg(1, PROG_A, None, 0, true),
        ])
        .unwrap();
        let built = builder.build(&[0, 1]).unwrap();
        let keyed = instruction(PROG_A, &[0x21]);
        let other = instruction(PROG_A, &[0x22]);
        assert_eq!(
            (
                route_indexes(&built, &keyed, None),
                route_indexes(&built, &other, None),
            ),
            (vec![0], vec![1])
        );
    }

    #[test]
    fn fans_out_to_wildcard_and_owned_registration() {
        let mut owned = reg(0, PROG_A, Some("0x21"), 1, false);
        owned.contract_name = "Owned".to_string();
        let wildcard = reg(1, PROG_A, Some("0x21"), 1, true);
        let mut other = reg(2, PROG_A, Some("0x21"), 1, false);
        other.contract_name = "Other".to_string();
        let builder = SelectionBuilder::from_registrations(&[owned, wildcard, other]).unwrap();
        let built = builder.build(&[0, 1, 2]).unwrap();
        let instr = instruction(PROG_A, &[0x21]);
        assert_eq!(
            (
                route_indexes(&built, &instr, Some("Owned")),
                route_indexes(&built, &instr, None),
            ),
            (vec![0, 1], vec![1])
        );
    }

    #[test]
    fn routing_scoped_to_program() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, PROG_A, Some("0x21"), 1, true),
            reg(1, PROG_B, Some("0x21"), 1, true),
        ])
        .unwrap();
        let built = builder.build(&[0, 1]).unwrap();
        let instr = instruction(PROG_B, &[0x21]);
        assert_eq!(route_indexes(&built, &instr, None), vec![1]);
    }

    #[test]
    fn account_filters_reapplied_in_routing() {
        let mut filtered = reg(0, PROG_A, Some("0x21"), 1, true);
        filtered.account_filters = vec![vec![SvmAccountFilterInput {
            position: 1,
            values: vec![ACCOUNT_1.to_string()],
        }]];
        let builder = SelectionBuilder::from_registrations(&[filtered]).unwrap();
        let built = builder.build(&[0]).unwrap();
        let mut matching = instruction(PROG_A, &[0x21]);
        matching.accounts = vec![ACCOUNT_2.to_string(), ACCOUNT_1.to_string()];
        let mut rejected = instruction(PROG_A, &[0x21]);
        rejected.accounts = vec![ACCOUNT_1.to_string(), ACCOUNT_2.to_string()];
        assert_eq!(
            (
                route_indexes(&built, &matching, None),
                route_indexes(&built, &rejected, None),
            ),
            (vec![0], vec![])
        );
    }

    #[test]
    fn is_inner_constraint_reapplied_in_routing() {
        let mut outer_only = reg(0, PROG_A, Some("0x21"), 1, true);
        outer_only.is_inner = Some(false);
        let builder = SelectionBuilder::from_registrations(&[outer_only]).unwrap();
        let built = builder.build(&[0]).unwrap();
        let outer = instruction(PROG_A, &[0x21]);
        let mut inner = instruction(PROG_A, &[0x21]);
        inner.is_inner = true;
        assert_eq!(
            (
                route_indexes(&built, &outer, None),
                route_indexes(&built, &inner, None),
            ),
            (vec![0], vec![])
        );
    }

    #[test]
    fn selection_subset_excludes_other_registrations() {
        let builder = SelectionBuilder::from_registrations(&[
            reg(0, PROG_A, Some("0x21"), 1, true),
            reg(1, PROG_A, Some("0x22"), 1, true),
        ])
        .unwrap();
        let built = builder.build(&[1]).unwrap();
        let instr = instruction(PROG_A, &[0x21]);
        assert_eq!(route_indexes(&built, &instr, None), Vec::<i64>::new());
    }

    #[test]
    fn unknown_registration_index_errors() {
        let builder = SelectionBuilder::from_registrations(&[]).unwrap();
        let err = builder.build(&[7]).err().unwrap();
        assert!(format!("{err:#}").contains("Unknown registration index 7"));
    }

    #[test]
    fn mismatched_discriminator_byte_len_errors() {
        let err = SelectionBuilder::from_registrations(&[reg(0, PROG_A, Some("0x2122"), 1, true)])
            .err()
            .unwrap();
        assert!(format!("{err:#}").contains("discriminator byte length"));
    }
}
