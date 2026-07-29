use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use anyhow::{Context, Result};
use napi_derive::napi;

mod borsh_decoder;
mod config;
mod query;
mod selection;
pub(crate) mod types;

/// Local hex helpers. Lives here so `decoder.rs` can pull them via
/// `super::mod_helpers::hex_to_bytes` without crossing the crate boundary
/// and without exposing a public hex parser at the napi surface.
pub(crate) mod mod_helpers {
    use anyhow::{anyhow, Result};
    pub fn hex_to_bytes(input: &str) -> Result<Vec<u8>> {
        let s = input.strip_prefix("0x").unwrap_or(input);
        if !s.len().is_multiple_of(2) {
            return Err(anyhow!("hex string has odd length: '{input}'"));
        }
        (0..s.len())
            .step_by(2)
            .map(|i| {
                s.get(i..i + 2)
                    .and_then(|byte| u8::from_str_radix(byte, 16).ok())
                    .ok_or_else(|| anyhow!("invalid hex byte at offset {i} in '{input}'"))
            })
            .collect()
    }
}

use hypersync_client_solana::decode::ProgramSchema as UpstreamSchema;
use hypersync_client_solana::simple_types as simple;
use hypersync_solana_net_types::field_selection::SolanaFieldSelection;
use hypersync_solana_net_types::query::SolanaQuery;

use crate::address_store::{AddressSet, AddressStore, SetCache, StoreInner};
use crate::block_store::BlockStore;
use crate::config_parsing::human_config::svm::{ArgDef, ArgType};
use crate::transaction_store::TransactionStore;
use borsh_decoder::{DecodedInstructionJson, InstructionSchemaInput};
use config::SvmClientConfig;
use query::SvmQuery;
use selection::{route_instruction, SelectionBuilder, SvmOnEventRegistrationInput};
use types::{opt_hex, to_hex, QueryResponse};

/// Move the response's transactions and token balances into a
/// `TransactionStore`, keyed by `(slot, transactionIndex)`. Kept in Rust so
/// only the config-selected fields are materialised at batch prep; many
/// instructions in one transaction collapse to a single stored row, and token
/// balances land in the store's companion table joined back by key at
/// materialisation.
///
/// `keys` restricts what is stored to the transactions routed items reference;
/// `None` stores the whole response (the raw `get` query, which builds no
/// items).
fn build_svm_store(
    mut transactions: Vec<simple::Transaction>,
    mut token_balances: Vec<simple::TokenBalance>,
    keys: Option<&HashSet<(u64, u32)>>,
) -> TransactionStore {
    if let Some(keys) = keys {
        transactions.retain(|tx| keys.contains(&(tx.slot, tx.transaction_index)));
        token_balances.retain(|b| {
            b.transaction_index
                .is_some_and(|i| keys.contains(&(b.slot, i)))
        });
    }
    let store = TransactionStore::new_svm();
    store.insert_svm_txs(transactions);
    store.insert_svm_token_balances(token_balances);
    store
}

