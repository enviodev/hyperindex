use std::sync::{Arc, Once};

use anyhow::{Context, Result};
use hypersync_client::{
    format::{Address, LogArgument},
    net_types, simple_types, RateLimitResponse,
};

use crate::address_store::AddressSet;
use crate::chain_buffer::{
    self,
    matching::transactions::{TransactionMatcher, TransactionView},
    matching::EvmMatcher,
    page::{Page, PageData},
    selection::evm::BuiltLogSelection,
    tables::evm::LogView,
    ChainBuffer, Ecosystem, EvmRegistrations, Shared,
};
use crate::ecosystems::evm::fields::{
    block_field_missing, transaction_field_missing, BlockField, TransactionField,
};
use crate::ecosystems::evm::format::map_i64;
use crate::ecosystems::evm::rpc_fields;
use crate::sources::block_hash_pagination::{paginate_block_hashes, HashPage};
use crate::sources::failure::ClientError;
use crate::sources::request_stats::RequestStat;

pub(crate) mod config;
mod field_selection;
mod transaction_selection;
mod types;

pub(crate) use config::ClientConfig;
use field_selection::field_selection;
use net_types::LogField;
use types::RollbackGuard;

static LOGGER_INIT: Once = Once::new();

/// The client logs through the `log` facade, which has one logger per
/// process, so only the first client's filter takes effect.
fn init_logger(filter: &str) {
    LOGGER_INIT.call_once(|| {
        env_logger::Builder::new()
            .parse_filters(filter)
            .target(env_logger::Target::Pipe(Box::new(crate::tui::LogWriter)))
            .init();
    });
}

pub(crate) fn rate_limited(info: &hypersync_client::RateLimitInfo) -> ClientError {
    ClientError::RateLimited {
        reset_ms: info.suggested_wait_secs().unwrap_or(1) * 1000,
    }
}

/// The first line of a client error: the client embeds a `{:?}` dump (a full
/// backtrace when RUST_BACKTRACE is set) in its message.
pub(crate) fn first_line(error: &anyhow::Error) -> String {
    let message = format!("{error}");
    message.lines().next().unwrap_or_default().to_string()
}

pub(crate) struct EvmHyperSyncClient {
    inner: hypersync_client::Client,
    chain: Arc<Shared>,
    evm: Arc<EvmRegistrations>,
}

impl EvmHyperSyncClient {
    /// Execute one raw HyperSync page. Public methods decide how much of the
    /// response to convert for their specific caller.
    async fn get_raw(
        &self,
        query: net_types::Query,
    ) -> Result<hypersync_client::QueryResponse, ClientError> {
        let res = self
            .inner
            .get_with_rate_limit(&query)
            .await
            .context("run inner query")?;
        match res {
            RateLimitResponse::Success { response, .. } => Ok(response),
            RateLimitResponse::RateLimited(info) => Err(rate_limited(&info)),
        }
    }

    pub(crate) fn new(
        cfg: ClientConfig,
        user_agent: String,
        buffer: &ChainBuffer,
    ) -> anyhow::Result<EvmHyperSyncClient> {
        init_logger(&cfg.log_filter);
        let chain = buffer.shared();
        let evm = chain.evm()?;
        let inner = hypersync_client::Client::new_with_agent(cfg.into(), user_agent)
            .context("build client")?;
        Ok(EvmHyperSyncClient { inner, chain, evm })
    }

    pub(crate) async fn get_height(&self) -> Result<u64, ClientError> {
        self.inner.get_height().await.map_err(|error| {
            ClientError::Other(anyhow::anyhow!(
                "Failed to get HyperSync height: {}",
                first_line(&error)
            ))
        })
    }

    /// Fetch the complete inclusive range spanning `block_numbers` into one
    /// response store. Query construction, pagination, and the no-progress
    /// retry stay on the Rust side so block-only response data never needs to
    /// cross into ReScript.
    pub(crate) async fn get_block_hashes(
        &self,
        block_numbers: &[u32],
    ) -> (Result<Page, ClientError>, Vec<RequestStat>) {
        let aggregate = Page::from_data(PageData::new(Ecosystem::Evm));
        let (result, request_stats) = paginate_block_hashes(
            block_numbers,
            &aggregate,
            |request_from, to_block_exclusive| async move {
                let query = net_types::Query {
                    from_block: u64::try_from(request_from).context("from_block must be >= 0")?,
                    to_block: Some(
                        u64::try_from(to_block_exclusive).context("to_block must be >= 0")?,
                    ),
                    include_all_blocks: true,
                    field_selection: field_selection(
                        &[BlockField::Number, BlockField::Hash],
                        &[],
                        &[],
                    ),
                    ..Default::default()
                };
                let response = self.get_raw(query).await?;
                let (next, page) = block_hash_page(response)?;
                // `include_all_blocks` leaves no gaps, so the last block the
                // page covered is the one before where it stopped.
                Ok(HashPage {
                    next,
                    last_returned: Some(next - 1),
                    page,
                })
            },
        )
        .await;
        (result.map(|()| aggregate), request_stats)
    }

