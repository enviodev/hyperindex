use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use anyhow::{Context, Result};

pub(crate) mod config;
mod transaction_counts;

use hypersync_client_solana::from_arrow::blocks_from_arrow;
use hypersync_client_solana::simple_types as simple;
use hypersync_client_solana::RateLimitInfo;
use hypersync_solana_net_types::field_selection::{BlockField, SolanaFieldSelection};
use hypersync_solana_net_types::query::SolanaQuery;

use crate::chain_buffer::matching::svm::SvmMatcher;
use crate::chain_buffer::page::{Page, PageData};
use crate::chain_buffer::selection::svm as selection;
use crate::chain_buffer::selection::svm_fields as fields;
use crate::chain_buffer::tables::svm::{
    push_block, push_instruction, push_transaction, InstructionRow, InstructionView, SvmBlockField,
    SvmTransactionCounts,
};
use crate::chain_buffer::{ChainBuffer, Ecosystem, Shared, SvmRegistrations};
use crate::ecosystems::svm::types;
use crate::sources::block_hash_pagination::{paginate_block_hashes, HashPage};
use crate::sources::failure::ClientError;
use crate::sources::request_stats::RequestStat;
pub(crate) use config::SvmClientConfig;

/// The marker the client leaves in the error chain on a 429. It exposes no
/// typed variant for a rate limit — the 429 is folded into an `anyhow` context
/// line — so the message is the only signal.
const RATE_LIMITED_MARKER: &str = "rate limited by server";

/// Map a failed query to the marker `SourceManager` backs off on when the
/// server rate limited it, and to a plain failure otherwise. `rate_limit` is
/// the client's state, which it refreshed from the same response's headers.
fn map_query_error(error: anyhow::Error, rate_limit: Option<RateLimitInfo>) -> ClientError {
    if !format!("{error:?}").contains(RATE_LIMITED_MARKER) {
        return map_err(error);
    }
    // A 429 without a reset header still has to back off, or the source would
    // spin straight back into the closed window.
    let reset_secs = rate_limit
        .and_then(|info| info.suggested_wait_secs())
        .unwrap_or(1);
    ClientError::RateLimited {
        reset_ms: reset_secs * 1000,
    }
}

impl SvmHyperSyncClient {
    /// Run one query, surfacing a rate limit to the source manager rather than
    /// sleeping it out inside the call.
    async fn run_query(&self, query: &SolanaQuery) -> Result<simple::SolanaResponse, ClientError> {
        self.inner
            .get(query)
            .await
            .context("solana get")
            .map_err(|e| map_query_error(e, self.inner.rate_limit_info()))
    }

    /// Run a `transaction_counts::query`, tallying its transaction rows
    /// without decoding them.
    async fn run_counting_query(&self, query: &SolanaQuery) -> Result<CountedPage, ClientError> {
        let response = self
            .inner
            .get_arrow(query)
            .await
            .context("solana get")
            .map_err(|e| map_query_error(e, self.inner.rate_limit_info()))?;
        let tables = &response.data.tables;
        let blocks = tables
            .get("blocks")
            .map(blocks_from_arrow)
            .transpose()
            .context("decode blocks")
            .map_err(map_err)?
            .unwrap_or_default();
        let counts = tables
            .get("transactions")
            .map(transaction_counts::count_by_slot)
            .transpose()
            .context("count transactions")
            .map_err(map_err)?
            .unwrap_or_default();
        Ok(CountedPage {
            next_slot: response.next_slot,
            blocks,
            counts,
        })
    }
}

pub(crate) struct SvmHyperSyncClient {
    inner: Arc<hypersync_client_solana::Client>,
    chain: Arc<Shared>,
    /// The chain's registrations, matched against what a query returns so a
    /// page keeps only the instructions some registration takes.
    svm: Arc<SvmRegistrations>,
}

impl SvmHyperSyncClient {
    pub(crate) fn new(
        cfg: SvmClientConfig,
        user_agent: String,
        buffer: &ChainBuffer,
    ) -> anyhow::Result<SvmHyperSyncClient> {
        let chain = buffer.shared();
        let svm = chain.svm()?;
        let inner = hypersync_client_solana::Client::new_with_agent(cfg.into(), user_agent)
            .context("build solana client")?;
        Ok(SvmHyperSyncClient {
            inner: Arc::new(inner),
            chain,
            svm,
        })
    }

    pub(crate) async fn get_height(&self) -> Result<u64, ClientError> {
        self.inner.get_height().await.map_err(map_err)
    }