/// Per-program Borsh schemas from the registrations that carry schema pieces
/// (`accounts`/`args`), keyed by base58 program id. A registration without a
/// schema (or without a discriminator to dispatch on) contributes nothing;
/// the program's `definedTypes` come from its first schema-carrying
/// registration — every registration of a program duplicates the same
/// registry.
fn build_schemas(
    registrations: &[SvmOnEventRegistrationInput],
) -> Result<HashMap<String, UpstreamSchema>> {
    struct ProgramParts {
        defined_types: BTreeMap<String, ArgType>,
        instructions: Vec<InstructionSchemaInput>,
    }
    let mut parts_by_program: Vec<(String, ProgramParts)> = Vec::new();

    for reg in registrations {
        if reg.program_id.is_empty() {
            continue;
        }
        let has_schema = !reg.accounts.is_empty() || reg.args_json.is_some();
        let discriminator = reg.discriminator.as_deref().unwrap_or_default();
        if !has_schema || discriminator.is_empty() {
            continue;
        }
        let args: Vec<ArgDef> = reg
            .args_json
            .as_deref()
            .map(|json| {
                serde_json::from_str(json)
                    .with_context(|| format!("parse args schema for {}", reg.instruction_name))
            })
            .transpose()?
            .unwrap_or_default();
        let instruction = InstructionSchemaInput {
            name: reg.instruction_name.clone(),
            discriminator: discriminator.to_string(),
            accounts: reg.accounts.clone(),
            args,
        };
        match parts_by_program
            .iter_mut()
            .find(|(program_id, _)| program_id == &reg.program_id)
        {
            Some((_, parts)) => parts.instructions.push(instruction),
            None => {
                let defined_types: BTreeMap<String, ArgType> = reg
                    .defined_types_json
                    .as_deref()
                    .map(|json| {
                        serde_json::from_str(json).with_context(|| {
                            format!("parse defined types for {}", reg.instruction_name)
                        })
                    })
                    .transpose()?
                    .unwrap_or_default();
                parts_by_program.push((
                    reg.program_id.clone(),
                    ProgramParts {
                        defined_types,
                        instructions: vec![instruction],
                    },
                ));
            }
        }
    }

    parts_by_program
        .into_iter()
        .map(|(program_id, parts)| {
            let schema = borsh_decoder::build_program_schema(
                program_id.clone(),
                &parts.defined_types,
                parts.instructions,
            )
            .with_context(|| format!("build program schema for {program_id}"))?;
            Ok((program_id, schema))
        })
        .collect()
}

#[napi]
pub struct SvmHyperSyncClient {
    inner: Arc<hypersync_client_solana::Client>,
    schemas: HashMap<String, UpstreamSchema>,
    selection_builder: SelectionBuilder,
    /// The chain's address index, shared with the fetch state. Read by the
    /// per-instruction owner gate.
    address_store: Arc<std::sync::RwLock<StoreInner>>,
}

#[napi]
impl SvmHyperSyncClient {
    #[napi(constructor)]
    pub fn new(
        cfg: SvmClientConfig,
        user_agent: String,
        event_registrations: Vec<SvmOnEventRegistrationInput>,
        address_store: &AddressStore,
    ) -> napi::Result<SvmHyperSyncClient> {
        Self::from_config(cfg, user_agent, event_registrations, address_store)
    }

    /// Factory taking a custom user agent, mirroring EVM's `new_with_agent`.
    /// Exposed so callers that grab the class dynamically (e.g. ReScript
    /// reaching through the addon dict) can use `@send` rather than `%raw`.
    #[napi(factory)]
    pub fn from_config(
        cfg: SvmClientConfig,
        user_agent: String,
        event_registrations: Vec<SvmOnEventRegistrationInput>,
        address_store: &AddressStore,
    ) -> napi::Result<SvmHyperSyncClient> {
        let schemas = build_schemas(&event_registrations)
            .context("build program schemas")
            .map_err(map_err)?;
        let handle = address_store.handle();
        let selection_builder = {
            let store = handle.read().unwrap();
            SelectionBuilder::from_registrations(&event_registrations, &store)
                .context("build selection builder")
                .map_err(map_err)?
        };
        let inner = hypersync_client_solana::Client::new_with_agent(cfg.into(), user_agent)
            .context("build solana client")
            .map_err(map_err)?;
        Ok(SvmHyperSyncClient {
            inner: Arc::new(inner),
            schemas,
            selection_builder,
            address_store: handle,
        })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let h = self.inner.get_height().await.map_err(map_err)?;
        i64::try_from(h)
            .with_context(|| format!("height {} does not fit in i64", h))
            .map_err(map_err)
    }