    pub(crate) async fn get_items(
        &self,
        params: ItemsQuery,
        address_set: &AddressSet,
        buffer: &ChainBuffer,
    ) -> Result<(ItemsResponse, Page), ClientError> {
        let client_filtered =
            crate::address_store::client_filtered_contracts::ClientFilteredContracts::from_vec(
                params.client_filtered_contracts.unwrap_or_default(),
            );
        let selects_logs = !params.on_event_registration_indexes.is_empty();
        let transaction_registrations = if params.on_transaction_registration_indexes.is_empty() {
            Vec::new()
        } else {
            self.chain.transaction_matcher.registrations()
        };
        let selects_transactions = !transaction_registrations.is_empty();
        let built_transactions = transaction_selection::build(&transaction_registrations);
        let built = self
            .evm
            .selection
            .build(
                &params.on_event_registration_indexes,
                address_set,
                &client_filtered,
            )
            .map_err(map_err)?;
        let block_query = self
            .chain
            .schedule
            .plan(
                &params.on_block_registration_indexes,
                params.from_block,
                params.to_block,
                !selects_logs && !selects_transactions,
                params.reorgable_from,
                |block, mask| buffer.has_block_fields(block, mask),
            )
            .map_err(map_err)?;
        let block_selection = &block_query.selection;
        if let Some(next_block) = block_query.unread_until() {
            let next_block = next_block as i64;
            return Ok((
                ItemsResponse {
                    // No request was made, so the source learned no height.
                    archive_height: None,
                    next_block,
                    response_blocks: 0,
                },
                Page::from_data(PageData::new(Ecosystem::Evm)),
            ));
        }

        let mut requested_transaction_fields = built.transaction_fields;
        for &field in &built_transactions.transaction_fields {
            push_unique(&mut requested_transaction_fields, field);
        }
        let mut block_fields = built.block_fields;
        // Force-add the always-required block fields, then validate the full
        // set. Validating the forced fields (not just the selection's) is what
        // guarantees the consumer's unconditional number/timestamp/hash reads
        // — the presence check, not the request, is the guarantee.
        for field in BlockField::in_store_mask(block_selection.mask())
            .into_iter()
            .chain(built_transactions.block_fields.iter().copied())
            .chain(REQUIRED_BLOCK_FIELDS.iter().copied())
        {
            if !block_fields.contains(&field) {
                block_fields.push(field);
            }
        }
        let validated_block_fields = block_fields;

        let mut transaction_fields = requested_transaction_fields.clone();
        // Transactions are accumulated into the store keyed by
        // (blockNumber, transactionIndex), so those keys must come back on each
        // transaction row whenever any transaction field is requested, or a
        // transaction handler runs on rows of none.
        if !transaction_fields.is_empty() || selects_transactions {
            for field in [
                TransactionField::BlockNumber,
                TransactionField::TransactionIndex,
            ] {
                if !transaction_fields.contains(&field) {
                    transaction_fields.push(field);
                }
            }
        }

        let logs = if selects_logs {
            built
                .log_selections
                .iter()
                .map(log_selection_from_built)
                .collect::<Result<Vec<_>>>()
                .context("parse query")
                .map_err(map_err)?
        } else {
            Vec::new()
        };
        let query = net_types::Query {
            from_block: block_query.from_block,
            to_block: block_query.to_block.map(|b| b + 1),
            logs,
            transactions: if selects_transactions {
                built_transactions.selections()
            } else {
                Vec::new()
            },
            field_selection: field_selection(
                &validated_block_fields,
                if selects_logs || selects_transactions {
                    &transaction_fields
                } else {
                    &[]
                },
                // Everything get_items reads off the log: decode inputs, the
                // flattened item fields, and the transaction-store keys.
                if selects_logs {
                    &[
                        LogField::Address,
                        LogField::Data,
                        LogField::LogIndex,
                        LogField::Topic0,
                        LogField::Topic1,
                        LogField::Topic2,
                        LogField::Topic3,
                        LogField::BlockNumber,
                        LogField::TransactionIndex,
                    ]
                } else {
                    &[]
                },
            ),
            include_all_blocks: block_query.include_all_blocks(),
            ..Default::default()
        };

        let response = self.get_raw(query).await?;
        let response_blocks = response.data.blocks.iter().map(Vec::len).sum::<usize>() as i64;

        let next_block: i64 = response
            .next_block
            .try_into()
            .context("convert next_block")
            .map_err(map_err)?;
        // The range the page covered: `include_all_blocks` leaves no gaps in it.
        let handler_blocks =
            block_selection.blocks_run_on(block_query.from_block..(next_block as u64));
        let matcher = &self.evm.matcher;
        let transaction_matcher = selects_transactions.then_some(&self.chain.transaction_matcher);
        let mut page = tokio::task::block_in_place(|| {
            process_response(
                response.data.blocks,
                response.data.transactions,
                response.data.logs,
                matcher,
                transaction_matcher,
                &validated_block_fields,
                &requested_transaction_fields,
                &handler_blocks,
            )
        })?;

        let rollback_guard = response
            .rollback_guard
            .map(RollbackGuard::try_from)
            .transpose()
            .context("convert rollback guard")
            .map_err(map_err)?;

        // The rollback guard's blocks are reorg-detection inputs like any
        // other: the guard's head block covers the tip of the scanned range,
        // and the parent of the first in-memory block the seam right below it.
        if let Some(guard) = &rollback_guard {
            add_rollback_guard_blocks(&mut page, guard).map_err(map_err)?;
        }

        let items = ItemsResponse {
            archive_height: response
                .archive_height
                .map(|h| h.try_into())
                .transpose()
                .context("convert archive_height")
                .map_err(map_err)?,
            next_block: block_query.fetched_until(next_block as u64) as i64,
            response_blocks,
        };
        Ok((items, Page::from_data(page)))
    }
}

