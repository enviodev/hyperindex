use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use anyhow::{Context, Result};
use napi::bindgen_prelude::Uint8Array;
use napi_derive::napi;

mod borsh_decoder;
mod config;
mod fields;
mod query;
mod selection;
pub(crate) mod types;

pub(crate) mod mod_helpers {
    use anyhow::Result;
    pub fn hex_to_bytes(input: &str) -> Result<Vec<u8>> {
        crate::hex::decode_optionally_prefixed(input, "hex string")
    }
}

use hypersync_client_solana::simple_types as simple;
use hypersync_client_solana::RateLimitInfo;
use hypersync_solana_net_types::field_selection::SolanaFieldSelection;
use hypersync_solana_net_types::query::SolanaQuery;

use crate::address_store::{AddressSet, AddressStore, Emitter, SetCache, StoreInner};
use crate::block_hash_pagination::{paginate_block_hashes, HashPage};
use crate::block_store::BlockStore;
use crate::request_stats::{rate_limited_err, source_behind_head_err, RequestStat};
use crate::transaction_store::TransactionStore;
use config::SvmClientConfig;
use query::SvmQuery;
use selection::{route_instruction, SelectionBuilder, SvmProgramInput};

/// Move the response's transactions and account activity into a
/// `TransactionStore`, keyed by `(slot, transactionIndex)`. Kept in Rust so
/// only the config-selected fields are materialised at batch prep; many
/// instructions in one transaction collapse to a single stored row, and account
/// activity lands in the store's companion table joined back by key at
/// materialisation.
///
/// `keys` restricts what is stored to the transactions routed items reference;
/// `None` stores the whole response (the raw `get` query, which builds no
/// items).
fn build_svm_store(
    mut transactions: Vec<simple::Transaction>,
    mut account_activity: Vec<simple::AccountActivity>,
    keys: Option<&HashSet<(u64, u32)>>,
) -> TransactionStore {
    if let Some(keys) = keys {
        let referenced = |slot: Option<u64>, index: Option<u32>| {
            slot.zip(index).is_some_and(|key| keys.contains(&key))
        };
        transactions.retain(|tx| referenced(tx.slot, tx.transaction_index));
        account_activity.retain(|row| referenced(row.slot, row.transaction_index));
    }
    let store = TransactionStore::new_svm();
    store.insert_svm_txs(transactions);
    store.insert_svm_account_activity(account_activity);
    store
}

/// The marker the client leaves in the error chain on a 429. It exposes no
/// typed variant for a rate limit — the 429 is folded into an `anyhow` context
/// line — so the message is the only signal.
const RATE_LIMITED_MARKER: &str = "rate limited by server";

/// Map a failed query to the marker `SourceManager` backs off on when the
/// server rate limited it, and to a plain failure otherwise. `rate_limit` is
/// the client's state, which it refreshed from the same response's headers.
fn map_query_error(error: anyhow::Error, rate_limit: Option<RateLimitInfo>) -> napi::Error {
    if !format!("{error:?}").contains(RATE_LIMITED_MARKER) {
        return map_err(error);
    }
    // A 429 without a reset header still has to back off, or the source would
    // spin straight back into the closed window.
    let reset_secs = rate_limit
        .and_then(|info| info.suggested_wait_secs())
        .unwrap_or(1);
    rate_limited_err(reset_secs * 1000)
}

impl SvmHyperSyncClient {
    /// Run one query, surfacing a rate limit to the source manager rather than
    /// sleeping it out inside the call.
    async fn run_query(&self, query: &SolanaQuery) -> napi::Result<simple::SolanaResponse> {
        self.inner
            .get(query)
            .await
            .context("solana get")
            .map_err(|e| map_query_error(e, self.inner.rate_limit_info()))
    }

    /// Execute one raw Solana HyperSync page. Event queries and block-hash
    /// queries convert only the tables they actually consume.
    async fn get_raw(&self, query: SvmQuery) -> napi::Result<simple::SolanaResponse> {
        let query: SolanaQuery = query
            .try_into()
            .context("parse solana query")
            .map_err(map_err)?;
        self.run_query(&query).await
    }
}