    /// Single-window query (no client-side pagination), used for block-hash
    /// range queries. The hyperindex source layer paginates by chunking the
    /// slot range itself, so the napi binding must NOT call `collect` (which
    /// spins up parallel batched requests under `StreamConfig::default()` and
    /// can DoS the server on multi-day windows).
    #[napi]
    pub async fn get(
        &self,
        query: SvmQuery,
    ) -> napi::Result<(QueryResponse, TransactionStore, BlockStore)> {
        let q: SolanaQuery = query
            .try_into()
            .context("parse solana query")
            .map_err(map_err)?;
        let mut resp = self
            .inner
            .get(&q)
            .await
            .context("solana get")
            .map_err(map_err)?;

        // Retain raw transactions + token balances in Rust; the store
        // materialises the parent transaction (selected fields only) at batch
        // prep.
        let store = build_svm_store(
            std::mem::take(&mut resp.transactions),
            std::mem::take(&mut resp.token_balances),
            None,
        );

        let (block_headers, block_store) = take_blocks(&mut resp, None).map_err(map_err)?;

        let mut out = QueryResponse::try_from(resp)
            .context("convert solana response")
            .map_err(map_err)?;
        out.data.blocks = block_headers;
        Ok((out, store, block_store))
    }

    #[napi]
    pub async fn get_event_items(
        &self,
        params: EventItemsQuery,
        address_set: &AddressSet,
    ) -> napi::Result<(EventItemsResponse, TransactionStore, BlockStore)> {
        let built = self
            .selection_builder
            .build(&params.registration_indexes)
            .map_err(map_err)?;

        let mut field_selection = SolanaFieldSelection {
            block: parse_columns(&built.block_columns).map_err(map_err)?,
            // Instructions keep the server's full column set — everything
            // item building reads (data, accounts, dN, addresses, flags).
            ..Default::default()
        };
        // Under the server's default merge mode, requesting a table's columns
        // is what opts the matched result set into that join — a table with an
        // empty field list returns no rows (instructions and blocks are
        // exempt), so each opted-into table needs its columns spelled out.
        if !built.transaction_columns.is_empty() {
            field_selection.transaction =
                parse_columns(&built.transaction_columns).map_err(map_err)?;
        }
        if built.needs_logs {
            field_selection.log = parse_columns(&[
                "slot",
                "transaction_index",
                "instruction_address",
                "kind",
                "message",
            ])
            .map_err(map_err)?;
        }
        if built.needs_token_balances {
            // The store keys balance rows by account regardless of what the
            // consumer selected, so `account` always rides along.
            field_selection.token_balance = parse_columns(&[
                "slot",
                "transaction_index",
                "account",
                "mint",
                "owner",
                "pre_amount",
                "post_amount",
            ])
            .map_err(map_err)?;
        }

        let query = SolanaQuery {
            from_slot: u64::try_from(params.from_slot)
                .context("from_slot must be non-negative")
                .map_err(map_err)?,
            // Inclusive on the boundary, exclusive on the wire.
            to_slot: params
                .to_slot
                .map(|b| {
                    u64::try_from(b)
                        .context("to_slot must be non-negative")?
                        .checked_add(1)
                        .context("to_slot overflow")
                })
                .transpose()
                .map_err(map_err)?,
            instructions: built.instruction_selections.clone(),
            field_selection,
            max_num_instructions: params
                .max_num_instructions
                .and_then(|v| usize::try_from(v).ok()),
            ..Default::default()
        };

        let mut resp = self
            .inner
            .get(&query)
            .await
            .context("solana get")
            .map_err(map_err)?;

        let client_filtered = crate::client_filtered_contracts::ClientFilteredContracts::from_vec(
            params.client_filtered_contracts.unwrap_or_default(),
        );
        // Materialise the set's cache before taking the store guard: `cache()`
        // lazily initialises by reading the same lock, and a writer queued
        // between the two reads would deadlock the pair.
        let set_cache = address_set.cache().clone();
        // Route before filling the stores: an instruction that routes nowhere
        // keeps neither its transaction nor its block.
        let items = {
            let store = self.address_store.read().unwrap();
            build_event_items(
                &resp.instructions,
                std::mem::take(&mut resp.logs),
                &built,
                &self.schemas,
                &set_cache,
                &client_filtered,
                &store,
            )
            .map_err(map_err)?
        };

        let referenced_transactions: HashSet<(u64, u32)> = items
            .iter()
            .filter_map(|item| {
                Some((
                    u64::try_from(item.slot).ok()?,
                    u32::try_from(item.transaction_index).ok()?,
                ))
            })
            .collect();
        let referenced_slots: HashSet<u64> = referenced_transactions
            .iter()
            .map(|(slot, _)| *slot)
            .collect();

        let store = build_svm_store(
            std::mem::take(&mut resp.transactions),
            std::mem::take(&mut resp.token_balances),
            Some(&referenced_transactions),
        );
        let (block_headers, block_store) =
            take_blocks(&mut resp, Some(&referenced_slots)).map_err(map_err)?;

        let response = EventItemsResponse {
            next_slot: i64::try_from(resp.next_slot)
                .context("next_slot overflow")
                .map_err(map_err)?,
            blocks: block_headers,
            items,
        };
        Ok((response, store, block_store))
    }
}