    /// Fetch the inclusive range spanning `block_numbers` into one page. Each
    /// advancing cursor proves its half-open range was processed; missing
    /// block rows inside that coverage are skipped slots.
    pub(crate) async fn get_block_hashes(
        &self,
        block_numbers: &[u32],
    ) -> (Result<Page, ClientError>, Vec<RequestStat>) {
        let aggregate = Page::from_data(PageData::new(Ecosystem::Svm));
        let (result, request_stats) = paginate_block_hashes(
            block_numbers,
            &aggregate,
            |request_from, to_slot_exclusive| {
                async move {
                    let query = block_hash_query(request_from, to_slot_exclusive)
                        .context("parse solana query")
                        .map_err(map_err)?;
                    let response = self.run_query(&query).await?;
                    let (next, last_returned, mut page) =
                        block_hash_page(response).map_err(map_err)?;
                    // Each advancing cursor proves its half-open range was
                    // processed; block rows missing inside it are skipped slots.
                    // A cursor that didn't advance proves nothing — leave it to
                    // the paginator, which reports it as a source behind the
                    // head rather than a malformed coverage range.
                    if next > request_from {
                        page.add_covered(request_from as u64, next.min(to_slot_exclusive) as u64);
                    }
                    Ok(HashPage {
                        next,
                        last_returned,
                        page,
                    })
                }
            },
        )
        .await;
        (result.map(|()| aggregate), request_stats)
    }

    pub(crate) async fn get_items(
        &self,
        params: ItemsQuery,
    ) -> Result<(ItemsResponse, Page), ClientError> {
        let built = self
            .svm
            .selection
            .build(&params.on_event_registration_indexes)
            .map_err(map_err)?;
        let selects_instructions = !params.on_event_registration_indexes.is_empty();
        let block_query = self
            .chain
            .schedule
            .plan(
                &params.on_block_registration_indexes,
                params.from_slot,
                params.to_slot,
                !selects_instructions,
                params.reorgable_from,
                |_, _| false,
            )
            .map_err(map_err)?;
        let block_selection = &block_query.selection;
        if let Some(next_slot) = block_query.unread_until() {
            return Ok((
                ItemsResponse {
                    next_slot: next_slot as i64,
                },
                Page::from_data(PageData::new(Ecosystem::Svm)),
            ));
        }
        let from_slot = block_query.from_block;
        let mut block_columns = built.block_columns.clone();
        for column in fields::block_mask_columns(block_selection.mask()).map_err(map_err)? {
            fields::push_unique(&mut block_columns, column);
        }

        let mut field_selection = SolanaFieldSelection {
            block: parse_columns(&block_columns).map_err(map_err)?,
            // Instructions are exempt from merge-mode "empty = no rows", so an
            // empty list would fetch every column. Spell the matching set.
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
            from_slot,
            // Inclusive on the boundary, exclusive on the wire.
            to_slot: block_query
                .to_block
                .map(|b| b.checked_add(1).context("to_slot overflow"))
                .transpose()
                .map_err(map_err)?,
            instruction_calls: built.instruction_selections.clone(),
            field_selection,
            include_all_blocks: block_query.include_all_blocks(),
            ..Default::default()
        };

        let counts_transactions =
            block_selection.mask() & SvmBlockField::TRANSACTION_COUNTS_MASK != 0;
        let (mut resp, transaction_counts) = if counts_transactions {
            // Selections of different tables intersect: beside instruction
            // selections, one matching every transaction would return only the
            // transactions those instructions are in and undercount the slot.
            // The fetch state keeps slot handlers in a partition of their own,
            // so no query selects both.
            if selects_instructions {
                return Err(map_err(anyhow::anyhow!(
                    "A query counting the transactions of its slots can't also select instructions"
                )));
            }
            let counted = self
                .run_counting_query(&transaction_counts::query(
                    from_slot,
                    query.to_slot,
                    query.field_selection.block,
                ))
                .await?;
            let resp = simple::SolanaResponse {
                next_slot: counted.next_slot,
                blocks: counted.blocks,
                ..Default::default()
            };
            (resp, Some(counted.counts))
        } else {
            (self.run_query(&query).await?, None)
        };

        // The replica serving this request has not reached the queried range,
        // so it would report negative progress. Expected around the head of a
        // load-balanced backend; the source manager backs off and fails over.
        if resp.next_slot <= from_slot {
            return Err(ClientError::BehindHead {
                block_number: from_slot,
            });
        }

        let handler_slots = block_selection.blocks_run_on(from_slot..resp.next_slot);
        let matcher = &self.svm.matcher;
        let page = tokio::task::block_in_place(|| {
            build_page(
                &mut resp,
                &built,
                matcher,
                &handler_slots,
                transaction_counts.as_ref(),
            )
        })
        .map_err(map_err)?;
        let response = ItemsResponse {
            next_slot: i64::try_from(block_query.fetched_until(resp.next_slot))
                .context("next_slot overflow")
                .map_err(map_err)?,
        };
        Ok((response, Page::from_data(page)))
    }
}

/// What a `transaction_counts::query` page answers with.
struct CountedPage {
    next_slot: u64,
    blocks: Vec<simple::Block>,
    counts: HashMap<u64, SvmTransactionCounts>,
}