#[napi]
pub struct SvmHyperSyncClient {
    inner: Arc<hypersync_client_solana::Client>,
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
        programs: Vec<SvmProgramInput>,
        address_store: &AddressStore,
    ) -> napi::Result<SvmHyperSyncClient> {
        Self::from_config(cfg, user_agent, programs, address_store)
    }

    /// Factory taking a custom user agent, mirroring EVM's `new_with_agent`.
    /// Exposed so callers that grab the class dynamically (e.g. ReScript
    /// reaching through the addon dict) can use `@send` rather than `%raw`.
    #[napi(factory)]
    pub fn from_config(
        cfg: SvmClientConfig,
        user_agent: String,
        programs: Vec<SvmProgramInput>,
        address_store: &AddressStore,
    ) -> napi::Result<SvmHyperSyncClient> {
        let handle = address_store.handle();
        let selection_builder = {
            let store = handle.read().unwrap();
            SelectionBuilder::from_programs(&programs, &store)
                .context("build selection builder")
                .map_err(map_err)?
        };
        let inner = hypersync_client_solana::Client::new_with_agent(cfg.into(), user_agent)
            .context("build solana client")
            .map_err(map_err)?;
        Ok(SvmHyperSyncClient {
            inner: Arc::new(inner),
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

    /// Fetch the inclusive range spanning `block_numbers` into one response
    /// store. Each advancing cursor proves its half-open range was processed;
    /// missing block rows inside that coverage are skipped slots.
    #[napi]
    pub async fn get_block_hashes(
        &self,
        block_numbers: Vec<i64>,
    ) -> napi::Result<(BlockStore, Vec<RequestStat>)> {
        let fields = query::FieldSelection {
            block: Some(vec!["slot".to_string(), "blockhash".to_string()]),
            ..Default::default()
        };
        let aggregate = BlockStore::new_svm();
        let request_stats = paginate_block_hashes(
            &block_numbers,
            &aggregate,
            "slot numbers",
            |request_from, to_slot_exclusive| {
                let fields = fields.clone();
                let aggregate = &aggregate;
                async move {
                    let query = SvmQuery {
                        from_slot: request_from,
                        to_slot: Some(to_slot_exclusive),
                        include_all_blocks: Some(true),
                        fields: Some(fields),
                        ..Default::default()
                    };
                    let response = self.get_raw(query).await?;
                    let (next, last_returned, store) =
                        block_hash_page(response).map_err(map_err)?;
                    // Each advancing cursor proves its half-open range was
                    // processed; block rows missing inside it are skipped slots.
                    // A cursor that didn't advance proves nothing — leave it to
                    // the paginator, which reports it as a source behind the
                    // head rather than a malformed coverage range.
                    if next > request_from {
                        aggregate
                            .mark_svm_coverage(request_from, next.min(to_slot_exclusive))
                            .map_err(map_err)?;
                    }
                    Ok(HashPage {
                        next,
                        last_returned,
                        store,
                    })
                }
            },
        )
        .await?;
        Ok((aggregate, request_stats))
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
            // Instructions are exempt from merge-mode "empty = no rows", so an
            // empty list would fetch every column. Spell the routing set.
            instruction_call: parse_columns(&built.instruction_columns).map_err(map_err)?,
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
        if !built.log_columns.is_empty() {
            field_selection.log = parse_columns(&built.log_columns).map_err(map_err)?;
        }
        if !built.account_activity_columns.is_empty() {
            field_selection.account_activity =
                parse_columns(&built.account_activity_columns).map_err(map_err)?;
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
            instruction_calls: built.instruction_selections.clone(),
            field_selection,
            max_num_instructions: params
                .max_num_instructions
                .and_then(|v| usize::try_from(v).ok()),
            ..Default::default()
        };

        let mut resp = self.run_query(&query).await?;

        // The replica serving this request has not reached the queried range,
        // so it would report negative progress. Expected around the head of a
        // load-balanced backend; the source manager backs off and fails over.
        if resp.next_slot <= query.from_slot {
            return Err(source_behind_head_err(params.from_slot));
        }

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
                &resp.instruction_calls,
                std::mem::take(&mut resp.logs),
                &built,
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
            std::mem::take(&mut resp.account_activity),
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

/// Convert only the values needed by the block-hash paginator: the advancing
/// cursor, the highest returned slot (the next page's overlap anchor), and the
/// page store.
fn block_hash_page(mut response: simple::SolanaResponse) -> Result<(i64, Option<i64>, BlockStore)> {
    let next_slot = i64::try_from(response.next_slot).context("convert next_slot")?;
    let last_slot = response
        .blocks
        .iter()
        .map(|b| i64::try_from(types::required(b.slot, "block.slot")?).context("convert slot"))
        .try_fold(None, |acc: Option<i64>, slot| {
            slot.map(|s| Some(acc.map_or(s, |a: i64| a.max(s))))
        })?;
    let block_store = BlockStore::new_svm();
    block_store.insert_svm_blocks(std::mem::take(&mut response.blocks));
    Ok((next_slot, last_slot, block_store))
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
    pub kind: Option<String>,
    pub message: Option<String>,
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
    pub path: Vec<i64>,
    pub program_id: String,
    pub accounts: Vec<String>,
    /// Raw instruction data; decoded params ride on `args` when the
    /// registration carries a Borsh schema.
    pub data: Uint8Array,
    pub is_inner: bool,
    /// Borsh-decoded args as a JS value tree (wide integers as bigint);
    /// `Some` exactly when the routed registration selected `args`. An
    /// instruction its layout rejects never becomes an item at all.
    pub args: Option<crate::param_value::ParamValue>,
    /// Logs scoped to this instruction; `Some` only when the routed
    /// registration selected `fields.log`.
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

fn project_logs(logs: &[LogItem], columns: &[&str]) -> Vec<LogItem> {
    let want_kind = columns.contains(&"kind");
    let want_message = columns.contains(&"message");
    logs.iter()
        .map(|log| LogItem {
            kind: want_kind.then(|| log.kind.clone()).flatten(),
            message: want_message.then(|| log.message.clone()).flatten(),
        })
        .collect()
}

/// Fans each committed instruction call out to every selected instruction
/// whose prefix it carries, and within each to the registrations it routes
/// to. Logs group per (slot, transactionIndex, path) and attach only to items
/// whose registration selected `fields.log`; logs without an instruction
/// address attach to no instruction (rare; usually only system messages).
/// Borsh decoding runs once per matched instruction, and only when one of its
/// routed registrations selected `args`.
fn build_event_items(
    instruction_calls: &[simple::InstructionCall],
    logs: Vec<simple::Log>,
    built: &selection::BuiltSelection,
    set_cache: &SetCache,
    client_filtered: &crate::client_filtered_contracts::ClientFilteredContracts,
    address_store: &StoreInner,
) -> Result<Vec<EventItem>> {
    let mut logs_by_key: HashMap<(u64, u32, Vec<u32>), Vec<LogItem>> = HashMap::new();
    if !built.log_columns.is_empty() {
        for log in logs {
            let (Some(slot), Some(transaction_index), Some(instruction_address)) =
                (log.slot, log.transaction_index, log.instruction_address)
            else {
                continue;
            };
            logs_by_key
                .entry((slot, transaction_index, instruction_address))
                .or_default()
                .push(LogItem {
                    kind: Some(
                        log.kind
                            .map(|kind| kind.as_str().to_string())
                            .unwrap_or_default(),
                    ),
                    message: Some(log.message.unwrap_or_default()),
                });
        }
    }

    let mut items: Vec<EventItem> = Vec::with_capacity(instruction_calls.len());
    for raw in instruction_calls {
        let instr = &selection::InstructionCall::try_from(raw)?;
        // The query filters on `tx_success`, so a failed transaction's
        // instructions shouldn't arrive at all; the guard keeps a store that
        // ignores the predicate from leaking rolled-back state changes into a
        // handler.
        if !instr.tx_success {
            continue;
        }
        let slot = i64::try_from(instr.slot).context("instruction.slot overflow")?;
        let program_key = instr.executing_account.as_bytes();
        let address = Emitter {
            key: program_key,
            owners: set_cache.owners_of(program_key),
            block: slot,
        };
        let routed = route_instruction(
            &built.instructions,
            instr,
            &address,
            client_filtered,
            address_store,
        );
        if routed.is_empty() {
            continue;
        }
        let logs = if routed
            .iter()
            .flat_map(|(_, registrations)| registrations)
            .any(|reg| !reg.log_columns.is_empty())
        {
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
        let fanned_out_from = items.len();
        for (_, registrations) in routed {
            // Every registration of an instruction shares its layout, so one
            // decode serves them all, and `None` here means none of them
            // reads args.
            let decoded = match registrations.iter().find_map(|reg| reg.args.as_ref()) {
                None => None,
                Some(schema) => match schema.decode(&instr.data) {
                    Some(args) => Some(args),
                    // This layout rejected the data, so there is nothing
                    // truthful to hand its handlers. Another instruction
                    // matching the same call decodes on its own.
                    None => continue,
                },
            };
            for reg in registrations {
                items.push(EventItem {
                    on_event_registration_index: reg.index,
                    slot,
                    transaction_index: i64::from(instr.transaction_index),
                    path: instr
                        .instruction_address
                        .iter()
                        .map(|&v| i64::from(v))
                        .collect(),
                    program_id: instr.executing_account.clone(),
                    accounts: instr.account_arguments.clone(),
                    data: instr.data.clone().into(),
                    is_inner: instr.is_inner,
                    args: decoded.clone().filter(|_| reg.args.is_some()),
                    logs: if !reg.log_columns.is_empty() {
                        logs.as_deref()
                            .map(|logs| project_logs(logs, &reg.log_columns))
                    } else {
                        None
                    },
                });
            }
        }
        // Item order within a call follows registration index whatever
        // instruction each registration hangs off.
        items[fanned_out_from..].sort_by_key(|item| item.on_event_registration_index);
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
        // Slots whose instructions were all dropped by client-side routing keep
        // a slot+hash row so every returned header still backs reorg detection.
        for b in raw_blocks.iter_mut() {
            if !b.slot.is_some_and(|slot| slots.contains(&slot)) {
                *b = simple::Block {
                    slot: b.slot,
                    blockhash: b.blockhash.take(),
                    ..Default::default()
                };
            }
        }
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
    use crate::param_value::ParamValue;
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
            instruction_calls: Some(vec![InstructionSelection {
                executing_account: Some(vec![TOKEN_METADATA_PROGRAM.into()]),
                ..Default::default()
            }]),
            max_num_instructions: Some(200),
            ..Default::default()
        };

        let resp = client.get_raw(q).await.expect("collect");
        eprintln!(
            "got {} instructions / next_slot={}",
            resp.instruction_calls.len(),
            resp.next_slot
        );
        assert!(
            !resp.instruction_calls.is_empty(),
            "expected at least one Token Metadata instruction"
        );
        for ix in resp.instruction_calls.iter().take(3) {
            assert_eq!(
                ix.executing_account.as_ref().map(ToString::to_string),
                Some(TOKEN_METADATA_PROGRAM.to_string())
            );
            assert!(!ix.data.as_deref().unwrap_or_default().is_empty());
        }
    }

    /// The error shape the client's retry loop produces on a 429: the marker
    /// arrives only as an `anyhow` context line, so the mapping is a message
    /// match rather than a typed variant.
    fn rate_limited_error() -> anyhow::Error {
        anyhow::anyhow!("")
            .context("rate limited by server (remaining=0/5 reqs, resets_in=42s)")
            .context("solana get")
    }

    #[test]
    fn a_rate_limited_query_carries_the_reset_window() {
        let error = map_query_error(
            rate_limited_error(),
            Some(RateLimitInfo {
                remaining: Some(0),
                reset_secs: Some(42),
                ..Default::default()
            }),
        );
        assert_eq!(error.reason, "RATE_LIMITED:42000");
    }

    #[test]
    fn a_rate_limit_without_a_reset_header_still_backs_off() {
        let error = map_query_error(rate_limited_error(), Some(RateLimitInfo::default()));
        assert_eq!(error.reason, "RATE_LIMITED:1000");
    }

    #[test]
    fn other_failures_keep_their_own_message() {
        let error = map_query_error(
            anyhow::anyhow!("connection reset").context("solana get"),
            Some(RateLimitInfo {
                remaining: Some(0),
                reset_secs: Some(42),
                ..Default::default()
            }),
        );
        assert!(!error.reason.starts_with("RATE_LIMITED:"), "{error}");
        assert!(error.reason.contains("connection reset"), "{error}");
    }

    fn registration(index: i64, include_logs: bool) -> selection::SvmOnEventRegistrationInput {
        selection::SvmOnEventRegistrationInput {
            index,
            is_wildcard: true,
            start_block: None,
            is_inner: None,
            account_filters: vec![],
            transaction_fields: vec![],
            block_fields: vec![],
            account_activity_fields: vec![],
            log_fields: if include_logs {
                vec!["kind".to_string(), "message".to_string()]
            } else {
                vec![]
            },
            instruction_fields: vec![],
        }
    }

    fn reads_args(
        mut registration: selection::SvmOnEventRegistrationInput,
    ) -> selection::SvmOnEventRegistrationInput {
        registration.instruction_fields = vec!["args".to_string()];
        registration
    }

    fn instruction(
        name: &str,
        discriminator: Option<&str>,
        args_json: Option<&str>,
        registrations: Vec<selection::SvmOnEventRegistrationInput>,
    ) -> selection::SvmInstructionInput {
        selection::SvmInstructionInput {
            name: name.to_string(),
            discriminator: discriminator.map(str::to_string),
            args_json: args_json.map(str::to_string),
            registrations,
        }
    }

    /// One keyed instruction of the Token Metadata program.
    fn keyed(
        index: i64,
        discriminator: &str,
        include_logs: bool,
    ) -> selection::SvmInstructionInput {
        instruction(
            &format!("I{index}"),
            Some(discriminator),
            None,
            vec![registration(index, include_logs)],
        )
    }

    fn program(name: &str, instructions: Vec<selection::SvmInstructionInput>) -> SvmProgramInput {
        SvmProgramInput {
            name: name.to_string(),
            program_id: TOKEN_METADATA_PROGRAM.to_string(),
            defined_types_json: None,
            instructions,
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

    fn build(
        store: &AddressStore,
        programs: &[SvmProgramInput],
        indexes: &[i64],
    ) -> selection::BuiltSelection {
        SelectionBuilder::from_programs(programs, &store.handle().read().unwrap())
            .unwrap()
            .build(indexes)
            .unwrap()
    }

    fn route(
        store: &AddressStore,
        set: &AddressSet,
        instructions: &[simple::InstructionCall],
        logs: Vec<simple::Log>,
        built: &selection::BuiltSelection,
    ) -> Result<Vec<EventItem>> {
        let address_store = store.handle();
        let address_store = address_store.read().unwrap();
        build_event_items(
            instructions,
            logs,
            built,
            set.cache(),
            &Default::default(),
            &address_store,
        )
    }

    fn committed_instruction(data: &[u8]) -> simple::InstructionCall {
        simple::InstructionCall {
            executing_account: Some(TOKEN_METADATA_PROGRAM.parse().unwrap()),
            account_arguments: Some(vec![]),
            data: Some(data.to_vec()),
            slot: Some(42),
            transaction_index: Some(7),
            instruction_address: Some(vec![1]),
            is_inner: Some(false),
            tx_success: Some(true),
            ..Default::default()
        }
    }

    fn decoded_args(items: &[EventItem]) -> Vec<(i64, Option<ParamValue>)> {
        items
            .iter()
            .map(|item| (item.on_event_registration_index, item.args.clone()))
            .collect()
    }

    fn amount(value: u128) -> ParamValue {
        ParamValue::Obj(vec![("amount".to_string(), ParamValue::from_u128(value))])
    }

    const AMOUNT: &str = r#"[{"name":"amount","type":"u64"}]"#;

    #[test]
    fn instructions_of_failed_transactions_are_dropped() {
        let (store, set) = fixture(&["TokenMetadata"]);
        let built = build(
            &store,
            &[program("TokenMetadata", vec![keyed(0, "0x21", false)])],
            &[0],
        );
        let committed = committed_instruction(&[0x21]);
        let mut uncommitted = committed_instruction(&[0x21]);
        uncommitted.tx_success = Some(false);
        uncommitted.transaction_index = Some(8);
        let items = route(&store, &set, &[committed, uncommitted], vec![], &built).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| (
                    i.on_event_registration_index,
                    i.transaction_index,
                    i.data.to_vec()
                ))
                .collect::<Vec<_>>(),
            vec![(0, 7, vec![0x21])]
        );
    }

    #[test]
    fn logs_attach_only_to_opted_in_registrations() {
        // Two registrations fan out from the same instruction; only the
        // `fields.log` one carries the instruction-scoped log.
        let (store, set) = fixture(&["TokenMetadata", "Other"]);
        let built = build(
            &store,
            &[
                program("TokenMetadata", vec![keyed(0, "0x21", true)]),
                program("Other", vec![keyed(1, "0x21", false)]),
            ],
            &[0, 1],
        );
        let instr = committed_instruction(&[0x21]);
        let log = simple::Log {
            slot: Some(42),
            transaction_index: Some(7),
            instruction_address: Some(vec![1]),
            kind: Some(simple::LogKind::Data),
            message: Some("hello".to_string()),
            ..Default::default()
        };
        let unscoped_log = simple::Log {
            slot: Some(42),
            transaction_index: Some(7),
            instruction_address: None,
            ..Default::default()
        };
        let items = route(&store, &set, &[instr], vec![log, unscoped_log], &built).unwrap();
        let views: Vec<(i64, Option<Vec<(Option<String>, Option<String>)>>)> = items
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
                (
                    0,
                    Some(vec![(Some("data".to_string()), Some("hello".to_string()))])
                ),
                (1, None),
            ]
        );
    }

    // Ignored: this is the standing reproduction of a gap that is still open -
    // there is no fix to assert yet, and the only key left to join on
    // (program_id) attaches a log to every invocation of that program in the
    // transaction, which is a semantic call the payload spec has to make.
    #[test]
    #[ignore = "logs of a null-instruction_address range never reach the instruction"]
    fn logs_without_an_instruction_address_still_reach_the_instruction() {
        // SQD/RPC-ingested ranges - which is what the head of Solana is served
        // from - return log rows with a null `instruction_address`, so the
        // (slot, transactionIndex, path) key matches nothing and the handler
        // gets no logs at all. Verified against solana.hypersync.xyz: at slot
        // ~441_370_000 not one log row carries the column.
        let (store, set) = fixture(&["TokenMetadata"]);
        let built = build(
            &store,
            &[program("TokenMetadata", vec![keyed(0, "0x21", true)])],
            &[0],
        );
        let instr = committed_instruction(&[0x21]);
        let log = simple::Log {
            slot: Some(42),
            transaction_index: Some(7),
            instruction_address: None,
            kind: Some(simple::LogKind::Log),
            message: Some("Instruction: Swap".to_string()),
            ..Default::default()
        };
        let items = route(&store, &set, &[instr], vec![log], &built).unwrap();
        assert_eq!(
            items[0].logs.as_ref().map(|logs| logs
                .iter()
                .map(|l| (l.kind.clone(), l.message.clone()))
                .collect::<Vec<_>>()),
            Some(vec![(
                Some("log".to_string()),
                Some("Instruction: Swap".to_string())
            )])
        );
    }

    #[test]
    fn kind_only_log_selection_omits_message() {
        let (store, set) = fixture(&["TokenMetadata"]);
        let mut kind_only = registration(0, false);
        kind_only.log_fields = vec!["kind".to_string()];
        let built = build(
            &store,
            &[program(
                "TokenMetadata",
                vec![instruction("I0", Some("0x21"), None, vec![kind_only])],
            )],
            &[0],
        );
        let instr = committed_instruction(&[0x21]);
        let log = simple::Log {
            slot: Some(42),
            transaction_index: Some(7),
            instruction_address: Some(vec![1]),
            kind: Some(simple::LogKind::Data),
            message: Some("hello".to_string()),
            ..Default::default()
        };
        let items = route(&store, &set, &[instr], vec![log], &built).unwrap();
        assert_eq!(
            items[0].logs.as_ref().map(|logs| logs
                .iter()
                .map(|l| (l.kind.clone(), l.message.clone()))
                .collect::<Vec<_>>()),
            Some(vec![(Some("data".to_string()), None)])
        );
    }

    #[test]
    fn args_reach_only_the_registrations_that_select_them() {
        // Two registrations of one instruction: the payload omits `args` for
        // the one that never reads it, so it carries nothing rather than a
        // decoded-looking empty object.
        let (store, set) = fixture(&["TokenMetadata"]);
        let built = build(
            &store,
            &[program(
                "TokenMetadata",
                vec![instruction(
                    "Create",
                    Some("0x21"),
                    Some(AMOUNT),
                    vec![reads_args(registration(0, false)), registration(1, false)],
                )],
            )],
            &[0, 1],
        );
        let instr = committed_instruction(&[0x21, 1, 0, 0, 0, 0, 0, 0, 0]);
        let items = route(&store, &set, &[instr], vec![], &built).unwrap();
        assert_eq!(decoded_args(&items), vec![(0, Some(amount(1))), (1, None)]);
    }

    #[test]
    fn selecting_args_on_an_instruction_without_a_layout_is_rejected() {
        let (store, _set) = fixture(&["TokenMetadata"]);
        let err = SelectionBuilder::from_programs(
            &[program(
                "TokenMetadata",
                vec![instruction(
                    "Bare",
                    Some("0x21"),
                    None,
                    vec![reads_args(registration(0, false))],
                )],
            )],
            &store.handle().read().unwrap(),
        )
        .err()
        .unwrap();
        assert!(
            format!("{err:#}")
                .contains("registration 0 selects `args` but instruction Bare declares none"),
            "{err:#}"
        );
    }

    // SPL Memo shape: no discriminator, the whole data is the args. It fires
    // alongside a keyed instruction of the same program that also matches.
    #[test]
    fn a_program_wide_instruction_decodes_from_offset_zero_and_fans_out_with_keyed_ones() {
        let (store, set) = fixture(&["TokenMetadata"]);
        let built = build(
            &store,
            &[program(
                "TokenMetadata",
                vec![
                    instruction(
                        "Create",
                        Some("0x21"),
                        Some(AMOUNT),
                        vec![reads_args(registration(0, false))],
                    ),
                    instruction(
                        "Any",
                        None,
                        Some(r#"[{"name":"raw","type":{"vec":"u8"}}]"#),
                        vec![reads_args(registration(1, false))],
                    ),
                ],
            )],
            &[0, 1],
        );
        let mut any_data = 2u32.to_le_bytes().to_vec();
        any_data.extend_from_slice(&[0x21, 0x01]);
        let items = route(
            &store,
            &set,
            &[
                committed_instruction(&[0x21, 1, 0, 0, 0, 0, 0, 0, 0]),
                committed_instruction(&any_data),
            ],
            vec![],
            &built,
        )
        .unwrap();
        assert_eq!(
            decoded_args(&items),
            vec![
                (0, Some(amount(1))),
                // The same call, as `Any` reads it: a 9-byte vec is what the
                // data isn't, so the layout rejects it and `Any` is skipped.
                (
                    1,
                    Some(ParamValue::Obj(vec![(
                        "raw".to_string(),
                        ParamValue::Arr(vec![ParamValue::Num(0x21.into()), ParamValue::Num(1.0)])
                    )]))
                ),
            ]
        );
    }

    // An Anchor upgrade keeps the discriminator (a hash of the name) while
    // changing the args, so two layouts share one prefix. Each call decodes
    // under exactly the layout that fits it.
    #[test]
    fn instructions_sharing_a_prefix_each_decode_with_their_own_layout() {
        let (store, set) = fixture(&["TokenMetadata"]);
        let built = build(
            &store,
            &[program(
                "TokenMetadata",
                vec![
                    instruction(
                        "SwapV1",
                        Some("0x09"),
                        Some(AMOUNT),
                        vec![reads_args(registration(0, false))],
                    ),
                    instruction(
                        "SwapV2",
                        Some("0x09"),
                        Some(r#"[{"name":"amount","type":"u64"},{"name":"minOut","type":"u64"}]"#),
                        vec![reads_args(registration(1, false))],
                    ),
                    // Reads no args, so no layout can reject it.
                    instruction("Every", None, None, vec![registration(2, false)]),
                ],
            )],
            &[0, 1, 2],
        );
        let mut v1 = vec![0x09];
        v1.extend_from_slice(&1u64.to_le_bytes());
        let mut v2 = v1.clone();
        v2.extend_from_slice(&2u64.to_le_bytes());
        let mut v2_call = committed_instruction(&v2);
        v2_call.transaction_index = Some(8);
        let items = route(
            &store,
            &set,
            &[committed_instruction(&v1), v2_call],
            vec![],
            &built,
        )
        .unwrap();
        assert_eq!(
            items
                .iter()
                .map(|item| (
                    item.transaction_index,
                    item.on_event_registration_index,
                    item.args.clone()
                ))
                .collect::<Vec<_>>(),
            vec![
                (7, 0, Some(amount(1))),
                (7, 2, None),
                (
                    8,
                    1,
                    Some(ParamValue::Obj(vec![
                        ("amount".to_string(), ParamValue::from_u128(1)),
                        ("minOut".to_string(), ParamValue::from_u128(2)),
                    ]))
                ),
                (8, 2, None),
            ]
        );
    }

    use crate::field_columns::test_support::{column, str_column};

    /// Deterministic 32-byte fixtures. The client hands pubkeys and hashes
    /// over as bytes, so a test value has to be a real key; `tag` keeps the
    /// roles apart and the low byte carries the slot.
    fn key(tag: u8, slot: u64) -> [u8; 32] {
        let mut bytes = [tag; 32];
        bytes[31] = slot as u8;
        bytes
    }

    fn fee_payer(slot: u64) -> simple::Address {
        simple::Address(key(1, slot))
    }

    fn account(slot: u64) -> simple::Address {
        simple::Address(key(2, slot))
    }

    fn mint(slot: u64) -> simple::Address {
        simple::Address(key(3, slot))
    }

    fn blockhash(slot: u64) -> simple::Hash {
        simple::Hash(key(4, slot))
    }

    // `materialize` uses `block_in_place`, which needs a multi-thread runtime.
    #[tokio::test(flavor = "multi_thread")]
    async fn store_keeps_only_the_transactions_and_balances_items_reference() {
        let tx = |slot, index| simple::Transaction {
            slot: Some(slot),
            transaction_index: Some(index),
            fee_payer: Some(fee_payer(slot)),
            ..Default::default()
        };
        let balance = |slot, index| simple::AccountActivity {
            slot: Some(slot),
            transaction_index: Some(index),
            account: Some(account(slot)),
            mint: Some(mint(slot)),
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
            | (1u64 << (crate::transaction_store::SvmTxField::AccountActivities as u32)))
            as f64;
        let cols = store
            .materialize(vec![42, 43], vec![7, 7], vec![mask, mask])
            .await
            .expect("materialize");

        let mints: Vec<Option<Vec<Option<String>>>> = match column(&cols, "accountActivities") {
            Some(crate::field_columns::Column::AccountActivities(rows)) => rows
                .iter()
                .map(|r| {
                    r.as_ref().map(|v| {
                        v.iter()
                            .map(|a| a.token.as_ref().map(|t| t.mint.clone()))
                            .collect()
                    })
                })
                .collect(),
            _ => panic!("expected an accountActivities column"),
        };
        assert_eq!(
            (str_column(&cols, "feePayer"), mints),
            (
                vec![Some(fee_payer(42).to_string()), None],
                vec![Some(vec![Some(mint(42).to_string())]), Some(vec![])],
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn native_only_activity_rows_are_kept() {
        let activity = |account: u8, mint: Option<simple::Address>| simple::AccountActivity {
            slot: Some(43),
            transaction_index: Some(7),
            account: Some(simple::Address([account; 32])),
            pre_balance: Some(100),
            post_balance: Some(90),
            mint,
            ..Default::default()
        };
        let store = build_svm_store(
            vec![simple::Transaction {
                slot: Some(43),
                transaction_index: Some(7),
                ..Default::default()
            }],
            vec![activity(1, None), activity(2, Some(mint(43)))],
            None,
        );
        let mask =
            (1u64 << (crate::transaction_store::SvmTxField::AccountActivities as u32)) as f64;
        let cols = store
            .materialize(vec![43], vec![7], vec![mask])
            .await
            .expect("materialize");
        match column(&cols, "accountActivities") {
            Some(crate::field_columns::Column::AccountActivities(accounts)) => {
                let views = accounts[0]
                    .as_ref()
                    .expect("selected row")
                    .iter()
                    .map(|a| (a.address.clone(), a.lamports.is_some(), a.token.is_some()))
                    .collect::<Vec<_>>();
                assert_eq!(
                    views,
                    vec![
                        (simple::Address([1; 32]).to_string(), true, false),
                        (simple::Address([2; 32]).to_string(), true, true),
                    ]
                );
            }
            _ => panic!("expected an accountActivities column"),
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn no_key_set_stores_the_whole_response() {
        // The raw `get` query builds no items, so it has no reference set to
        // filter by and must keep everything.
        let mut resp = simple::SolanaResponse {
            blocks: vec![simple::Block {
                slot: Some(43),
                blockhash: Some(blockhash(43)),
                ..Default::default()
            }],
            ..Default::default()
        };
        let store = build_svm_store(
            vec![simple::Transaction {
                slot: Some(43),
                transaction_index: Some(7),
                fee_payer: Some(fee_payer(43)),
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
                vec![Some(fee_payer(43).to_string())],
                vec![Some(blockhash(43).to_string())],
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn block_store_keeps_a_hash_only_row_for_unreferenced_slots() {
        let mut resp = simple::SolanaResponse {
            blocks: vec![
                simple::Block {
                    slot: Some(42),
                    blockhash: Some(blockhash(42)),
                    ..Default::default()
                },
                simple::Block {
                    slot: Some(43),
                    blockhash: Some(blockhash(43)),
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
                // Slot 43's instructions were all dropped, but its block keeps a
                // hash-only row so a fork on it can still be detected.
                vec![
                    Some(blockhash(42).to_string()),
                    Some(blockhash(43).to_string()),
                ],
            )
        );
    }
}