/// The whole per-query input for `get_items` beside the partition's address
/// set: the block range and what it selects from each table. Log selections,
/// field selection, and the matching index are all derived internally from the
/// registrations passed at construction and the set.
pub(crate) struct ItemsQuery {
    pub from_block: i64,
    /// Inclusive; `None` queries to the end of available data.
    pub to_block: Option<i64>,
    /// The event registrations selecting logs, by the index the client was
    /// constructed with. Empty selects no logs.
    pub on_event_registration_indexes: Vec<i64>,
    /// The block handlers selecting blocks, by the index the client was
    /// constructed with. Empty selects no more blocks than the logs come from,
    /// unless the range reaches `reorgable_from`.
    pub on_block_registration_indexes: Vec<i64>,
    /// The transaction handlers selecting transactions. Empty selects none
    /// beyond the logs' own.
    pub on_transaction_registration_indexes: Vec<i64>,
    /// Contract names to fetch address-free even though their registrations
    /// depend on addresses (client-side filtering). Absent or empty
    /// means every address-dependent contract is filtered server-side.
    pub client_filtered_contracts: Option<Vec<String>>,
    /// Blocks at or above this number can still be reorged on the chain. A
    /// page reaching them must link to the page before it for reorg
    /// detection, so it reads every block of its range. Absent when the whole
    /// range is final.
    pub reorgable_from: Option<i64>,
}

fn log_selection_from_built(built: &BuiltLogSelection) -> Result<net_types::LogSelection> {
    let address = built
        .addresses()
        .iter()
        .map(|address| Address::try_from(address.as_str()))
        .collect::<std::result::Result<Vec<_>, _>>()
        .context("Failed to parse address")?;
    let mut topics = arrayvec::ArrayVec::new();
    for topic_vec in &built.topics {
        if topics.is_full() {
            anyhow::bail!("Log filter has more than 4 topics");
        }
        let parsed_topics = topic_vec
            .iter()
            .map(|topic| LogArgument::try_from(topic.as_str()))
            .collect::<std::result::Result<Vec<_>, _>>()
            .context("Failed to parse topic")?;
        topics.push(parsed_topics);
    }
    Ok(net_types::LogSelection::new(net_types::LogFilter {
        address,
        address_filter: None,
        topics,
    }))
}

/// What a page covered. Its rows are in the `Page` returned beside it.
pub(crate) struct ItemsResponse {
    pub archive_height: Option<i64>,
    pub next_block: i64,
    /// Blocks the server returned for this query, before the page drops the
    /// ones no kept log joins to. The server returns one block per number, so this is a
    /// distinct count.
    pub response_blocks: i64,
}

/// Convert only the two values needed by the block-hash paginator. Raw blocks
/// move directly into the response store without constructing napi block DTOs.
fn block_hash_page(mut response: hypersync_client::QueryResponse) -> Result<(i64, PageData)> {
    let next_block = response
        .next_block
        .try_into()
        .context("convert next_block")?;
    let mut page = PageData::new(Ecosystem::Evm);
    let mut rows = page.blocks.builder();
    for block in std::mem::take(&mut response.data.blocks).iter().flatten() {
        chain_buffer::tables::evm::push_block(&mut rows, block, 0);
    }
    page.add_blocks(rows.finish());
    Ok((next_block, page))
}

/// The guard's head block, with its time, and the parent of the first block
/// the server holds in memory.
fn add_rollback_guard_blocks(page: &mut PageData, guard: &RollbackGuard) -> Result<()> {
    let mut rows = page.blocks.builder();
    chain_buffer::tables::evm::push_observed_block(
        &mut rows,
        u64::try_from(guard.block_number).context("guard block_number negative")?,
        Some(&chain_buffer::tables::evm::hash_bytes(&guard.hash)?),
        u64::try_from(guard.timestamp).ok(),
    );
    if guard.first_block_number > 0 {
        chain_buffer::tables::evm::push_observed_block(
            &mut rows,
            (guard.first_block_number - 1) as u64,
            Some(&chain_buffer::tables::evm::hash_bytes(
                &guard.first_parent_hash,
            )?),
            None,
        );
    }
    page.add_blocks(rows.finish());
    Ok(())
}

pub(super) fn push_unique<T: PartialEq>(values: &mut Vec<T>, value: T) {
    if !values.contains(&value) {
        values.push(value);
    }
}

/// Keys sorted and deduplicated, looked up by binary search.
fn sorted_set<T: Ord>(mut keys: Vec<T>) -> Vec<T> {
    keys.sort_unstable();
    keys.dedup();
    keys
}