/// The whole per-query input for `get_event_items`: the slot range and the
/// partition's registration selection (by index). The partition's addresses
/// arrive separately, as the `AddressSet` handle. Instruction selections, field
/// selection, and routing are all derived internally from the registrations
/// passed at construction.
#[napi(object)]
pub struct EventItemsQuery {
    pub from_slot: i64,
    /// Inclusive; `None` queries to the end of available data.
    pub to_slot: Option<i64>,
    /// `None` sends no server-side cap on the number of instructions returned.
    pub max_num_instructions: Option<i64>,
    pub registration_indexes: Vec<i64>,
    /// Program names to fetch address-free even though their registrations
    /// depend on addresses (client-side filtering). Absent or empty means every
    /// address-dependent program is filtered server-side.
    pub client_filtered_contracts: Option<Vec<String>>,
}

#[napi(object)]
#[derive(Clone)]
pub struct LogItem {
    pub kind: String,
    pub message: String,
}

/// One routed instruction. Carries everything JS needs to build the handler
/// payload; the parent transaction and block are materialised from the
/// per-chain stores at batch prep.
#[napi(object)]
pub struct EventItem {
    /// The registration this instruction routed to, as passed to the client
    /// constructor. Instructions that route nowhere never cross the boundary.
    pub on_event_registration_index: i64,
    pub slot: i64,
    pub transaction_index: i64,
    pub instruction_address: Vec<i64>,
    pub program_id: String,
    pub accounts: Vec<String>,
    /// Raw instruction data, `0x`-prefixed hex; decoded params ride on
    /// `decoded` when the registration carries a Borsh schema.
    pub data: String,
    pub d1: Option<String>,
    pub d2: Option<String>,
    pub d4: Option<String>,
    pub d8: Option<String>,
    pub is_inner: bool,
    pub decoded: Option<DecodedInstructionJson>,
    /// Logs scoped to this instruction; `Some` only when the routed
    /// registration opted in via `includeLogs`.
    pub logs: Option<Vec<LogItem>>,
}

#[napi(object)]
pub struct EventItemsResponse {
    pub next_slot: i64,
    /// The page's lean block headers, one per slot; used for reorg detection
    /// and the batch's latest timestamp. The full blocks live in the
    /// `BlockStore` returned alongside this response.
    pub blocks: Vec<types::Block>,
    pub items: Vec<EventItem>,
}

