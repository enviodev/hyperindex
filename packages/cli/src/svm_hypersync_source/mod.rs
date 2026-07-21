use std::collections::{BTreeMap, HashMap};
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
                u8::from_str_radix(&s[i..i + 2], 16)
                    .map_err(|_| anyhow!("invalid hex byte at offset {i} in '{input}'"))
            })
            .collect()
    }
}

use hypersync_client_solana::decode::ProgramSchema as UpstreamSchema;
use hypersync_client_solana::simple_types as simple;
use hypersync_solana_net_types::field_selection::SolanaFieldSelection;
use hypersync_solana_net_types::query::SolanaQuery;

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
fn build_svm_store(
    transactions: Vec<simple::Transaction>,
    token_balances: Vec<simple::TokenBalance>,
) -> TransactionStore {
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
}

#[napi]
impl SvmHyperSyncClient {
    #[napi(constructor)]
    pub fn new(
        cfg: SvmClientConfig,
        user_agent: String,
        event_registrations: Vec<SvmOnEventRegistrationInput>,
    ) -> napi::Result<SvmHyperSyncClient> {
        Self::from_config(cfg, user_agent, event_registrations)
    }

    /// Factory taking a custom user agent, mirroring EVM's `new_with_agent`.
    /// Exposed so callers that grab the class dynamically (e.g. ReScript
    /// reaching through the addon dict) can use `@send` rather than `%raw`.
    #[napi(factory)]
    pub fn from_config(
        cfg: SvmClientConfig,
        user_agent: String,
        event_registrations: Vec<SvmOnEventRegistrationInput>,
    ) -> napi::Result<SvmHyperSyncClient> {
        let schemas = build_schemas(&event_registrations)
            .context("build program schemas")
            .map_err(map_err)?;
        let selection_builder = SelectionBuilder::from_registrations(&event_registrations)
            .context("build selection builder")
            .map_err(map_err)?;
        let inner = hypersync_client_solana::Client::new_with_agent(cfg.into(), user_agent)
            .context("build solana client")
            .map_err(map_err)?;
        Ok(SvmHyperSyncClient {
            inner: Arc::new(inner),
            schemas,
            selection_builder,
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
        );

        let (block_headers, block_store) = take_blocks(&mut resp).map_err(map_err)?;

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
                .map(|b| u64::try_from(b + 1).context("to_slot must be non-negative"))
                .transpose()
                .map_err(map_err)?,
            instructions: built.instruction_selections.clone(),
            field_selection,
            max_num_instructions: usize::try_from(params.max_num_instructions).ok(),
            ..Default::default()
        };

        let mut resp = self
            .inner
            .get(&query)
            .await
            .context("solana get")
            .map_err(map_err)?;

        let store = build_svm_store(
            std::mem::take(&mut resp.transactions),
            std::mem::take(&mut resp.token_balances),
        );
        let (block_headers, block_store) = take_blocks(&mut resp).map_err(map_err)?;

        let mut contract_name_by_address: HashMap<String, String> = HashMap::new();
        for (contract_name, addresses) in &params.addresses_by_contract_name {
            for address in addresses {
                contract_name_by_address.insert(address.clone(), contract_name.clone());
            }
        }

        let items = build_event_items(
            &resp.instructions,
            std::mem::take(&mut resp.logs),
            &built,
            &self.schemas,
            &contract_name_by_address,
        )
        .map_err(map_err)?;

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

/// The whole per-query input for `get_event_items`: the slot range, the
/// partition's registration selection (by index), and its current addresses
/// (program ids per program name). Instruction selections, field selection,
/// and routing are all derived internally from the registrations passed at
/// construction.
#[napi(object)]
pub struct EventItemsQuery {
    pub from_slot: i64,
    /// Inclusive; `None` queries to the end of available data.
    pub to_slot: Option<i64>,
    pub max_num_instructions: i64,
    pub registration_indexes: Vec<i64>,
    pub addresses_by_contract_name: HashMap<String, Vec<String>>,
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
    contract_name_by_address: &HashMap<String, String>,
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
        let contract_name = contract_name_by_address
            .get(&instr.program_id)
            .map(String::as_str);
        let routed = route_instruction(&built.registrations, instr, contract_name);
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
        let slot = i64::try_from(instr.slot).context("instruction.slot overflow")?;
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
/// any other field, so every response block needs a store entry.
fn take_blocks(resp: &mut simple::SolanaResponse) -> Result<(Vec<types::Block>, BlockStore)> {
    let raw_blocks = std::mem::take(&mut resp.blocks);
    let block_headers: Vec<types::Block> = raw_blocks
        .iter()
        .map(types::Block::from_raw)
        .collect::<Result<Vec<_>>>()
        .context("mapping solana block headers")?;
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
        let built = SelectionBuilder::from_registrations(&[reg_input(0, "0x21", false)])
            .unwrap()
            .build(&[0])
            .unwrap();
        let committed = committed_instruction(&[0x21]);
        let mut uncommitted = committed_instruction(&[0x21]);
        uncommitted.is_committed = false;
        uncommitted.transaction_index = 8;
        let items = build_event_items(
            &[committed, uncommitted],
            vec![],
            &built,
            &HashMap::new(),
            &HashMap::new(),
        )
        .unwrap();
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
        let built = SelectionBuilder::from_registrations(&[reg_input(0, "0x21", true), {
            let mut with_different_contract = reg_input(1, "0x21", false);
            with_different_contract.contract_name = "Other".to_string();
            with_different_contract
        }])
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
        let items = build_event_items(
            &[instr],
            vec![log, unscoped_log],
            &built,
            &HashMap::new(),
            &HashMap::new(),
        )
        .unwrap();
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
}
