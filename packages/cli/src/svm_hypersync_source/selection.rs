use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{Context, Result};
use hypersync_client_solana::simple_types as simple;
use hypersync_solana_net_types::query as net;
use hypersync_solana_net_types::types::Address;
use napi_derive::napi;

use super::borsh_decoder::{parse_defined_types, ArgsSchema};
use super::fields;
use super::mod_helpers::hex_to_bytes;
use super::types::required;
use crate::address_store::{Emitter, StoreInner};
use crate::config_parsing::human_config::svm::ArgDef;
use crate::hex::to_hex;

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

/// One `onInstruction`/`contractRegister` binding of a config instruction on a
/// chain: the handler-specific routing state and what the fetch state queries
/// are built from.
#[napi(object)]
#[derive(Clone)]
pub struct SvmOnEventRegistrationInput {
    /// Chain-scoped sequential registration index; returned on every routed
    /// item so JS resolves the registration by array index.
    pub index: i64,
    pub is_wildcard: bool,
    /// Earliest slot this registration accepts; absent is unrestricted. See
    /// `crate::registration_start_block`.
    pub start_block: Option<i64>,
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
}

/// One config instruction: its identity and Borsh layout, shared by every
/// registration bound to it.
#[napi(object)]
#[derive(Clone)]
pub struct SvmInstructionInput {
    pub name: String,
    /// Hex-encoded instruction-data prefix of any length. Absent or empty
    /// matches every instruction of the program.
    pub discriminator: Option<String>,
    /// Borsh args layout as `Vec<ArgDef>` JSON. Absent means the instruction
    /// declares no args, so none of its registrations may select them.
    pub args_json: Option<String>,
    pub registrations: Vec<SvmOnEventRegistrationInput>,
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmProgramInput {
    /// The config's program name.
    pub name: String,
    /// Base58 program id. Empty means the config carries no real program
    /// (placeholder); such a program is never fetched or routed.
    pub program_id: String,
    /// Program-level nominal-type registry (`BTreeMap<String, ArgType>` JSON).
    pub defined_types_json: Option<String>,
    pub instructions: Vec<SvmInstructionInput>,
}

pub(crate) struct Registration {
    pub index: i64,
    pub is_wildcard: bool,
    /// Earliest slot this registration accepts; `None` is unrestricted.
    pub start_block: Option<i64>,
    pub is_inner: Option<bool>,
    pub account_filters: Vec<Vec<(usize, Vec<String>)>>,
    pub transaction_columns: Vec<&'static str>,
    pub account_activity_columns: Vec<&'static str>,
    pub block_columns: Vec<&'static str>,
    pub log_columns: Vec<&'static str>,
    pub instruction_columns: Vec<&'static str>,
    /// Stored at parse because `args` is not a query column, so it cannot be
    /// recovered from `instruction_columns`.
    pub selects_args: bool,
}

impl Registration {
    fn parse(
        input: &SvmOnEventRegistrationInput,
        instruction: &SvmInstructionInput,
    ) -> Result<Self> {
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
        if selects_args {
            instruction.args_json.as_ref().with_context(|| {
                format!(
                    "registration {} selects `args` but instruction {} declares none",
                    input.index, instruction.name
                )
            })?;
        }
        Ok(Self {
            index: input.index,
            is_wildcard: input.is_wildcard,
            start_block: input.start_block,
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
    /// aside: at or after the registration's own start block, an allowed
    /// owner, the `isInner` constraint, and the registration's account filters
    /// — the filters are re-applied here so an instruction fetched for a
    /// sibling selection can't leak into a registration whose own filter
    /// rejects it.
    ///
    /// Owner rules mirror EVM's: a wildcard registration accepts any program
    /// address; a program-bound one needs the address to be in this partition's
    /// set for its own contract (or, when the contract is client-filtered, only
    /// in the store) and registered at or before the instruction's slot.
    fn matches_scope(
        &self,
        instruction: &Instruction,
        instr: &InstructionCall,
        address: &Emitter,
        force_wildcard: bool,
        store: &StoreInner,
    ) -> bool {
        address.matches_registration(
            store,
            instruction.contract_idx,
            self.is_wildcard,
            self.start_block,
            force_wildcard,
        ) && self
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
}

/// One config instruction of a program.
pub(crate) struct Instruction {
    pub contract_name: String,
    /// This program in the chain's address store, resolved once at
    /// construction so the per-instruction gate is an index compare.
    pub contract_idx: u32,
    pub program_id: String,
    /// The data prefix this instruction claims; empty claims every
    /// instruction of the program.
    pub prefix: Vec<u8>,
    /// Declared Borsh layout, independent of whether any registration selected
    /// `args`.
    pub args: Option<Arc<ArgsSchema>>,
}

impl Instruction {
    fn matches(&self, instr: &InstructionCall) -> bool {
        self.program_id == instr.executing_account && instr.data.starts_with(&self.prefix)
    }

    /// The longest `dN` the wire can filter on inside the prefix. Routing
    /// compares the whole prefix, so a longer or odd-length prefix over-fetches
    /// by at most the bytes the wire cannot see.
    fn wire_prefix(&self) -> &[u8] {
        let len = [8, 4, 2, 1]
            .into_iter()
            .find(|len| self.prefix.len() >= *len)
            .unwrap_or(0);
        &self.prefix[..len]
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
    /// 0, 1, 2, 4 or 8 bytes — see `Instruction::wire_prefix`.
    prefix: Vec<u8>,
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
        let d = to_hex(&self.prefix);
        match self.prefix.len() {
            0 => {}
            1 => selection.d1 = vec![d],
            2 => selection.d2 = vec![d],
            4 => selection.d4 = vec![d],
            8 => selection.d8 = vec![d],
            len => anyhow::bail!("wire prefix of {len} bytes"),
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

/// An instruction with the subset of its registrations a query selected.
pub(crate) struct SelectedInstruction {
    pub instruction: Arc<Instruction>,
    pub registrations: Vec<Arc<Registration>>,
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
    /// The instructions the selection's registrations belong to, each with
    /// those registrations, for routing.
    pub instructions: Vec<SelectedInstruction>,
}

/// Builds per-query instruction selections and field unions from the programs
/// passed at client construction, and routes returned instructions back to
/// their registrations.
pub(crate) struct SelectionBuilder {
    instructions: Vec<Arc<Instruction>>,
    /// Registration index → (position in `instructions`, registration).
    registrations: HashMap<i64, (usize, Arc<Registration>)>,
}

impl SelectionBuilder {
    pub(crate) fn from_programs(programs: &[SvmProgramInput], store: &StoreInner) -> Result<Self> {
        let mut instructions = Vec::new();
        let mut registrations = HashMap::new();
        for program in programs {
            let contract_idx = store.contract_idx(&program.name).with_context(|| {
                format!(
                    "Program {} is missing from the chain's address store",
                    program.name
                )
            })?;
            let defined_types = Arc::new(
                parse_defined_types(program.defined_types_json.as_deref())
                    .with_context(|| format!("parse defined types for {}", program.name))?,
            );
            for input in &program.instructions {
                let prefix = match input.discriminator.as_deref() {
                    Some(hex) if !hex.is_empty() => {
                        hex_to_bytes(hex).context("decode discriminator hex")?
                    }
                    _ => Vec::new(),
                };
                let args = input
                    .args_json
                    .as_deref()
                    .map(|json| -> Result<Arc<ArgsSchema>> {
                        let args: Vec<ArgDef> =
                            serde_json::from_str(json).context("parse args schema")?;
                        Ok(Arc::new(ArgsSchema::new(
                            prefix.len(),
                            &args,
                            Arc::clone(&defined_types),
                        )?))
                    })
                    .transpose()
                    .with_context(|| format!("instruction {}", input.name))?;
                let position = instructions.len();
                let parsed = input
                    .registrations
                    .iter()
                    .map(|reg| {
                        let parsed = Registration::parse(reg, input)
                            .with_context(|| format!("parse registration for {}", input.name))?;
                        Ok(Arc::new(parsed))
                    })
                    .collect::<Result<Vec<_>>>()?;
                for reg in &parsed {
                    anyhow::ensure!(
                        registrations
                            .insert(reg.index, (position, Arc::clone(reg)))
                            .is_none(),
                        "Duplicate registration index {} for instruction {}",
                        reg.index,
                        input.name,
                    );
                }
                instructions.push(Arc::new(Instruction {
                    contract_name: program.name.clone(),
                    contract_idx,
                    program_id: program.program_id.clone(),
                    prefix,
                    args,
                }));
            }
        }
        Ok(Self {
            instructions,
            registrations,
        })
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
        let mut selected: Vec<Option<SelectedInstruction>> =
            (0..self.instructions.len()).map(|_| None).collect();

        for id in registration_indexes {
            let (position, reg) = self
                .registrations
                .get(id)
                .with_context(|| format!("Unknown registration index {id} in query selection"))?;
            let instruction = &self.instructions[*position];
            selected[*position]
                .get_or_insert_with(|| SelectedInstruction {
                    instruction: Arc::clone(instruction),
                    registrations: Vec::new(),
                })
                .registrations
                .push(Arc::clone(reg));

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
            if instruction.program_id.is_empty() {
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
                    program_id: instruction.program_id.clone(),
                    prefix: instruction.wire_prefix().to_vec(),
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
        let mut instructions: Vec<SelectedInstruction> = selected.into_iter().flatten().collect();
        // Deterministic item order per instruction, independent of the
        // selection's index order.
        for selected in &mut instructions {
            selected.registrations.sort_unstable_by_key(|reg| reg.index);
        }

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
            instructions,
        })
    }
}

/// Routes an instruction call to every selected instruction whose prefix it
/// carries — a program-wide one alongside a keyed one, or a 1-byte family
/// alongside its 2-byte member — and within each to the registrations whose
/// scope accepts it. Instructions no registration accepted are omitted.
pub(crate) fn route_instruction<'a>(
    instructions: &'a [SelectedInstruction],
    instr: &InstructionCall,
    address: &Emitter,
    client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
    store: &StoreInner,
) -> Vec<(&'a Arc<Instruction>, Vec<&'a Arc<Registration>>)> {
    instructions
        .iter()
        .filter(|selected| selected.instruction.matches(instr))
        .filter_map(|selected| {
            let instruction = &selected.instruction;
            let force_wildcard = client_filtered.applies(&instruction.contract_name);
            let registrations: Vec<&Arc<Registration>> = selected
                .registrations
                .iter()
                .filter(|reg| reg.matches_scope(instruction, instr, address, force_wildcard, store))
                .collect();
            (!registrations.is_empty()).then_some((instruction, registrations))
        })
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

    fn reg(index: i64, is_wildcard: bool) -> SvmOnEventRegistrationInput {
        SvmOnEventRegistrationInput {
            index,
            is_wildcard,
            start_block: None,
            is_inner: None,
            account_filters: vec![],
            transaction_fields: vec![],
            block_fields: vec![],
            account_activity_fields: vec![],
            log_fields: vec![],
            instruction_fields: vec![],
        }
    }

    fn ix(
        discriminator: Option<&str>,
        registrations: Vec<SvmOnEventRegistrationInput>,
    ) -> SvmInstructionInput {
        SvmInstructionInput {
            name: format!(
                "I{}",
                registrations
                    .iter()
                    .map(|reg| reg.index.to_string())
                    .collect::<Vec<_>>()
                    .join("_")
            ),
            discriminator: discriminator.map(str::to_string),
            args_json: None,
            registrations,
        }
    }

    fn program(program_id: &str, instructions: Vec<SvmInstructionInput>) -> SvmProgramInput {
        program_named(&format!("P_{program_id}"), program_id, instructions)
    }

    fn program_named(
        name: &str,
        program_id: &str,
        instructions: Vec<SvmInstructionInput>,
    ) -> SvmProgramInput {
        SvmProgramInput {
            name: name.to_string(),
            program_id: program_id.to_string(),
            defined_types_json: None,
            instructions,
        }
    }

    /// One registration under one keyed instruction of one program.
    fn single(
        index: i64,
        program_id: &str,
        discriminator: Option<&str>,
        is_wildcard: bool,
    ) -> SvmProgramInput {
        program(
            program_id,
            vec![ix(discriminator, vec![reg(index, is_wildcard)])],
        )
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
        programs: &[SvmProgramInput],
        indexes: &[i64],
        owned: &[(&str, &str)],
    ) -> (AddressStore, AddressSet, BuiltSelection) {
        let mut entries: Vec<(&str, &[&str])> = Vec::new();
        for program in programs {
            if !entries.iter().any(|(name, _)| *name == program.name) {
                entries.push((program.name.as_str(), &[]));
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
        let built = SelectionBuilder::from_programs(programs, &store.handle().read().unwrap())
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
            &built.instructions,
            instr,
            &address,
            &Default::default(),
            &address_store,
        )
        .iter()
        .flat_map(|(_, registrations)| registrations.iter().map(|reg| reg.index))
        .collect()
    }

    fn dn_views(
        built: &BuiltSelection,
    ) -> Vec<(Vec<String>, Vec<String>, Vec<String>, Vec<String>)> {
        built
            .instruction_selections
            .iter()
            .map(|s| (s.d1.clone(), s.d2.clone(), s.d4.clone(), s.d8.clone()))
            .collect()
    }

    #[test]
    fn discriminator_becomes_the_matching_dn_filter() {
        let (_store, _set, built) = build(
            &[program(
                PROG_A,
                vec![
                    ix(Some("0x21"), vec![reg(0, false)]),
                    ix(Some("0x0102030405060708"), vec![reg(1, false)]),
                ],
            )],
            &[0, 1],
            &[],
        );
        let prog_a = PROG_A.parse::<Address>().unwrap();
        assert_eq!(
            (
                built
                    .instruction_selections
                    .iter()
                    .map(|s| s.executing_account.clone())
                    .collect::<Vec<_>>(),
                dn_views(&built)
            ),
            (
                vec![vec![prog_a], vec![prog_a]],
                vec![
                    (vec!["0x21".to_string()], vec![], vec![], vec![]),
                    (
                        vec![],
                        vec![],
                        vec![],
                        vec!["0x0102030405060708".to_string()]
                    ),
                ]
            )
        );
    }

    // Serum v3 dispatches on a version byte plus a 4-byte tag. The wire can
    // filter on the first four of those five bytes; routing checks all five.
    #[test]
    fn a_prefix_the_wire_cannot_express_filters_on_its_longest_dn_and_routes_on_all_of_it() {
        let (store, set, built) =
            build(&[single(0, PROG_A, Some("0x000a000000"), true)], &[0], &[]);
        let full = instruction(PROG_A, &[0x00, 0x0a, 0x00, 0x00, 0x00, 0x01]);
        let fifth_byte_differs = instruction(PROG_A, &[0x00, 0x0a, 0x00, 0x00, 0x01]);
        assert_eq!(
            (
                dn_views(&built),
                route_indexes(&store, &set, &built, &full),
                route_indexes(&store, &set, &built, &fifth_byte_differs),
            ),
            (
                vec![(vec![], vec![], vec!["0x000a0000".to_string()], vec![])],
                vec![0],
                vec![]
            )
        );
    }

    #[test]
    fn a_program_wide_instruction_sends_no_dn_filter() {
        let (_store, _set, built) = build(&[single(0, PROG_A, None, true)], &[0], &[]);
        assert_eq!(dn_views(&built), vec![(vec![], vec![], vec![], vec![])]);
    }

    #[test]
    fn account_filter_groups_fan_out_to_separate_selections() {
        let mut input = reg(0, false);
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
        let (_store, _set, built) = build(
            &[program(PROG_A, vec![ix(Some("0x0c"), vec![input])])],
            &[0],
            &[],
        );
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
        let (_store, _set, built) = build(&[single(0, PROG_A, Some("0x21"), false)], &[0], &[]);
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
        let (_store, _set, built) = build(&[single(0, "", Some("0x21"), false)], &[0], &[]);
        assert!(built.instruction_selections.is_empty());
    }

    #[test]
    fn identical_selections_are_deduplicated() {
        let (_store, _set, built) = build(
            &[program(
                PROG_A,
                vec![ix(Some("0x21"), vec![reg(0, false), reg(1, true)])],
            )],
            &[0, 1],
            &[],
        );
        assert_eq!(built.instruction_selections.len(), 1);
    }

    #[test]
    fn field_unions() {
        let mut a = reg(0, false);
        a.transaction_fields = vec!["signature".to_string(), "transactionIndex".to_string()];
        a.block_fields = vec!["height".to_string(), "slot".to_string()];
        a.log_fields = vec!["kind".to_string(), "message".to_string()];
        let mut b = reg(1, false);
        b.account_activity_fields = vec!["token.mint".to_string()];
        let (_store, _set, built) = build(
            &[program(
                PROG_A,
                vec![ix(Some("0x21"), vec![a]), ix(Some("0x22"), vec![b])],
            )],
            &[0, 1],
            &[],
        );
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
        let mut input = reg(0, false);
        input.transaction_fields = vec!["transactionIndex".to_string()];
        input.account_activity_fields = vec!["token.mint".to_string(), "lamports.post".to_string()];
        let (_store, _set, built) = build(
            &[program(PROG_A, vec![ix(Some("0x21"), vec![input])])],
            &[0],
            &[],
        );
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
        let mut input = reg(0, false);
        input.account_activity_fields = vec!["address".to_string()];
        let (_store, _set, built) = build(
            &[program(PROG_A, vec![ix(Some("0x21"), vec![input])])],
            &[0],
            &[],
        );
        assert_eq!(
            built.account_activity_columns,
            vec!["slot", "transaction_index", "account"]
        );
    }

    #[test]
    fn accounts_selection_fetches_account_arguments() {
        let mut input = reg(0, false);
        input.instruction_fields = vec!["accounts".to_string()];
        let (_store, _set, built) = build(
            &[program(PROG_A, vec![ix(Some("0x21"), vec![input])])],
            &[0],
            &[],
        );
        let mut expected = fields::INSTRUCTION_REQUIRED.to_vec();
        expected.push("account_arguments");
        assert_eq!(built.instruction_columns, expected);
    }

    #[test]
    fn account_keys_still_fetch_the_key_list() {
        let mut input = reg(0, false);
        input.transaction_fields = vec!["accountKeys".to_string()];
        let (_store, _set, built) = build(
            &[program(PROG_A, vec![ix(Some("0x21"), vec![input])])],
            &[0],
            &[],
        );
        assert_eq!(
            built.transaction_columns,
            vec!["slot", "transaction_index", "account_keys"]
        );
        assert!(built.account_activity_columns.is_empty());
    }

    // Token-2022 shape: a 1-byte extension family and its 2-byte members. A
    // call carrying the longer prefix carries the shorter one too, so both
    // instructions receive it.
    #[test]
    fn a_call_routes_to_every_instruction_whose_prefix_it_carries() {
        let (store, set, built) = build(
            &[program(
                PROG_A,
                vec![
                    ix(Some("0x1a"), vec![reg(0, true)]),
                    ix(Some("0x1a00"), vec![reg(1, true)]),
                    ix(None, vec![reg(2, true)]),
                ],
            )],
            &[0, 1, 2],
            &[],
        );
        let member = instruction(PROG_A, &[0x1a, 0x00, 0xff]);
        let family_only = instruction(PROG_A, &[0x1a, 0x01]);
        let unrelated = instruction(PROG_A, &[0x22]);
        assert_eq!(
            (
                route_indexes(&store, &set, &built, &member),
                route_indexes(&store, &set, &built, &family_only),
                route_indexes(&store, &set, &built, &unrelated),
            ),
            (vec![0, 1, 2], vec![0, 2], vec![2])
        );
    }

    #[test]
    fn instructions_sharing_a_prefix_both_receive_the_call() {
        let (store, set, built) = build(
            &[program(
                PROG_A,
                vec![
                    ix(Some("0x09"), vec![reg(0, true)]),
                    ix(Some("0x09"), vec![reg(1, true)]),
                ],
            )],
            &[0, 1],
            &[],
        );
        let instr = instruction(PROG_A, &[0x09, 0x01]);
        assert_eq!(route_indexes(&store, &set, &built, &instr), vec![0, 1]);
    }

    #[test]
    fn fans_out_to_wildcard_and_owned_registration() {
        let programs = [
            program_named("Owned", PROG_A, vec![ix(Some("0x21"), vec![reg(0, false)])]),
            program(PROG_A, vec![ix(Some("0x21"), vec![reg(1, true)])]),
            program_named("Other", PROG_A, vec![ix(Some("0x21"), vec![reg(2, false)])]),
        ];
        let instr = instruction(PROG_A, &[0x21]);
        // PROG_A registered for "Owned": its registration plus the wildcard.
        let (store, set, built) = build(&programs, &[0, 1, 2], &[("Owned", PROG_A)]);
        let with_owner = route_indexes(&store, &set, &built, &instr);
        // Nothing registered: the wildcard only — no fallback into
        // program-bound registrations.
        let (store, set, built) = build(&programs, &[0, 1, 2], &[]);
        let without_owner = route_indexes(&store, &set, &built, &instr);
        assert_eq!((with_owner, without_owner), (vec![0, 1], vec![1]));
    }

    #[test]
    fn program_registered_after_the_instruction_slot_is_dropped() {
        // SVM gets the same temporal gate as EVM and Fuel: an instruction from
        // before the program's registration slot never reaches its handler.
        let owned = program_named("Owned", PROG_A, vec![ix(Some("0x21"), vec![reg(0, false)])]);
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
        let built = SelectionBuilder::from_programs(
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
        let mut restricted = reg(1, false);
        restricted.start_block = Some(100);
        let (store, set, built) = build(
            &[program_named(
                "Owned",
                PROG_A,
                vec![ix(Some("0x21"), vec![reg(0, false), restricted])],
            )],
            &[0, 1],
            &[("Owned", PROG_A)],
        );
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
                single(0, PROG_A, Some("0x21"), true),
                single(1, PROG_B, Some("0x21"), true),
            ],
            &[0, 1],
            &[],
        );
        let instr = instruction(PROG_B, &[0x21]);
        assert_eq!(route_indexes(&store, &set, &built, &instr), vec![1]);
    }

    #[test]
    fn account_filters_reapplied_in_routing() {
        let mut filtered = reg(0, true);
        filtered.account_filters = vec![vec![SvmAccountFilterInput {
            position: 1,
            values: vec![ACCOUNT_1.to_string()],
        }]];
        let (store, set, built) = build(
            &[program(PROG_A, vec![ix(Some("0x21"), vec![filtered])])],
            &[0],
            &[],
        );
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
        let mut outer_only = reg(0, true);
        outer_only.is_inner = Some(false);
        let (store, set, built) = build(
            &[program(PROG_A, vec![ix(Some("0x21"), vec![outer_only])])],
            &[0],
            &[],
        );
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
            &[program(
                PROG_A,
                vec![
                    ix(Some("0x21"), vec![reg(0, true)]),
                    ix(Some("0x22"), vec![reg(1, true)]),
                ],
            )],
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
            SelectionBuilder::from_programs(&[], &store.handle().read().unwrap()).unwrap();
        let err = builder.build(&[7]).err().unwrap();
        assert!(format!("{err:#}").contains("Unknown registration index 7"));
    }
}