/// Fans each committed instruction out to the registrations it routes to.
/// Logs group per (slot, transactionIndex, instructionAddress) and attach only
/// to items whose registration opted in via `includeLogs`; logs without an
/// instruction address attach to no instruction (rare; usually only system
/// messages). Borsh decoding runs once per instruction against its program's
/// schema, when one exists.
fn build_event_items(
    instructions: &[simple::Instruction],
    logs: Vec<simple::Log>,
    built: &selection::BuiltSelection,
    schemas: &HashMap<String, UpstreamSchema>,
    set_cache: &SetCache,
    client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
    address_store: &StoreInner,
) -> Result<Vec<EventItem>> {
    let mut logs_by_key: HashMap<(u64, u32, Vec<u32>), Vec<LogItem>> = HashMap::new();
    for log in logs {
        if let (Some(transaction_index), Some(instruction_address)) =
            (log.transaction_index, log.instruction_address)
        {
            logs_by_key
                .entry((log.slot, transaction_index, instruction_address))
                .or_default()
                .push(LogItem {
                    kind: log.kind.unwrap_or_default(),
                    message: log.message.unwrap_or_default(),
                });
        }
    }

    let mut items: Vec<EventItem> = Vec::with_capacity(instructions.len());
    for instr in instructions {
        // Instructions from failed transactions are excluded. HyperSync has no
        // server-side predicate to filter instructions by parent-transaction
        // success, so the client filters on the `isCommitted` flag it already
        // delivers on every instruction row.
        if !instr.is_committed {
            continue;
        }
        let slot = i64::try_from(instr.slot).context("instruction.slot overflow")?;
        let program_key = instr.program_id.as_bytes();
        let address = selection::InstructionAddress {
            key: program_key,
            contract_name: set_cache.owner_of(program_key),
            slot,
        };
        let routed = route_instruction(
            &built.registrations,
            instr,
            &address,
            client_filtered,
            address_store,
        );
        if routed.is_empty() {
            continue;
        }
        let decoded = schemas.get(&instr.program_id).and_then(|schema| {
            borsh_decoder::decode_with_schema(schema, instr.accounts.clone(), instr.data.clone())
        });
        let logs = if routed.iter().any(|reg| reg.include_logs) {
            logs_by_key
                .get(&(
                    instr.slot,
                    instr.transaction_index,
                    instr.instruction_address.clone(),
                ))
                .cloned()
        } else {
            None
        };
        for reg in routed {
            items.push(EventItem {
                on_event_registration_index: reg.index,
                slot,
                transaction_index: i64::from(instr.transaction_index),
                instruction_address: instr
                    .instruction_address
                    .iter()
                    .map(|&v| i64::from(v))
                    .collect(),
                program_id: instr.program_id.clone(),
                accounts: instr.accounts.clone(),
                data: to_hex(&instr.data),
                d1: opt_hex(&instr.d1),
                d2: opt_hex(&instr.d2),
                d4: opt_hex(&instr.d4),
                d8: opt_hex(&instr.d8),
                is_inner: instr.is_inner,
                decoded: decoded.clone(),
                logs: if reg.include_logs { logs.clone() } else { None },
            });
        }
    }
    Ok(items)
}

fn parse_columns<F>(columns: &[&str]) -> Result<Vec<F>>
where
    F: std::str::FromStr,
{
    columns
        .iter()
        .map(|name| {
            name.parse::<F>()
                .map_err(|_| anyhow::anyhow!("unknown field name {name:?}"))
        })
        .collect()
}

/// Take the raw blocks out of the response, build the lean per-slot header
/// from a borrow, then move the owned raw blocks into the store — avoiding a
/// full raw-`Block` clone per block. slot/time/hash decode from the store like
/// any other field, so every block an item reads needs a store entry.
///
/// `slots` restricts what is stored to the slots routed items reference;
/// `None` stores every block (the raw `get` query, which builds no items).
/// Headers are built for every returned block either way — reorg detection and
/// the batch's latest timestamp read them whether an item landed there or not.
fn take_blocks(
    resp: &mut simple::SolanaResponse,
    slots: Option<&HashSet<u64>>,
) -> Result<(Vec<types::Block>, BlockStore)> {
    let mut raw_blocks = std::mem::take(&mut resp.blocks);
    let block_headers: Vec<types::Block> = raw_blocks
        .iter()
        .map(types::Block::from_raw)
        .collect::<Result<Vec<_>>>()
        .context("mapping solana block headers")?;
    if let Some(slots) = slots {
        raw_blocks.retain(|b| slots.contains(&b.slot));
    }
    let block_store = BlockStore::new_svm();
    block_store.insert_svm_blocks(raw_blocks);
    Ok((block_headers, block_store))
}