fn block_hash_query(from_slot: i64, to_slot_exclusive: i64) -> Result<SolanaQuery> {
    Ok(SolanaQuery {
        from_slot: u64::try_from(from_slot).context("from_slot must be non-negative")?,
        to_slot: Some(u64::try_from(to_slot_exclusive).context("to_slot must be non-negative")?),
        include_all_blocks: true,
        field_selection: SolanaFieldSelection {
            block: vec![BlockField::Slot, BlockField::Blockhash],
            ..Default::default()
        },
        ..Default::default()
    })
}

/// Convert only the values needed by the block-hash paginator: the advancing
/// cursor, the highest returned slot (the next page's overlap anchor), and the
/// page.
fn block_hash_page(response: simple::SolanaResponse) -> Result<(i64, Option<i64>, PageData)> {
    let next_slot = i64::try_from(response.next_slot).context("convert next_slot")?;
    let last_slot = response
        .blocks
        .iter()
        .map(|b| i64::try_from(types::required(b.slot, "block.slot")?).context("convert slot"))
        .try_fold(None, |acc: Option<i64>, slot| {
            slot.map(|s| Some(acc.map_or(s, |a: i64| a.max(s))))
        })?;
    let mut page = PageData::new(Ecosystem::Svm);
    let mut rows = page.blocks.builder();
    for block in &response.blocks {
        push_block(&mut rows, block, None);
    }
    page.add_blocks(rows.finish());
    Ok((next_slot, last_slot, page))
}

/// The whole per-query input for `get_items`: the slot range and what it
/// selects from each table. Instruction selections and field selection are
/// derived internally from the registrations passed at construction.
pub(crate) struct ItemsQuery {
    pub from_slot: i64,
    /// Inclusive; `None` queries to the end of available data.
    pub to_slot: Option<i64>,
    /// The instruction registrations selecting instructions, by index. Empty
    /// selects no instructions.
    pub on_event_registration_indexes: Vec<i64>,
    /// The slot handlers selecting blocks, by index.
    pub on_block_registration_indexes: Vec<i64>,
    /// Slots at or above this one can still be reorged on the chain. A
    /// page reaching them must link to the page before it for reorg
    /// detection, so it reads every slot of its range. Absent when the whole
    /// range is final.
    pub reorgable_from: Option<i64>,
}

/// What a page covered. Its rows are in the `Page` returned beside it.
pub(crate) struct ItemsResponse {
    pub next_slot: i64,
}

type CallKey = (u64, u32, Vec<u32>);