/// Builds the page: the logs some registration matches now, the
/// transactions they belong to or a transaction handler runs on, and the
/// blocks of the range, each validated for the fields the query asked for. A
/// block a kept row or a block handler reads keeps every field fetched; any
/// other keeps its number, hash and time for reorg detection and progress.
/// Returns `ConvertError::MissingFields` when the source omitted a requested
/// non-nullable field or a joined row.
#[allow(clippy::too_many_arguments)]
fn process_response(
    blocks: Vec<Vec<simple_types::Block>>,
    transactions: Vec<Vec<simple_types::Transaction>>,
    logs: Vec<Vec<simple_types::Log>>,
    matcher: &EvmMatcher,
    transaction_matcher: Option<&TransactionMatcher>,
    validated_block_fields: &[BlockField],
    requested_transaction_fields: &[TransactionField],
    handler_blocks: &[u64],
) -> std::result::Result<PageData, ConvertError> {
    let mut missing: Vec<String> = Vec::new();
    let mut page = PageData::new(Ecosystem::Evm);

    let mut referenced_transactions: Vec<(u64, u32)> = Vec::new();
    let mut registering_blocks = Vec::new();
    let mut log_rows = page.events.builder();
    {
        let store = matcher.read_store();
        for log in logs.iter().flatten() {
            let block_number = u64::from(log.block_number.context("log.blockNumber missing")?);
            let transaction_index = u64::from(
                log.transaction_index
                    .context("log.transactionIndex missing")?,
            ) as u32;
            let address = log.address.as_ref().context("log.address missing")?;
            let view = LogView {
                block_number,
                address: address.as_slice(),
                topics: std::array::from_fn(|position| {
                    log.topics
                        .get(position)
                        .and_then(Option::as_ref)
                        .map(|topic| topic.as_slice())
                }),
            };
            let found = matcher.classify(&view, &store);
            if !found.kept {
                continue;
            }
            if found.registers {
                registering_blocks.push(block_number);
            }
            referenced_transactions.push((block_number, transaction_index));
            chain_buffer::tables::evm::push_log(&mut log_rows, log)?;
        }
    }
    page.add_events(log_rows.finish());
    page.add_registering_blocks(registering_blocks);

    let referenced_transactions = sorted_set(referenced_transactions);
    let mut handled_transactions: Vec<(u64, u32)> = Vec::new();
    if !requested_transaction_fields.is_empty() || transaction_matcher.is_some() {
        let fetched = rpc_fields::tx_mask(requested_transaction_fields);
        let mut kept = Vec::new();
        let mut rows = page.transactions.builder();
        for tx in transactions.iter().flatten() {
            // A row without its key backs no log; if a kept log wanted it, the
            // coverage check below reports the transaction missing. A
            // transaction selection returned it as one the handlers may run on,
            // and nothing later would notice it dropped.
            let (Some(block_number), Some(transaction_index)) =
                (tx.block_number, tx.transaction_index)
            else {
                if transaction_matcher.is_some() {
                    let name = if tx.block_number.is_none() {
                        "blockNumber"
                    } else {
                        "transactionIndex"
                    };
                    push_unique(&mut missing, format!("transaction.{name}"));
                }
                continue;
            };
            let key = (u64::from(block_number), u64::from(transaction_index) as u32);
            let handled = transaction_matcher.is_some_and(|transaction_matcher| {
                transaction_matcher.matches_any(&TransactionView::of_transaction(tx, fetched))
            });
            if handled {
                handled_transactions.push(key);
            } else if referenced_transactions.binary_search(&key).is_err() {
                continue;
            }
            for &field in requested_transaction_fields {
                if let Some(name) = transaction_field_missing(tx, field) {
                    push_unique(&mut missing, format!("transaction.{}", name));
                }
            }
            kept.push(key);
            chain_buffer::tables::evm::push_transaction(&mut rows, tx, fetched)?;
        }
        page.add_transactions(rows.finish());
        let kept = sorted_set(kept);
        for key in &referenced_transactions {
            if kept.binary_search(key).is_err() {
                push_unique(&mut missing, "transaction".into());
            }
        }
    }

    let returned_blocks: Vec<&simple_types::Block> = blocks.iter().flatten().collect();
    let present_block_numbers =
        sorted_set(returned_blocks.iter().filter_map(|b| b.number).collect());
    let referenced_blocks = sorted_set(
        referenced_transactions
            .iter()
            .chain(&handled_transactions)
            .map(|(block_number, _)| *block_number)
            .chain(handler_blocks.iter().copied())
            .collect(),
    );
    let is_referenced = |number: u64| referenced_blocks.binary_search(&number).is_ok();
    for block in &returned_blocks {
        let referenced = block.number.is_some_and(is_referenced);
        for &field in validated_block_fields {
            if !referenced && !REQUIRED_BLOCK_FIELDS.contains(&field) {
                continue;
            }
            if let Some(name) = block_field_missing(block, field) {
                push_unique(&mut missing, format!("block.{}", name));
            }
        }
    }
    if !validated_block_fields.is_empty() {
        for block_number in &referenced_blocks {
            if present_block_numbers.binary_search(block_number).is_err() {
                push_unique(&mut missing, "block".into());
            }
        }
    }
    if !missing.is_empty() {
        return Err(ConvertError::MissingFields(missing));
    }

    let fetched = BlockField::store_mask(validated_block_fields);
    let mut rows = page.blocks.builder();
    for block in returned_blocks {
        if block.number.is_some_and(is_referenced) {
            chain_buffer::tables::evm::push_block(&mut rows, block, fetched);
        } else if let Some(number) = block.number {
            chain_buffer::tables::evm::push_observed_block(
                &mut rows,
                number,
                block.hash.as_ref().map(|hash| hash.as_slice()),
                block
                    .timestamp
                    .as_ref()
                    .and_then(|time| map_i64(&Some(time)).ok().flatten())
                    .map(|time| time as u64),
            );
        }
    }
    page.add_blocks(rows.finish());
    Ok(page)
}

/// How converting a response into a page fails.
#[derive(Debug)]
pub(crate) enum ConvertError {
    MissingFields(Vec<String>),
    Other(anyhow::Error),
}

impl From<anyhow::Error> for ConvertError {
    fn from(e: anyhow::Error) -> Self {
        Self::Other(e)
    }
}

impl From<ConvertError> for ClientError {
    fn from(error: ConvertError) -> Self {
        match error {
            ConvertError::MissingFields(fields) => ClientError::MissingFields(fields),
            ConvertError::Other(error) => ClientError::Other(error),
        }
    }
}