pub(crate) fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::{set_of, svm_store};
    use query::{InstructionSelection, SvmQuery};

    const TOKEN_METADATA_PROGRAM: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

    /// Live test against `solana.hypersync.xyz`. Run with:
    ///     cargo test -p envio --lib svm_hypersync_source::tests -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn live_query_token_metadata() {
        let client = SvmHyperSyncClient::new(
            SvmClientConfig {
                url: "https://solana.hypersync.xyz".into(),
                ..Default::default()
            },
            "hyperindex-test".into(),
            vec![],
            &svm_store(&[]),
        )
        .expect("build client");

        let height = client.get_height().await.expect("get_height");
        eprintln!("current slot: {}", height);
        let from = height.saturating_sub(10_000).max(0);

        let q = SvmQuery {
            from_slot: from,
            to_slot: Some(height),
            instructions: Some(vec![InstructionSelection {
                program_id: Some(vec![TOKEN_METADATA_PROGRAM.into()]),
                ..Default::default()
            }]),
            max_num_instructions: Some(200),
            ..Default::default()
        };

        // Transactions are moved into the store, so `resp.data.transactions` is
        // empty here by design.
        let (resp, _store, _block_store) = client.get(q).await.expect("collect");
        eprintln!(
            "got {} instructions / next_slot={}",
            resp.data.instructions.len(),
            resp.next_slot
        );
        assert!(
            !resp.data.instructions.is_empty(),
            "expected at least one Token Metadata instruction"
        );
        for ix in resp.data.instructions.iter().take(3) {
            assert_eq!(ix.program_id, TOKEN_METADATA_PROGRAM);
            assert!(ix.data.starts_with("0x"));
            assert!(ix.data.len() > 2, "data should not be empty hex");
        }
    }

    fn reg_input(
        index: i64,
        discriminator: &str,
        include_logs: bool,
    ) -> SvmOnEventRegistrationInput {
        SvmOnEventRegistrationInput {
            index,
            instruction_name: format!("I{index}"),
            contract_name: "TokenMetadata".to_string(),
            program_id: TOKEN_METADATA_PROGRAM.to_string(),
            is_wildcard: true,
            start_block: None,
            discriminator: Some(discriminator.to_string()),
            discriminator_byte_len: 1,
            is_inner: None,
            include_logs,
            account_filters: vec![],
            transaction_fields: vec![],
            block_fields: vec![],
            accounts: vec![],
            args_json: None,
            defined_types_json: None,
        }
    }

    /// The store and set a real query carries: `TokenMetadata` (and `Other`,
    /// when a test names it) holding the program id.
    fn fixture(contract_names: &[&str]) -> (AddressStore, AddressSet) {
        let entries: Vec<(&str, &[&str])> = contract_names
            .iter()
            .map(|name| {
                let addresses: &[&str] = if *name == "TokenMetadata" {
                    &[TOKEN_METADATA_PROGRAM]
                } else {
                    &[]
                };
                (*name, addresses)
            })
            .collect();
        let store = svm_store(&entries);
        let set = set_of(&store, contract_names);
        (store, set)
    }

    fn route(
        store: &AddressStore,
        set: &AddressSet,
        instructions: &[simple::Instruction],
        logs: Vec<simple::Log>,
        built: &selection::BuiltSelection,
    ) -> Result<Vec<EventItem>> {
        let address_store = store.handle();
        let address_store = address_store.read().unwrap();
        build_event_items(
            instructions,
            logs,
            built,
            &HashMap::new(),
            set.cache(),
            &Default::default(),
            &address_store,
        )
    }

    fn committed_instruction(data: &[u8]) -> simple::Instruction {
        simple::Instruction {
            program_id: TOKEN_METADATA_PROGRAM.to_string(),
            data: data.to_vec(),
            slot: 42,
            transaction_index: 7,
            instruction_address: vec![1],
            is_committed: true,
            ..Default::default()
        }
    }

    #[test]
    fn uncommitted_instructions_are_dropped() {
        let (store, set) = fixture(&["TokenMetadata"]);
        let built = SelectionBuilder::from_registrations(
            &[reg_input(0, "0x21", false)],
            &store.handle().read().unwrap(),
        )
        .unwrap()
        .build(&[0])
        .unwrap();
        let committed = committed_instruction(&[0x21]);
        let mut uncommitted = committed_instruction(&[0x21]);
        uncommitted.is_committed = false;
        uncommitted.transaction_index = 8;
        let items = route(&store, &set, &[committed, uncommitted], vec![], &built).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| (
                    i.on_event_registration_index,
                    i.transaction_index,
                    i.data.as_str()
                ))
                .collect::<Vec<_>>(),
            vec![(0, 7, "0x21")]
        );
    }

    #[test]
    fn logs_attach_only_to_opted_in_registrations() {
        // Two registrations fan out from the same instruction; only the
        // includeLogs one carries the instruction-scoped log.
        let (store, set) = fixture(&["TokenMetadata", "Other"]);
        let built = SelectionBuilder::from_registrations(
            &[reg_input(0, "0x21", true), {
                let mut with_different_contract = reg_input(1, "0x21", false);
                with_different_contract.contract_name = "Other".to_string();
                with_different_contract
            }],
            &store.handle().read().unwrap(),
        )
        .unwrap()
        .build(&[0, 1])
        .unwrap();
        let instr = committed_instruction(&[0x21]);
        let log = simple::Log {
            slot: 42,
            transaction_index: Some(7),
            instruction_address: Some(vec![1]),
            kind: Some("data".to_string()),
            message: Some("hello".to_string()),
            ..Default::default()
        };
        let unscoped_log = simple::Log {
            slot: 42,
            transaction_index: Some(7),
            instruction_address: None,
            ..Default::default()
        };
        let items = route(&store, &set, &[instr], vec![log, unscoped_log], &built).unwrap();
        let views: Vec<(i64, Option<Vec<(String, String)>>)> = items
            .iter()
            .map(|i| {
                (
                    i.on_event_registration_index,
                    i.logs.as_ref().map(|logs| {
                        logs.iter()
                            .map(|l| (l.kind.clone(), l.message.clone()))
                            .collect()
                    }),
                )
            })
            .collect();
        assert_eq!(
            views,
            vec![
                (0, Some(vec![("data".to_string(), "hello".to_string())])),
                (1, None),
            ]
        );
    }

    #[test]
    fn schemas_group_instructions_per_program_and_skip_schemaless() {
        let with_schema =
            |index: i64, name: &str, discriminator: &str| selection::SvmOnEventRegistrationInput {
                index,
                instruction_name: name.to_string(),
                contract_name: "TokenMetadata".to_string(),
                program_id: TOKEN_METADATA_PROGRAM.to_string(),
                is_wildcard: false,
                start_block: None,
                discriminator: Some(discriminator.to_string()),
                discriminator_byte_len: 1,
                is_inner: None,
                include_logs: false,
                account_filters: vec![],
                transaction_fields: vec![],
                block_fields: vec![],
                accounts: vec!["metadata".to_string()],
                args_json: Some(r#"[{"name":"amount","type":"u64"}]"#.to_string()),
                defined_types_json: None,
            };
        let mut schemaless = with_schema(2, "NoSchema", "0x03");
        schemaless.accounts = vec![];
        schemaless.args_json = None;

        let schemas = build_schemas(&[
            with_schema(0, "CreateV1", "0x21"),
            with_schema(1, "UpdateV1", "0x0f"),
            schemaless,
        ])
        .unwrap();
        assert_eq!(
            schemas.keys().collect::<Vec<_>>(),
            vec![TOKEN_METADATA_PROGRAM]
        );
    }

    use crate::field_columns::test_support::{column, str_column};

    // `materialize` uses `block_in_place`, which needs a multi-thread runtime.
    #[tokio::test(flavor = "multi_thread")]
    async fn store_keeps_only_the_transactions_and_balances_items_reference() {
        let tx = |slot, index| simple::Transaction {
            slot,
            transaction_index: index,
            fee_payer: Some(format!("payer{slot}")),
            ..Default::default()
        };
        let balance = |slot, index| simple::TokenBalance {
            slot,
            transaction_index: Some(index),
            account: Some(format!("acct{slot}")),
            mint: Some(format!("mint{slot}")),
            ..Default::default()
        };
        // Only (42, 7) is routed; (43, 7) came back on the same page unreferenced.
        let referenced: HashSet<(u64, u32)> = [(42u64, 7u32)].into_iter().collect();
        let store = build_svm_store(
            vec![tx(42, 7), tx(43, 7)],
            vec![balance(42, 7), balance(43, 7)],
            Some(&referenced),
        );

        let mask = ((1u64 << (crate::transaction_store::SvmTxField::FeePayer as u32))
            | (1u64 << (crate::transaction_store::SvmTxField::TokenBalances as u32)))
            as f64;
        let cols = store
            .materialize(vec![42, 43], vec![7, 7], vec![mask, mask])
            .await
            .expect("materialize");

        let mints: Vec<Option<Vec<Option<String>>>> = match column(&cols, "tokenBalances") {
            Some(crate::field_columns::Column::TokenBalances(rows)) => rows
                .iter()
                .map(|r| {
                    r.as_ref()
                        .map(|v| v.iter().map(|tb| tb.mint.clone()).collect())
                })
                .collect(),
            _ => panic!("expected a tokenBalances column"),
        };
        assert_eq!(
            (str_column(&cols, "feePayer"), mints),
            (
                vec![Some("payer42".to_string()), None],
                // The unreferenced transaction keeps no balances either; a
                // selected row with none materialises as `[]`.
                vec![Some(vec![Some("mint42".to_string())]), Some(vec![])],
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn no_key_set_stores_the_whole_response() {
        // The raw `get` query builds no items, so it has no reference set to
        // filter by and must keep everything.
        let mut resp = simple::SolanaResponse {
            blocks: vec![simple::Block {
                slot: 43,
                blockhash: "hash43".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        };
        let store = build_svm_store(
            vec![simple::Transaction {
                slot: 43,
                transaction_index: 7,
                fee_payer: Some("payer43".to_string()),
                ..Default::default()
            }],
            vec![],
            None,
        );
        let (_, block_store) = take_blocks(&mut resp, None).expect("take blocks");

        let txs = store
            .materialize(
                vec![43],
                vec![7],
                vec![(1u64 << (crate::transaction_store::SvmTxField::FeePayer as u32)) as f64],
            )
            .await
            .expect("materialize transactions");
        let blocks = block_store
            .materialize(
                vec![43],
                vec![(1u64 << (crate::block_store::SvmBlockField::Hash as u32)) as f64],
            )
            .await
            .expect("materialize blocks");

        assert_eq!(
            (str_column(&txs, "feePayer"), str_column(&blocks, "hash")),
            (
                vec![Some("payer43".to_string())],
                vec![Some("hash43".to_string())],
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn block_store_keeps_only_referenced_slots_while_headers_keep_all() {
        let mut resp = simple::SolanaResponse {
            blocks: vec![
                simple::Block {
                    slot: 42,
                    blockhash: "hash42".to_string(),
                    ..Default::default()
                },
                simple::Block {
                    slot: 43,
                    blockhash: "hash43".to_string(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let referenced: HashSet<u64> = [42u64].into_iter().collect();
        let (headers, block_store) =
            take_blocks(&mut resp, Some(&referenced)).expect("take blocks");

        let mask = (1u64 << (crate::block_store::SvmBlockField::Hash as u32)) as f64;
        let cols = block_store
            .materialize(vec![42, 43], vec![mask, mask])
            .await
            .expect("materialize");

        assert_eq!(
            (
                headers.iter().map(|b| b.slot).collect::<Vec<_>>(),
                str_column(&cols, "hash"),
            ),
            (
                // Reorg detection and the batch's latest timestamp read every
                // returned slot, so headers aren't filtered.
                vec![42, 43],
                vec![Some("hash42".to_string()), None],
            )
        );
    }
}