/// Builds the page: the instructions some registration matches now, the
/// transactions they belong to with the accounts those touched, and the
/// blocks of the range. A slot a kept instruction or a block handler reads
/// keeps every field fetched; any other keeps slot, hash and time — the hash
/// backs reorg detection, and the time tells a slot that produced a block
/// from one the chain skipped. The program logs of a kept instruction ride
/// on its row.
fn build_page(
    resp: &mut simple::SolanaResponse,
    built: &selection::BuiltSelection,
    matcher: &SvmMatcher,
    handler_slots: &[u64],
    transaction_counts: Option<&HashMap<u64, SvmTransactionCounts>>,
) -> Result<PageData> {
    let mut page = PageData::new(Ecosystem::Svm);
    let reads_logs = !built.log_columns.is_empty();
    let mut logs_by_call: HashMap<CallKey, Vec<(String, String)>> = HashMap::new();
    if reads_logs {
        for log in std::mem::take(&mut resp.logs) {
            // Logs without an instruction address attach to no instruction.
            let (Some(slot), Some(transaction_index), Some(path)) =
                (log.slot, log.transaction_index, log.instruction_address)
            else {
                continue;
            };
            logs_by_call
                .entry((slot, transaction_index, path))
                .or_default()
                .push((
                    log.kind
                        .map(|kind| kind.as_str().to_string())
                        .unwrap_or_default(),
                    log.message.unwrap_or_default(),
                ));
        }
    }

    let mut referenced_transactions: HashSet<(u64, u32)> = HashSet::new();
    let mut registering_slots = Vec::new();
    let mut rows = page.events.builder();
    {
        let store = matcher.read_store();
        for raw in &resp.instruction_calls {
            let call = selection::InstructionCall::try_from(raw)?;
            // The query filters on `tx_success`, so a failed transaction's
            // instructions shouldn't arrive at all; the guard keeps a store
            // that ignores the predicate from leaking rolled-back state changes
            // into a handler.
            if !call.tx_success {
                continue;
            }
            let view = InstructionView {
                slot: call.slot,
                transaction_index: call.transaction_index,
                path: 0,
                program_id: &call.executing_account,
                accounts: call.account_arguments.clone(),
                data: &call.data,
                is_inner: call.is_inner,
                logs: None,
            };
            let found = matcher.classify(&view, &store);
            if !found.kept {
                continue;
            }
            if found.registers {
                registering_slots.push(call.slot);
            }
            referenced_transactions.insert((call.slot, call.transaction_index));
            let logs = reads_logs.then(|| {
                logs_by_call
                    .get(&(
                        call.slot,
                        call.transaction_index,
                        call.instruction_address.clone(),
                    ))
                    .cloned()
                    .unwrap_or_default()
            });
            push_instruction(
                &mut rows,
                &InstructionRow {
                    slot: call.slot,
                    transaction_index: call.transaction_index,
                    path: &call.instruction_address,
                    program_id: &call.executing_account,
                    accounts: raw
                        .account_arguments
                        .is_some()
                        .then_some(call.account_arguments.as_slice()),
                    data: &call.data,
                    is_inner: call.is_inner,
                    logs: logs.as_deref(),
                },
            )?;
        }
    }
    page.add_events(rows.finish());
    page.add_registering_blocks(registering_slots);

    let reads_activity = !built.account_activity_columns.is_empty();
    let mut activities: HashMap<(u64, u32), Vec<&simple::AccountActivity>> = HashMap::new();
    for row in &resp.account_activity {
        if let (Some(slot), Some(index), Some(_)) = (row.slot, row.transaction_index, row.account) {
            if referenced_transactions.contains(&(slot, index)) {
                activities.entry((slot, index)).or_default().push(row);
            }
        }
    }
    let mut kept: HashSet<(u64, u32)> = HashSet::new();
    let mut rows = page.transactions.builder();
    for transaction in &resp.transactions {
        let (Some(slot), Some(index)) = (transaction.slot, transaction.transaction_index) else {
            continue;
        };
        if !referenced_transactions.contains(&(slot, index)) || !kept.insert((slot, index)) {
            continue;
        }
        let touched = reads_activity.then(|| activities.remove(&(slot, index)).unwrap_or_default());
        push_transaction(&mut rows, transaction, touched.as_deref())?;
    }
    // Account activity of a transaction the query read no other field of
    // still needs a row to ride on.
    for ((slot, index), touched) in activities {
        if kept.contains(&(slot, index)) {
            continue;
        }
        let bare = simple::Transaction {
            slot: Some(slot),
            transaction_index: Some(index),
            ..Default::default()
        };
        push_transaction(&mut rows, &bare, Some(&touched))?;
    }
    page.add_transactions(rows.finish());

    let mut referenced_slots: HashSet<u64> = referenced_transactions
        .iter()
        .map(|(slot, _)| *slot)
        .collect();
    referenced_slots.extend(handler_slots.iter().copied());
    let mut rows = page.blocks.builder();
    for block in &resp.blocks {
        let slot = types::required(block.slot, "block.slot")?;
        types::required(block.blockhash.as_ref(), "block.blockhash")?;
        if referenced_slots.contains(&slot) {
            // A handler counting transactions reads the slot's tally; a block
            // the response holds no transaction of stored none.
            let counts = transaction_counts
                .filter(|_| handler_slots.binary_search(&slot).is_ok())
                .map(|counts| counts.get(&slot).copied().unwrap_or_default());
            push_block(&mut rows, block, counts);
        } else {
            let observed = simple::Block {
                slot: block.slot,
                blockhash: block.blockhash,
                block_time: block.block_time,
                ..Default::default()
            };
            push_block(&mut rows, &observed, None);
        }
    }
    page.add_blocks(rows.finish());
    Ok(page)
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

fn map_err(e: anyhow::Error) -> ClientError {
    ClientError::Other(e)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::svm_store;
    use crate::address_store::AddressStore;
    use crate::chain_buffer::matching::ContractRegisters;
    use crate::chain_buffer::tables::svm::{block_columns, transaction_columns, SvmTxField};
    use crate::chain_buffer::tables::table::make_key;
    use crate::chain_buffer::walk::Item;
    use crate::chain_buffer::{ChainBuffer, ChainBufferConfig};
    use crate::js_value::test_value::JsValue;
    use hypersync_solana_net_types::query::InstructionSelection;
    use selection::SvmProgramInput;

    const TOKEN_METADATA_PROGRAM: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

    /// Live test against `solana.hypersync.xyz`. Run with:
    ///     cargo test -p envio --lib svm_hypersync_source::tests -- --ignored --nocapture
    #[tokio::test]
    #[ignore]
    async fn live_query_token_metadata() {
        let client = SvmHyperSyncClient::new(
            SvmClientConfig {
                url: "https://solana.hypersync.xyz".into(),
                api_token: String::new(),
                http_req_timeout_millis: 30_000,
            },
            "hyperindex-test".into(),
            &ChainBuffer::make(
                crate::chain_buffer::ChainBufferConfig {
                    registrations: crate::chain_buffer::RegistrationsInput::Svm {
                        programs: vec![],
                    },
                    should_checksum: false,
                    contract_register_indexes: vec![],
                    block_handlers: vec![],
                    transaction_masks: vec![],
                    event_block_masks: vec![],
                    transaction_registrations: vec![],
                },
                &svm_store(&[]),
            )
            .expect("build buffer"),
        )
        .expect("build client");

        let height = client.get_height().await.expect("get_height") as i64;
        eprintln!("current slot: {}", height);
        let from = height.saturating_sub(10_000).max(0);

        let q = SolanaQuery {
            from_slot: from as u64,
            to_slot: Some(height as u64),
            instruction_calls: vec![InstructionSelection {
                executing_account: vec![TOKEN_METADATA_PROGRAM.parse().unwrap()],
                ..Default::default()
            }],
            ..Default::default()
        };

        let resp = client.run_query(&q).await.expect("collect");
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

    #[test]
    fn a_block_hash_query_selects_every_slot_of_its_range() {
        assert_eq!(
            serde_json::to_value(block_hash_query(5, 8).unwrap()).unwrap(),
            serde_json::json!({
                "from_slot": 5,
                "to_slot": 8,
                "instruction_calls": [],
                "transactions": [],
                "logs": [],
                "account_activity": [],
                "include_all_blocks": true,
                "field_selection": {
                    "block": ["slot", "blockhash"],
                    "transaction": [],
                    "instruction_call": [],
                    "log": [],
                    "account_activity": [],
                    "reward": [],
                },
                "max_num_blocks": null,
                "max_num_transactions": null,
                "max_num_instructions": null,
                "max_num_logs": null,
                "max_num_account_activity": null,
            })
        );
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
        assert!(matches!(
            error,
            ClientError::RateLimited { reset_ms: 42_000 }
        ));
    }

    #[test]
    fn a_rate_limit_without_a_reset_header_still_backs_off() {
        let error = map_query_error(rate_limited_error(), Some(RateLimitInfo::default()));
        assert!(matches!(
            error,
            ClientError::RateLimited { reset_ms: 1_000 }
        ));
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
        assert!(
            matches!(&error, ClientError::Other(error) if format!("{error:#}").contains("connection reset")),
            "{error:?}"
        );
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

    /// A store holding the program id for `TokenMetadata`; every other named
    /// program exists without addresses.
    fn store_of(programs: &[SvmProgramInput]) -> AddressStore {
        let mut entries: Vec<(&str, &[&str])> = Vec::new();
        for program in programs {
            if !entries.iter().any(|(name, _)| *name == program.name) {
                let addresses: &[&str] = if program.name == "TokenMetadata" {
                    &[TOKEN_METADATA_PROGRAM]
                } else {
                    &[]
                };
                entries.push((program.name.as_str(), addresses));
            }
        }
        svm_store(&entries)
    }

    /// The page a response becomes for a query selecting every registration.
    fn page_of(
        store: &AddressStore,
        programs: &[SvmProgramInput],
        response: &mut simple::SolanaResponse,
    ) -> PageData {
        let builder =
            selection::SelectionBuilder::from_programs(programs, &store.handle().read().unwrap())
                .unwrap();
        let built = builder.build(&builder.registration_indexes()).unwrap();
        let matcher = SvmMatcher::new(&builder, ContractRegisters::default(), store).unwrap();
        build_page(response, &built, &matcher, &[], None).unwrap()
    }

    /// The items a response builds once its page is in a chain's buffer.
    fn items_of(
        programs: &[SvmProgramInput],
        instructions: Vec<simple::InstructionCall>,
        logs: Vec<simple::Log>,
    ) -> Vec<Item> {
        let store = store_of(programs);
        let mut response = simple::SolanaResponse {
            instruction_calls: instructions,
            logs,
            ..Default::default()
        };
        let page = page_of(&store, programs, &mut response);
        let buffer = ChainBuffer::make(
            ChainBufferConfig {
                registrations: crate::chain_buffer::RegistrationsInput::Svm {
                    programs: programs.to_vec(),
                },
                should_checksum: false,
                contract_register_indexes: vec![],
                block_handlers: vec![],
                transaction_masks: vec![],
                event_block_masks: vec![],
                transaction_registrations: vec![],
            },
            &store,
        )
        .unwrap();
        buffer.merge_page(&Page::from_data(page), 0, false);
        buffer.build_items_for_test(0, 1000)
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

    /// `(transaction index, registration, args)` of each instruction item.
    fn decoded_args(items: &[Item]) -> Vec<(u32, u32, Option<JsValue>)> {
        items
            .iter()
            .map(|item| match item {
                Item::Svm {
                    transaction_index,
                    registration,
                    args,
                    ..
                } => (
                    *transaction_index,
                    *registration,
                    args.as_ref().map(JsValue::of),
                ),
                _ => panic!("expected an instruction item"),
            })
            .collect()
    }

    fn logs_of(items: &[Item]) -> Vec<(u32, Option<JsValue>)> {
        items
            .iter()
            .map(|item| match item {
                Item::Svm {
                    registration, logs, ..
                } => (*registration, logs.as_ref().map(JsValue::of)),
                _ => panic!("expected an instruction item"),
            })
            .collect()
    }

    fn amount(value: u128) -> JsValue {
        JsValue::obj([("amount", JsValue::uint(value))])
    }

    const AMOUNT: &str = r#"[{"name":"amount","type":"u64"}]"#;

    fn log(kind: Option<simple::LogKind>, message: &str, path: Option<Vec<u32>>) -> simple::Log {
        simple::Log {
            slot: Some(42),
            transaction_index: Some(7),
            instruction_address: path,
            kind,
            message: Some(message.to_string()),
            ..Default::default()
        }
    }

    fn log_value(kind: Option<&str>, message: Option<&str>) -> JsValue {
        JsValue::obj([
            ("kind", kind.map_or(JsValue::Undefined, JsValue::str)),
            ("message", message.map_or(JsValue::Undefined, JsValue::str)),
        ])
    }

    #[test]
    fn instructions_of_failed_transactions_are_dropped() {
        let committed = committed_instruction(&[0x21]);
        let mut uncommitted = committed_instruction(&[0x21]);
        uncommitted.tx_success = Some(false);
        uncommitted.transaction_index = Some(8);
        let items = items_of(
            &[program("TokenMetadata", vec![keyed(0, "0x21", false)])],
            vec![committed, uncommitted],
            vec![],
        );
        assert_eq!(decoded_args(&items), vec![(7, 0, None)]);
    }

    #[test]
    fn logs_attach_only_to_opted_in_registrations() {
        // Two registrations fan out from the same instruction; only the
        // `fields.log` one carries the instruction-scoped log. A log without
        // an instruction address attaches to no instruction.
        let items = items_of(
            &[
                program("TokenMetadata", vec![keyed(0, "0x21", true)]),
                program("Other", vec![keyed(1, "0x21", false)]),
            ],
            vec![committed_instruction(&[0x21])],
            vec![
                log(Some(simple::LogKind::Data), "hello", Some(vec![1])),
                log(None, "unscoped", None),
            ],
        );
        assert_eq!(
            logs_of(&items),
            vec![
                (
                    0,
                    Some(JsValue::Arr(vec![log_value(Some("data"), Some("hello"))]))
                ),
                (1, None),
            ]
        );
    }

    #[test]
    fn kind_only_log_selection_omits_message() {
        let mut kind_only = registration(0, false);
        kind_only.log_fields = vec!["kind".to_string()];
        let items = items_of(
            &[program(
                "TokenMetadata",
                vec![instruction("I0", Some("0x21"), None, vec![kind_only])],
            )],
            vec![committed_instruction(&[0x21])],
            vec![log(Some(simple::LogKind::Data), "hello", Some(vec![1]))],
        );
        assert_eq!(
            logs_of(&items),
            vec![(0, Some(JsValue::Arr(vec![log_value(Some("data"), None)])))]
        );
    }

    #[test]
    fn args_reach_only_the_registrations_that_select_them() {
        // Two registrations of one instruction: the payload omits `args` for
        // the one that never reads it, so it carries nothing rather than a
        // decoded-looking empty object.
        let items = items_of(
            &[program(
                "TokenMetadata",
                vec![instruction(
                    "Create",
                    Some("0x21"),
                    Some(AMOUNT),
                    vec![reads_args(registration(0, false)), registration(1, false)],
                )],
            )],
            vec![committed_instruction(&[0x21, 1, 0, 0, 0, 0, 0, 0, 0])],
            vec![],
        );
        assert_eq!(
            decoded_args(&items),
            vec![(7, 0, Some(amount(1))), (7, 1, None)]
        );
    }

    #[test]
    fn a_declared_layout_filters_calls_even_when_args_are_unselected() {
        let mut trailing = vec![0x21];
        trailing.extend_from_slice(&1u64.to_le_bytes());
        trailing.push(0);
        let at = |index: u32, data: &[u8]| {
            let mut call = committed_instruction(data);
            call.transaction_index = Some(index);
            call
        };
        let items = items_of(
            &[program(
                "TokenMetadata",
                vec![instruction(
                    "Create",
                    Some("0x21"),
                    Some(AMOUNT),
                    vec![registration(0, false)],
                )],
            )],
            vec![
                at(7, &[0x21]),
                at(8, &trailing),
                at(9, &[0x21, 1, 0, 0, 0, 0, 0, 0, 0]),
            ],
            vec![],
        );
        assert_eq!(decoded_args(&items), vec![(9, 0, None)]);
    }

    // SPL Memo shape: no discriminator, the whole data is the args. It fires
    // alongside a keyed instruction of the same program that also matches.
    #[test]
    fn a_program_wide_instruction_decodes_from_offset_zero_and_fans_out_with_keyed_ones() {
        let mut any_data = 2u32.to_le_bytes().to_vec();
        any_data.extend_from_slice(&[0x21, 0x01]);
        let mut any_call = committed_instruction(&any_data);
        any_call.transaction_index = Some(8);
        let items = items_of(
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
            vec![
                committed_instruction(&[0x21, 1, 0, 0, 0, 0, 0, 0, 0]),
                any_call,
            ],
            vec![],
        );
        assert_eq!(
            decoded_args(&items),
            vec![
                (7, 0, Some(amount(1))),
                (
                    8,
                    1,
                    Some(JsValue::obj([("raw", JsValue::Bytes(vec![0x21, 0x01]))]))
                ),
            ]
        );
    }

    // An empty layout is the assertion that the instruction takes no
    // arguments, which is what separates the bare form of a call from the one
    // carrying a payload under the same prefix. Declaring no layout takes both.
    #[test]
    fn an_empty_layout_takes_only_the_calls_that_carry_no_payload() {
        let mut with_amount = vec![0x09];
        with_amount.extend_from_slice(&7u64.to_le_bytes());
        let mut payload_call = committed_instruction(&with_amount);
        payload_call.transaction_index = Some(8);
        let items = items_of(
            &[program(
                "TokenMetadata",
                vec![
                    instruction(
                        "Bare",
                        Some("0x09"),
                        Some("[]"),
                        vec![registration(0, false)],
                    ),
                    instruction(
                        "WithAmount",
                        Some("0x09"),
                        Some(AMOUNT),
                        vec![reads_args(registration(1, false))],
                    ),
                    instruction("Every", Some("0x09"), None, vec![registration(2, false)]),
                ],
            )],
            vec![committed_instruction(&[0x09]), payload_call],
            vec![],
        );
        // The bare call reaches `Bare` and `Every`; the payload call reaches
        // `WithAmount` and `Every`, never `Bare`.
        assert_eq!(
            decoded_args(&items)
                .into_iter()
                .map(|(index, registration, _)| (index, registration))
                .collect::<Vec<_>>(),
            vec![(7, 0), (7, 2), (8, 1), (8, 2)]
        );
    }

    // An Anchor upgrade keeps the discriminator (a hash of the name) while
    // changing the args, so two layouts share one prefix. Each call decodes
    // under exactly the layout that fits it.
    #[test]
    fn instructions_sharing_a_prefix_each_decode_with_their_own_layout() {
        let mut v1 = vec![0x09];
        v1.extend_from_slice(&1u64.to_le_bytes());
        let mut v2 = v1.clone();
        v2.extend_from_slice(&2u64.to_le_bytes());
        let mut v2_call = committed_instruction(&v2);
        v2_call.transaction_index = Some(8);
        let items = items_of(
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
                    // Declares no layout, so nothing can reject it.
                    instruction("Every", None, None, vec![registration(2, false)]),
                ],
            )],
            vec![committed_instruction(&v1), v2_call],
            vec![],
        );
        assert_eq!(
            decoded_args(&items),
            vec![
                (7, 0, Some(amount(1))),
                (7, 2, None),
                (
                    8,
                    1,
                    Some(JsValue::obj([
                        ("amount", JsValue::uint(1u64)),
                        ("minOut", JsValue::uint(2u64)),
                    ]))
                ),
                (8, 2, None),
            ]
        );
    }

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

    fn block(slot: u64, time: i64) -> simple::Block {
        simple::Block {
            slot: Some(slot),
            blockhash: Some(blockhash(slot)),
            block_time: Some(time),
            block_height: Some(slot * 10),
            ..Default::default()
        }
    }

    fn reads_activity(
        mut registration: selection::SvmOnEventRegistrationInput,
    ) -> selection::SvmOnEventRegistrationInput {
        registration.transaction_fields = vec!["feePayer".to_string()];
        registration.account_activity_fields = vec!["token.mint".to_string()];
        registration
    }

    fn mask(fields: &[SvmTxField]) -> u64 {
        fields
            .iter()
            .fold(0, |mask, field| mask | 1 << *field as u32)
    }

    #[test]
    fn the_page_keeps_only_the_transactions_balances_and_blocks_its_instructions_reference() {
        let programs = [program(
            "TokenMetadata",
            vec![instruction(
                "I0",
                Some("0x21"),
                None,
                vec![reads_activity(registration(0, false))],
            )],
        )];
        let store = store_of(&programs);
        let transaction = |slot| simple::Transaction {
            slot: Some(slot),
            transaction_index: Some(7),
            fee_payer: Some(fee_payer(slot)),
            ..Default::default()
        };
        let activity = |slot, index, account: simple::Address, mint: Option<simple::Address>| {
            simple::AccountActivity {
                slot: Some(slot),
                transaction_index: Some(7),
                account_index: Some(index),
                account: Some(account),
                pre_balance: Some(100),
                post_balance: Some(90),
                mint,
                ..Default::default()
            }
        };
        // Only (42, 7) carries a matched instruction; (43, 7) and slot 43 came
        // back on the same response unreferenced.
        let mut response = simple::SolanaResponse {
            instruction_calls: vec![committed_instruction(&[0x21])],
            transactions: vec![transaction(42), transaction(43)],
            account_activity: vec![
                activity(42, 1, simple::Address([9; 32]), Some(mint(42))),
                activity(42, 0, account(42), None),
                activity(43, 0, account(43), Some(mint(43))),
            ],
            blocks: vec![block(42, 4200), block(43, 4300)],
            ..Default::default()
        };
        let page = page_of(&store, &programs, &mut response);

        let transactions: Vec<_> = [42, 43]
            .iter()
            .map(|slot| page.transactions.find(make_key(*slot, 7), 0))
            .collect();
        let selected = mask(&[SvmTxField::FeePayer, SvmTxField::AccountActivities]);
        let columns = transaction_columns(&transactions, &[7, 7], &[selected, selected]).unwrap();
        let described: Vec<String> = columns
            .columns
            .iter()
            .map(|(name, column)| match column {
                crate::chain_buffer::deliver::Column::Str(values) => format!("{name} {values:?}"),
                crate::chain_buffer::deliver::Column::AccountActivities(rows) => format!(
                    "{name} {:?}",
                    rows.iter()
                        .map(|row| row.as_ref().map(|activities| activities
                            .iter()
                            .map(|a| (
                                a.address.clone(),
                                a.lamports.is_some(),
                                a.token.as_ref().map(|t| t.mint.clone())
                            ))
                            .collect::<Vec<_>>()))
                        .collect::<Vec<_>>()
                ),
                _ => name.to_string(),
            })
            .collect();

        let blocks: Vec<_> = [42, 43]
            .iter()
            .map(|slot| page.blocks.find(make_key(*slot, 0), 0))
            .collect();
        let block_mask = (1 << SvmBlockField::Time as u32)
            | (1 << SvmBlockField::Hash as u32)
            | (1 << SvmBlockField::Height as u32);
        let blocks = block_columns(&blocks, &[42, 43], &[block_mask, block_mask]).unwrap();
        let blocks: Vec<String> = blocks
            .columns
            .iter()
            .map(|(name, column)| match column {
                crate::chain_buffer::deliver::Column::I64(values) => format!("{name} {values:?}"),
                crate::chain_buffer::deliver::Column::Str(values) => format!("{name} {values:?}"),
                _ => name.to_string(),
            })
            .collect();

        assert_eq!(
            (described, blocks),
            (
                vec![
                    format!("feePayer {:?}", vec![Some(fee_payer(42).to_string()), None]),
                    format!(
                        "accountActivities {:?}",
                        vec![
                            Some(vec![
                                (account(42).to_string(), true, None),
                                (
                                    simple::Address([9; 32]).to_string(),
                                    true,
                                    Some(mint(42).to_string())
                                ),
                            ]),
                            Some(vec![]),
                        ]
                    ),
                ],
                vec![
                    "time [Some(4200), Some(4300)]".to_string(),
                    format!(
                        "hash {:?}",
                        vec![
                            Some(blockhash(42).to_string()),
                            Some(blockhash(43).to_string())
                        ]
                    ),
                    // Slot 43 keeps only what reorg detection and skipped-slot
                    // reads need of it.
                    "height [Some(420), None]".to_string(),
                ],
            )
        );
    }

    #[test]
    fn a_slot_handler_runs_without_a_block_on_a_slot_the_chain_skipped() {
        let store = svm_store(&[]);
        let buffer = ChainBuffer::make(
            ChainBufferConfig {
                registrations: crate::chain_buffer::RegistrationsInput::Svm { programs: vec![] },
                should_checksum: false,
                contract_register_indexes: vec![],
                block_handlers: vec![crate::chain_buffer::schedule::BlockHandlerInput {
                    index: 0,
                    start_block: 10,
                    end_block: None,
                    interval: 1,
                    block_field_mask: Some((1u64 << SvmBlockField::Hash as u32) as f64),
                }],
                transaction_masks: vec![],
                event_block_masks: vec![],
                transaction_registrations: vec![],
            },
            &store,
        )
        .unwrap();
        let (_, _, page) = block_hash_page(simple::SolanaResponse {
            next_slot: 13,
            blocks: vec![block(10, 100), block(12, 120)],
            ..Default::default()
        })
        .unwrap();
        buffer.merge_page(&Page::from_data(page), 0, false);
        let skipped: Vec<(u64, bool)> = buffer
            .build_items_for_test(10, 12)
            .iter()
            .map(|item| match item {
                Item::Block {
                    block_number,
                    skipped,
                    ..
                } => (block_number.to_owned(), skipped.to_owned()),
                _ => panic!("expected a block item"),
            })
            .collect();
        assert_eq!(skipped, vec![(10, false), (11, true), (12, false)]);
    }
}