/// Block fields the indexer always needs: `number` keys the page's blocks and
/// lets items reference them; the consumer reads `timestamp` and `hash` off
/// every block unconditionally. Force-added to the query and validated for
/// presence regardless of the user's selection.
const REQUIRED_BLOCK_FIELDS: &[BlockField] =
    &[BlockField::Number, BlockField::Timestamp, BlockField::Hash];

fn map_err(e: anyhow::Error) -> ClientError {
    ClientError::Other(e)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::address_store::test_support::evm_store;
    use crate::chain_buffer::matching::ContractRegisters;
    use crate::chain_buffer::schedule::BlockHandlerInput;
    use crate::chain_buffer::tables::table::make_key;
    use crate::ecosystems::evm::fields::{EvmBlockField, EvmTxField};
    use hypersync_client::simple_types;

    fn empty_matcher() -> EvmMatcher {
        EvmMatcher::new(&[], ContractRegisters::default(), &evm_store(&[])).unwrap()
    }

    // Matches `full_log` (zero topic0, one topic, empty data) to a wildcard
    // registration, so success-path tests keep a log: an unmatched one is
    // dropped.
    fn zero_event_matcher() -> EvmMatcher {
        EvmMatcher::new(
            &[
                crate::ecosystems::evm::registration::OnEventRegistrationInput {
                    index: 0,
                    sighash: Some(format!("0x{}", "00".repeat(32))),
                    topic_count: 1,
                    event_name: "Zero".to_string(),
                    contract_name: "Zero".to_string(),
                    is_wildcard: true,
                    depends_on_addresses: false,
                    start_block: None,
                    topic_filters: vec![crate::ecosystems::evm::topic_filter::TopicFilterInput {
                        topic0: Some(vec![format!("0x{}", "00".repeat(32))]),
                        topic1: Some(vec![]),
                        topic2: Some(vec![]),
                        topic3: Some(vec![]),
                    }],
                    block_fields: vec![],
                    transaction_fields: vec![],
                    params: vec![],
                },
            ],
            ContractRegisters::default(),
            &evm_store(&[("Zero", &[])]),
        )
        .unwrap()
    }

    fn logged_blocks(page: &PageData) -> Vec<u64> {
        page.events
            .rows_in_block_range(0, 1 << 30)
            .map(|row| row.block_number())
            .collect()
    }

    fn full_log(block_number: u64) -> simple_types::Log {
        simple_types::Log {
            log_index: Some(0.into()),
            block_number: Some(block_number.into()),
            transaction_index: Some(0u64.into()),
            address: Some(Default::default()),
            data: Some(Default::default()),
            topics: std::iter::once(Some(Default::default())).collect(),
            ..Default::default()
        }
    }

    /// Same shape as `full_log`, but on a topic0 no fixture registration pins —
    /// so it routes nowhere.
    fn unmatched_log(block_number: u64) -> simple_types::Log {
        let mut topic0 = [0u8; 32];
        topic0[31] = 1;
        let topic0 = hypersync_client::format::LogArgument::from(topic0);
        simple_types::Log {
            topics: std::iter::once(Some(topic0)).collect(),
            ..full_log(block_number)
        }
    }

    #[test]
    fn missing_block_field_returns_typed_error() {
        // The server returned no block for the log but the user asked for
        // block.number/hash/timestamp.
        let err = process_response(
            vec![],
            vec![],
            vec![vec![full_log(1)]],
            &zero_event_matcher(),
            None,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[],
            &[],
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => assert_eq!(fields, vec!["block".to_string()]),
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn missing_block_field_named_path() {
        // block is present but timestamp is not.
        let block = simple_types::Block {
            number: Some(1),
            hash: Some(Default::default()),
            ..Default::default()
        };
        let err = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &empty_matcher(),
            None,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[],
            &[],
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => {
                assert_eq!(fields, vec!["block.timestamp".to_string()])
            }
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn forced_block_fields_validated_even_when_user_requested_none() {
        // get_items force-adds REQUIRED_BLOCK_FIELDS and validates that
        // forced set, so number/timestamp/hash are guaranteed present even when
        // the user's config selected no block fields. Here the user requested
        // nothing yet a missing timestamp is still reported.
        let block = simple_types::Block {
            number: Some(1),
            hash: Some(Default::default()),
            ..Default::default()
        };
        let err = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &empty_matcher(),
            None,
            REQUIRED_BLOCK_FIELDS,
            &[],
            &[],
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => {
                assert_eq!(fields, vec!["block.timestamp".to_string()])
            }
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn nullable_block_field_not_reported() {
        // BaseFeePerGas is inherently nullable — server omitting it must not
        // trigger MissingFields, regardless of whether the user requested it.
        // base_fee_per_gas left None
        let block = simple_types::Block {
            number: Some(1),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            ..Default::default()
        };
        let page = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &zero_event_matcher(),
            None,
            &[
                BlockField::Number,
                BlockField::Hash,
                BlockField::Timestamp,
                BlockField::BaseFeePerGas,
            ],
            &[],
            &[],
        )
        .expect("expected success when only nullable fields are absent");
        assert_eq!(page.events.len(), 1);
    }

    #[test]
    fn missing_transaction_field_with_transaction_present() {
        let block = simple_types::Block {
            number: Some(1),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            ..Default::default()
        };
        // The transaction is keyed to the log by (blockNumber, txIndex) but is
        // missing the requested hash, so transaction.hash is reported missing.
        let tx = simple_types::Transaction {
            block_number: Some(1u64.into()),
            transaction_index: Some(0u64.into()),
            ..Default::default()
        };
        let err = process_response(
            vec![vec![block]],
            vec![vec![tx]],
            vec![vec![full_log(1)]],
            &zero_event_matcher(),
            None,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::Hash],
            &[],
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => {
                assert_eq!(fields, vec!["transaction.hash".to_string()])
            }
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn missing_transaction_when_not_returned() {
        // Transaction fields requested but the source returned no transaction for
        // the log's (blockNumber, txIndex).
        let block = simple_types::Block {
            number: Some(1),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            ..Default::default()
        };
        let err = process_response(
            vec![vec![block]],
            vec![],
            vec![vec![full_log(1)]],
            &zero_event_matcher(),
            None,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::Hash],
            &[],
        )
        .err()
        .expect("expected MissingFields error");

        match err {
            ConvertError::MissingFields(fields) => {
                assert_eq!(fields, vec!["transaction".to_string()])
            }
            ConvertError::Other(e) => panic!("unexpected ConvertError::Other: {e:?}"),
        }
    }

    #[test]
    fn full_join_matches_block_and_transaction() {
        // Block and transaction live in separate response arrays; the log is
        // matched to its block by number and the transaction lands in the store
        // keyed by (blockNumber, txIndex). The page carries one deduplicated block.
        let block = simple_types::Block {
            number: Some(7),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            ..Default::default()
        };

        let tx = simple_types::Transaction {
            block_number: Some(7u64.into()),
            transaction_index: Some(0u64.into()),
            ..Default::default()
        };

        let page = process_response(
            vec![vec![block]],
            vec![vec![tx]],
            vec![vec![full_log(7)]],
            &zero_event_matcher(),
            None,
            &[BlockField::Number, BlockField::Hash, BlockField::Timestamp],
            &[TransactionField::BlockNumber],
            &[],
        )
        .expect("expected success when block and transaction join");

        assert_eq!(logged_blocks(&page), vec![7]);
    }

    #[test]
    fn unmatched_logs_keep_a_hash_only_block_and_no_transaction() {
        // Block 1's log matches; block 2's doesn't. Both blocks and both
        // transactions come back from the server. Block 1 is kept in full and
        // its transaction kept; block 2's transaction is dropped, but the block
        // keeps a hash-only row so a fork on it can still be detected.
        let block = |number: u64| simple_types::Block {
            number: Some(number),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            ..Default::default()
        };
        let tx = |block_number: u64| simple_types::Transaction {
            block_number: Some(block_number.into()),
            transaction_index: Some(0u64.into()),
            hash: Some(Default::default()),
            ..Default::default()
        };

        let page = process_response(
            vec![vec![block(1), block(2)]],
            vec![vec![tx(1), tx(2)]],
            vec![vec![full_log(1), unmatched_log(2)]],
            &zero_event_matcher(),
            None,
            REQUIRED_BLOCK_FIELDS,
            &[TransactionField::Hash],
            &[],
        )
        .expect("expected success");

        let transaction_hash = |block_number: u64| {
            page.transactions
                .find(make_key(block_number, 0), 0)
                .and_then(|row| row.bytes_at(EvmTxField::Hash as usize).map(<[u8]>::len))
        };
        let block_hash = |block_number: u64| {
            page.blocks
                .find(make_key(block_number, 0), 0)
                .and_then(|row| row.bytes_at(EvmBlockField::Hash as usize).map(<[u8]>::len))
        };
        assert_eq!(
            (
                logged_blocks(&page),
                [transaction_hash(1), transaction_hash(2)],
                [block_hash(1), block_hash(2)],
            ),
            (
                vec![1],
                // Block 2's transaction is dropped (never read)...
                [Some(32), None],
                // ...but its block keeps a hash-only row for reorg detection.
                [Some(32), Some(32)],
            )
        );
    }

    #[test]
    fn unmatched_logs_do_not_demand_their_block_and_transaction() {
        // The mirror of `missing_transaction_when_not_returned`: the source
        // returned neither the block nor the transaction for this log, but it
        // routes nowhere, so nothing will ever read them and the page stands.
        // Without this, filtering the stores would silently diverge from what
        // the coverage check still insists the source deliver.
        let page = process_response(
            vec![],
            vec![],
            vec![vec![unmatched_log(1)]],
            &zero_event_matcher(),
            None,
            REQUIRED_BLOCK_FIELDS,
            &[TransactionField::Hash],
            &[],
        )
        .expect("an unmatched log's absent block and transaction are not missing fields");

        assert_eq!(page.events.len(), 0);
    }

    #[test]
    fn unreferenced_block_is_judged_only_on_its_required_fields() {
        // Block 2 backs no item, so its absent `gasUsed` can't fail the page —
        // nothing can read it. The required trio is still demanded of every
        // returned block, referenced or not.
        let block = |number: u64| simple_types::Block {
            number: Some(number),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            gas_used: (number == 1).then(Default::default),
            ..Default::default()
        };
        let page = process_response(
            vec![vec![block(1), block(2)]],
            vec![],
            vec![vec![full_log(1), unmatched_log(2)]],
            &zero_event_matcher(),
            None,
            &[
                BlockField::Number,
                BlockField::Hash,
                BlockField::Timestamp,
                BlockField::GasUsed,
            ],
            &[],
            &[],
        )
        .expect("an unreferenced block's absent selected field is not a missing field");

        assert_eq!(page.events.len(), 1);
    }

    #[test]
    fn keyless_transaction_is_dropped_unjudged() {
        // The source returned a transaction with no (blockNumber, txIndex), so
        // it joins to nothing; its absent `hash` must not fail a page whose
        // matched item got the transaction it asked for.
        let block = simple_types::Block {
            number: Some(1),
            hash: Some(Default::default()),
            timestamp: Some(Default::default()),
            ..Default::default()
        };

        let keyless = simple_types::Transaction {
            hash: None,
            ..Default::default()
        };

        let page = process_response(
            vec![vec![block]],
            vec![vec![
                simple_types::Transaction {
                    block_number: Some(1u64.into()),
                    transaction_index: Some(0u64.into()),
                    hash: Some(Default::default()),
                    ..Default::default()
                },
                keyless,
            ]],
            vec![vec![full_log(1)]],
            &zero_event_matcher(),
            None,
            REQUIRED_BLOCK_FIELDS,
            &[TransactionField::Hash],
            &[],
        )
        .expect("a keyless transaction's absent field is not a missing field");

        assert_eq!(page.events.len(), 1);
    }

    #[test]
    fn missing_fields_reach_the_caller_by_name() {
        let error: ClientError = ConvertError::MissingFields(vec![
            "block.timestamp".to_string(),
            "transaction.hash".to_string(),
        ])
        .into();
        assert!(matches!(
            error,
            ClientError::MissingFields(fields)
                if fields == vec!["block.timestamp".to_string(), "transaction.hash".to_string()]
        ));
    }

    #[test]
    fn a_dropped_access_or_authorization_list_is_still_reported_missing() {
        // HyperSync serves both lists as columns, an empty one for a
        // transaction that has none, so a null here is the response dropping a
        // selected field rather than the transaction's shape.
        let tx = simple_types::Transaction::default();
        assert_eq!(
            (
                transaction_field_missing(&tx, TransactionField::AccessList),
                transaction_field_missing(&tx, TransactionField::AuthorizationList),
            ),
            (Some("accessList"), Some("authorizationList"))
        );
    }

    fn hash_handler_mask() -> u64 {
        (1 << EvmBlockField::Number as u32) | (1 << EvmBlockField::Hash as u32)
    }

    /// A block handler selecting the hash every 10 blocks from 10, beside a
    /// buffer an event query already filled with blocks 10 and 20 and their
    /// hashes.
    async fn blocks_only_queries(ranges: &[(i64, i64)]) -> (Vec<i64>, Vec<Option<i64>>) {
        let server = crate::sources::testing::mock_hypersync_server::MockHyperSyncServer::new(
            Some(1000),
            None,
        )
        .unwrap();
        let blocks: Vec<serde_json::Value> = (0..=1000)
            .map(|number| serde_json::json!({"number": number, "timestamp": number, "hash": format!("0x{number:064x}")}))
            .collect();
        server
            .serve_chain(serde_json::json!({"blocks": blocks, "logs": []}).to_string())
            .unwrap();
        let store = evm_store(&[]);
        let handler = BlockHandlerInput {
            index: 0,
            start_block: 10,
            end_block: None,
            interval: 10,
            block_field_mask: Some(hash_handler_mask() as f64),
        };
        let buffer = ChainBuffer::make(
            chain_buffer::ChainBufferConfig {
                registrations: crate::chain_buffer::RegistrationsInput::Evm {
                    registrations: vec![],
                },
                should_checksum: false,
                contract_register_indexes: vec![],
                block_handlers: vec![handler],
                transaction_masks: vec![],
                event_block_masks: vec![],
                transaction_registrations: vec![],
            },
            &store,
        )
        .unwrap();
        let client = EvmHyperSyncClient::new(
            ClientConfig {
                url: server.url(),
                api_token: "00000000-0000-0000-0000-000000000000".to_string(),
                http_req_timeout_millis: 10_000,
                serialization_format: config::SerializationFormat::Json,
                enable_query_caching: false,
                log_filter: "error".to_string(),
            },
            "test".to_string(),
            &buffer,
        )
        .unwrap();
        let mut fetched = PageData::new(Ecosystem::Evm);
        let mut rows = fetched.blocks.builder();
        for number in [10u64, 20] {
            let block = simple_types::Block {
                number: Some(number),
                hash: Some([number as u8; 32].into()),
                ..Default::default()
            };
            chain_buffer::tables::evm::push_block(&mut rows, &block, hash_handler_mask());
        }
        fetched.add_blocks(rows.finish());
        buffer.merge_page(&Page::from_data(fetched), 0, false);

        let mut next_blocks = Vec::new();
        for (from_block, to_block) in ranges {
            let (response, _page) = client
                .get_items(
                    ItemsQuery {
                        from_block: *from_block,
                        to_block: Some(*to_block),
                        on_event_registration_indexes: vec![],
                        on_block_registration_indexes: vec![0],
                        on_transaction_registration_indexes: vec![],
                        client_filtered_contracts: None,
                        reorgable_from: None,
                    },
                    &store.empty_set(),
                    &buffer,
                )
                .await
                .unwrap();
            next_blocks.push(response.next_block);
        }
        let requested_from = server
            .take_queries()
            .iter()
            .map(|query| {
                serde_json::from_str::<serde_json::Value>(query).unwrap()["from_block"].as_i64()
            })
            .collect();
        (next_blocks, requested_from)
    }

    const TOKEN: &str = "0x1000000000000000000000000000000000000001";
    const SENDER: &str = "0x2000000000000000000000000000000000000002";

    /// A client over a served chain of blocks 0..=100, with an event, a
    /// transaction and a block registration.
    fn served_client() -> (
        crate::sources::testing::mock_hypersync_server::MockHyperSyncServer,
        EvmHyperSyncClient,
        ChainBuffer,
        crate::address_store::AddressStore,
    ) {
        let server = crate::sources::testing::mock_hypersync_server::MockHyperSyncServer::new(
            Some(100),
            None,
        )
        .unwrap();
        let blocks: Vec<serde_json::Value> = (0..=100)
            .map(|number| serde_json::json!({"number": number, "timestamp": number, "hash": format!("0x{number:064x}")}))
            .collect();
        server
            .serve_chain(serde_json::json!({"blocks": blocks, "logs": []}).to_string())
            .unwrap();
        let store = evm_store(&[("Token", &[TOKEN])]);
        let transfer_topic0 = format!("0x{}", "ab".repeat(32));
        let buffer = ChainBuffer::make(
            chain_buffer::ChainBufferConfig {
                registrations: crate::chain_buffer::RegistrationsInput::Evm {
                    registrations: vec![
                        crate::ecosystems::evm::registration::OnEventRegistrationInput {
                            index: 0,
                            sighash: Some(transfer_topic0.clone()),
                            topic_count: 3,
                            event_name: "Transfer".to_string(),
                            contract_name: "Token".to_string(),
                            is_wildcard: false,
                            depends_on_addresses: true,
                            start_block: None,
                            topic_filters: vec![
                                crate::ecosystems::evm::topic_filter::TopicFilterInput {
                                    topic0: Some(vec![transfer_topic0]),
                                    topic1: Some(vec![format!("0x{:0>64}", &SENDER[2..])]),
                                    topic2: Some(vec![]),
                                    topic3: Some(vec![]),
                                },
                            ],
                            block_fields: vec![],
                            transaction_fields: vec![],
                            params: vec![],
                        },
                    ],
                },
                should_checksum: false,
                contract_register_indexes: vec![],
                block_handlers: vec![BlockHandlerInput {
                    index: 0,
                    start_block: 0,
                    end_block: None,
                    interval: 10,
                    block_field_mask: Some(hash_handler_mask() as f64),
                }],
                transaction_masks: vec![(1 << EvmTxField::Hash as u64) as f64],
                event_block_masks: vec![0.0],
                transaction_registrations: vec![
                    crate::chain_buffer::matching::transactions::OnTransactionRegistrationInput {
                        index: 0,
                        from: Some(vec![SENDER.to_string()]),
                        to: None,
                        status: Some(1),
                        transaction_field_mask: (1 << EvmTxField::Hash as u64) as f64,
                        block_field_mask: 0.0,
                    },
                ],
            },
            &store,
        )
        .unwrap();
        let client = EvmHyperSyncClient::new(
            ClientConfig {
                url: server.url(),
                api_token: "00000000-0000-0000-0000-000000000000".to_string(),
                http_req_timeout_millis: 10_000,
                serialization_format: config::SerializationFormat::Json,
                enable_query_caching: false,
                log_filter: "error".to_string(),
            },
            "test".to_string(),
            &buffer,
        )
        .unwrap();
        (server, client, buffer, store)
    }

    fn sent_queries(
        server: &crate::sources::testing::mock_hypersync_server::MockHyperSyncServer,
    ) -> Vec<serde_json::Value> {
        server
            .take_queries()
            .iter()
            .map(|query| serde_json::from_str(query).unwrap())
            .collect()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_items_query_sends_its_log_transaction_and_block_selections() {
        let (server, client, buffer, store) = served_client();
        client
            .get_items(
                ItemsQuery {
                    from_block: 0,
                    to_block: Some(49),
                    on_event_registration_indexes: vec![0],
                    on_block_registration_indexes: vec![0],
                    on_transaction_registration_indexes: vec![0],
                    client_filtered_contracts: None,
                    reorgable_from: None,
                },
                &crate::address_store::test_support::set_of(&store, &["Token"]),
                &buffer,
            )
            .await
            .unwrap();
        assert_eq!(
            sent_queries(&server),
            vec![serde_json::json!({
                "from_block": 0,
                "to_block": 50,
                "logs": [{
                    "address": [TOKEN],
                    "topics": [
                        [format!("0x{}", "ab".repeat(32))],
                        [format!("0x{:0>64}", &SENDER[2..])],
                        [],
                        [],
                    ],
                }],
                "transactions": [{"from": [SENDER], "status": 1}],
                "include_all_blocks": true,
                "field_selection": {
                    "block": ["hash", "number", "timestamp"],
                    "transaction": ["block_number", "from", "hash", "status", "transaction_index"],
                    "log": [
                        "address",
                        "block_number",
                        "data",
                        "log_index",
                        "topic0",
                        "topic1",
                        "topic2",
                        "topic3",
                        "transaction_index",
                    ],
                },
            })]
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_block_hash_query_selects_every_block_of_its_range() {
        let (server, client, _buffer, _store) = served_client();
        let (result, _stats) = client.get_block_hashes(&[5, 7]).await;
        result.unwrap();
        assert_eq!(
            sent_queries(&server),
            vec![serde_json::json!({
                "from_block": 5,
                "to_block": 8,
                "include_all_blocks": true,
                "field_selection": {"block": ["hash", "number"]},
            })]
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_blocks_only_query_requests_only_the_handler_blocks_the_buffer_lacks() {
        assert_eq!(
            blocks_only_queries(&[(10, 25), (10, 35)]).await,
            (vec![26, 36], vec![Some(30)])
        );
    }
}
