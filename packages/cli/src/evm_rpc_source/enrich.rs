//! Fills a page's block and transaction stores for the logs a query returned.
//! `plan_blocks` and `plan_transactions` decide what that costs in requests.
//!
//! Serving a field from the store rather than refetching it is safe wherever
//! reorgs are handled at all: every log's own `blockHash` enters the page as an
//! observation, so a stored row belonging to a dead fork disagrees with this
//! response and the merge reports a reorg before any event is materialised.
//! Where the merge proceeds regardless — detect-only mode, or a fork deeper
//! than the configured reorg window — the hash is corrected but the row's other
//! fields keep the dead fork's values until the row is pruned. Both are already
//! "reorgs not handled"; this is one more way that shows.
//!
//! What the store must never answer is the range's own boundary blocks — they
//! are the observations that comparison rests on, and the store holds only an
//! earlier response's view of them.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use futures_util::future::join_all;
use hypersync_client::format::{self, Hex};
use hypersync_client::simple_types::{Block, Transaction};
use serde_json::{json, Value as Json};

use super::client::{JsonRpcClient, RpcError};
use super::fields::{
    block_fields_in, tx_carrier, tx_fields_in, Carrier, BLOCK_KEY_MASK, BLOCK_OBSERVATION_MASK,
    TX_LOG_MASK,
};
use super::inflight::Inflight;
use super::responses::{self, ResponseError};
use crate::block_store::BlockStore;
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::request_stats::Stats;
use crate::transaction_store::{EvmTxField, TransactionStore};
use strum::VariantArray;

/// What a shared read hands to every waiter: the outcome, and its timing until
/// a waiter takes it. Taking it hands the timing to exactly one waiter — one
/// still running, unlike the call that happened to create the request. The
/// failure rides inside the value so that it, too, is recorded as the request
/// it was.
type Fetched = (
    std::result::Result<Arc<Json>, Arc<RpcError>>,
    Arc<Mutex<Option<f64>>>,
);

pub(crate) type Fetches = Inflight<FetchKey, Fetched>;

/// A transaction's place in its block, which is how both stores key it.
pub(crate) type TxKey = (u64, u32);

/// One outstanding JSON-RPC read, as the deduplication map keys it. A hash is
/// held as its bytes — the one canonical form — and rendered where the request
/// is built.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum FetchKey {
    Block(u64),
    Transaction([u8; 32]),
    Receipt([u8; 32]),
}

impl FetchKey {
    fn method(&self) -> &'static str {
        match self {
            FetchKey::Block(_) => "eth_getBlockByNumber",
            FetchKey::Transaction(_) => "eth_getTransactionByHash",
            FetchKey::Receipt(_) => "eth_getTransactionReceipt",
        }
    }

    fn params(&self) -> Json {
        match self {
            // `false`: transaction hashes only. The logs already name every
            // transaction this page cares about.
            FetchKey::Block(number) => json!([format!("0x{number:x}"), false]),
            FetchKey::Transaction(hash) | FetchKey::Receipt(hash) => {
                json!([format::Hash::from(*hash).encode_hex()])
            }
        }
    }

    fn describe(&self) -> String {
        match self {
            FetchKey::Block(number) => format!("block {number}"),
            FetchKey::Transaction(hash) => {
                format!("transaction {}", format::Hash::from(*hash).encode_hex())
            }
            FetchKey::Receipt(hash) => format!(
                "the receipt of transaction {}",
                format::Hash::from(*hash).encode_hex()
            ),
        }
    }
}

pub(crate) enum EnrichError {
    /// The provider's answer is unusable, but the next one may not be: a null
    /// row for something the chain has, a response for a block other than the
    /// one asked for, a value that will not decode. Providers load-balance
    /// across nodes that drift from each other near the head, and a node can
    /// answer badly once without answering badly again, so the caller waits and
    /// retries rather than failing the sync.
    Transient(String),
    /// Transport or JSON-RPC failure. Shared, because every waiter on one
    /// request receives it.
    Rpc(Arc<RpcError>),
    /// The provider answered, but cannot serve the fields the selection needs.
    /// Retrying asks the same question of the same chain, so the block it
    /// happened on is the one thing that makes it diagnosable.
    FieldSelection {
        block_number: u64,
        error: anyhow::Error,
    },
}

impl std::fmt::Display for EnrichError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EnrichError::Transient(message) => write!(f, "{message}"),
            EnrichError::FieldSelection { error, .. } => write!(f, "{error:#}"),
            EnrichError::Rpc(err) => write!(f, "{err}"),
        }
    }
}

impl EnrichError {
    /// How much a failure forecloses. Only the highest disables the source, so
    /// when a page fails several ways at once this is what decides which one it
    /// reports.
    fn severity(&self) -> u8 {
        match self {
            EnrichError::Transient(_) => 0,
            EnrichError::Rpc(_) => 1,
            EnrichError::FieldSelection { .. } => 2,
        }
    }

    /// Carry a rejected response's own verdict on whether trying again is worth
    /// anything, rather than treating every unreadable response as a selection
    /// the provider cannot serve.
    fn from_response(block_number: u64, error: ResponseError) -> Self {
        match error {
            ResponseError::Unservable(error) => EnrichError::FieldSelection {
                block_number,
                error,
            },
            ResponseError::Malformed(error) => EnrichError::Transient(format!(
                "The RPC gave an unusable answer while reading block {block_number}: {error:#}. \
                 The provider may be load-balanced between nodes that answer inconsistently; \
                 indexing continues correctly once the query is retried."
            )),
        }
    }
}

/// Collect a fan-out's results, keeping the most severe failure rather than
/// whichever settled first. A page's reads are grouped by field selection in a
/// `HashMap`, so "first" is not stable between runs — and the choice decides
/// whether the source is disabled or merely backs off.
fn collect_worst<T>(
    results: impl IntoIterator<Item = Result<T, EnrichError>>,
) -> Result<Vec<T>, EnrichError> {
    let mut values = Vec::new();
    let mut worst: Option<EnrichError> = None;
    for result in results {
        match result {
            Ok(value) => values.push(value),
            Err(error) => {
                if worst
                    .as_ref()
                    .is_none_or(|held| error.severity() > held.severity())
                {
                    worst = Some(error);
                }
            }
        }
    }
    match worst {
        Some(error) => Err(error),
        None => Ok(values),
    }
}

/// What one item wants from the block and transaction it belongs to.
#[derive(Clone, Copy)]
pub(crate) struct ItemFields {
    pub block_mask: u64,
    pub tx_mask: u64,
}

struct BlockRef {
    mask: u64,
    /// Every distinct hash the logs of this block reported. Each enters the
    /// page as its own observation, so two selections whose `eth_getLogs`
    /// responses straddle a fork disagree inside the page and are caught,
    /// rather than the second hash being dropped as a duplicate.
    log_hashes: Vec<format::Hash>,
}

struct TxRef {
    mask: u64,
    /// The hash the first log of this transaction reported. Two logs sharing a
    /// (block, index) but naming different transactions could only come from
    /// different forks, and their blocks disagree too — which the block
    /// observations above catch before anything is materialised.
    hash: format::Hash,
}

/// The blocks and transactions a page's routed logs reference, with the fields
/// their items selected unioned per key.
#[derive(Default)]
pub(crate) struct PageRefs {
    blocks: HashMap<u64, BlockRef>,
    transactions: HashMap<TxKey, TxRef>,
}

impl PageRefs {
    pub(crate) fn add(
        &mut self,
        block_number: u64,
        transaction_index: u32,
        block_hash: &format::Hash,
        transaction_hash: &format::Hash,
        fields: ItemFields,
    ) {
        let block = self.blocks.entry(block_number).or_insert_with(|| BlockRef {
            mask: 0,
            log_hashes: Vec::new(),
        });
        block.mask |= fields.block_mask;
        if !block.log_hashes.contains(block_hash) {
            block.log_hashes.push(block_hash.clone());
        }
        let transaction = self
            .transactions
            .entry((block_number, transaction_index))
            .or_insert_with(|| TxRef {
                mask: 0,
                hash: transaction_hash.clone(),
            });
        transaction.mask |= fields.tx_mask;
    }
}

pub(crate) struct EnrichRequest<'a> {
    pub from_block: u64,
    pub to_block: u64,
    pub refs: PageRefs,
    pub known_blocks: &'a BlockStore,
    pub known_transactions: &'a TransactionStore,
    pub should_checksum: bool,
}

pub(crate) struct EnrichedPage {
    pub blocks: BlockStore,
    pub transactions: TransactionStore,
}

/// Read one JSON-RPC result, sharing an identical request already in flight.
/// Everything read here is something the chain must have, so a null answer is
/// `Transient` rather than an absence to be handled.
async fn require(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    stats: &Stats,
    key: FetchKey,
) -> Result<Arc<Json>, EnrichError> {
    let method = key.method();
    let (result, timing) = fetches
        .get(key, || {
            let client = client.clone();
            let params = key.params();
            async move {
                let started = Instant::now();
                let result = client.request::<Json>(method, params).await;
                let seconds = started.elapsed().as_secs_f64();
                (
                    result.map(Arc::new).map_err(Arc::new),
                    Arc::new(Mutex::new(Some(seconds))),
                )
            }
        })
        .await;

    if let Some(seconds) = timing.lock().unwrap().take() {
        stats.record(method, seconds);
    }
    let value = result.map_err(EnrichError::Rpc)?;
    if value.is_null() {
        return Err(EnrichError::Transient(format!(
            "The RPC returned null for {}. The provider may be load-balanced between nodes that \
             drift from the head independently; indexing continues correctly once the query is \
             retried.",
            key.describe()
        )));
    }
    Ok(value)
}

/// Which responses a transaction's selected fields need. Fields carried by
/// both come from the transaction unless only the receipt is being read
/// anyway, so a selection never pays for two requests where one would do.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct TxReads {
    transaction: bool,
    receipt: bool,
}

impl TxReads {
    fn for_mask(mask: u64) -> Self {
        let mut transaction = false;
        let mut receipt = false;
        let mut either = false;
        for &column in EvmTxField::VARIANTS {
            if mask & (1u64 << (column as u32)) == 0 {
                continue;
            }
            match tx_carrier(column) {
                Carrier::Log => {}
                Carrier::Transaction => transaction = true,
                Carrier::Receipt => receipt = true,
                Carrier::Either => either = true,
            }
        }
        TxReads {
            // A selection of only shared fields is served by the transaction.
            transaction: transaction || (either && !receipt),
            receipt,
        }
    }

    fn is_empty(self) -> bool {
        !self.transaction && !self.receipt
    }
}

pub(crate) async fn page(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    stats: &Stats,
    request: EnrichRequest<'_>,
) -> Result<EnrichedPage, EnrichError> {
    let EnrichRequest {
        from_block,
        to_block,
        refs,
        known_blocks,
        known_transactions,
        should_checksum,
    } = request;

    let block_plan = plan_blocks(&refs, from_block, to_block, known_blocks);
    let tx_plan = plan_transactions(&refs, known_transactions);

    // Both sides are awaited, then judged together. Taking whichever failed
    // first would make the verdict a race: an unservable selection on the block
    // side would be reported on the attempts where the transactions happened to
    // answer and swallowed as a backoff on the ones where they did not. The
    // page as a whole is still bounded by the caller's query timeout.
    let (blocks, transactions) = futures_util::future::join(
        fetch_blocks(client, fetches, stats, &block_plan),
        fetch_transactions(client, fetches, stats, &tx_plan),
    )
    .await;
    let (blocks, transactions) = match (blocks, transactions) {
        (Ok(blocks), Ok(transactions)) => (blocks, transactions),
        (blocks, transactions) => {
            return Err([blocks.err(), transactions.err()]
                .into_iter()
                .flatten()
                .max_by_key(EnrichError::severity)
                .expect("one of the two sides failed"))
        }
    };

    let page_blocks = BlockStore::new_evm(should_checksum);
    let page_transactions = TransactionStore::new_evm(should_checksum);

    // What the logs themselves observed of each block, which the fetched blocks
    // and the stored chain are then cross-validated against.
    let log_observations: Vec<Block> = refs
        .blocks
        .iter()
        .flat_map(|(&number, block_ref)| {
            block_ref.log_hashes.iter().map(move |hash| Block {
                number: Some(number),
                hash: Some(hash.clone()),
                ..Default::default()
            })
        })
        .collect();
    fill_block_page(&page_blocks, log_observations, blocks);

    // Every referenced transaction gets its log-derived row even when nothing
    // was fetched for it, so `hash` and `transactionIndex` resolve from the
    // page alone.
    let log_rows: Vec<Transaction> = refs
        .transactions
        .iter()
        .map(|(&(block_number, transaction_index), tx_ref)| Transaction {
            block_number: Some(block_number.into()),
            transaction_index: Some(u64::from(transaction_index).into()),
            hash: Some(tx_ref.hash.clone()),
            ..Default::default()
        })
        .collect();
    page_transactions.insert_evm_txs(log_rows);

    for (covering, txs) in transactions {
        page_transactions.insert_evm_txs_covering(txs, covering);
    }

    Ok(EnrichedPage {
        blocks: page_blocks,
        transactions: page_transactions,
    })
}

/// Merge a plan's results into a page: the hash-only observations first, since
/// they claim no field coverage, then each group under the fields it was read
/// for. Every fetched block contributes its parent as one more observation —
/// this response's own view of the block below, which cross-validates against
/// the stored chain at no extra request.
fn fill_block_page(
    page: &BlockStore,
    mut observations: Vec<Block>,
    fetched: Vec<(u64, Vec<Block>)>,
) {
    observations.extend(
        fetched
            .iter()
            .flat_map(|(_, blocks)| blocks)
            .filter_map(|block| {
                // Genesis has no parent to observe, and its `parentHash` is
                // zero rather than absent, so it would enter the page as a
                // hash-only row for block -1 if it were not skipped.
                let number = block.number.filter(|&number| number > 0)?;
                Some(Block {
                    number: Some(number - 1),
                    hash: Some(block.parent_hash.clone()?),
                    ..Default::default()
                })
            }),
    );
    page.insert_evm_blocks(observations);
    for (covering, blocks) in fetched {
        page.insert_evm_blocks_covering(blocks, covering);
    }
}

/// The range's own boundary blocks, which are read fresh however much the
/// store already holds. `from_block` stands in for the seam below it: reading
/// the seam directly would be answered from the previous range's view of it,
/// whereas `from_block`'s parent hash is this response's.
fn boundary_blocks(from_block: u64, to_block: u64) -> Vec<u64> {
    let mut blocks = vec![to_block];
    if from_block > 0 && from_block < to_block {
        blocks.push(from_block);
    }
    blocks
}

/// A set of keys to read for one field selection. The rows of a page almost
/// always want the same fields, so resolving the selection per group rather
/// than per row does it once, and lets the group's results merge into the store
/// in a single batch instead of one locked insert per row.
struct BlockGroup {
    covering: u64,
    fields: Vec<BlockField>,
    /// The subset of `fields` the items actually selected. The rest are read
    /// for the reorg check alone, and a response missing one of those is a bad
    /// answer rather than a selection the chain cannot serve.
    selected: Vec<BlockField>,
    numbers: Vec<u64>,
}

struct TxGroup {
    covering: u64,
    fields: Vec<TransactionField>,
    reads: TxReads,
    entries: Vec<(TxKey, format::Hash)>,
}

/// Which blocks to read, and for which fields. A referenced block is skipped
/// when the store was already asked for everything this page needs of it; a
/// boundary block never is.
fn plan_blocks(
    refs: &PageRefs,
    from_block: u64,
    to_block: u64,
    known: &BlockStore,
) -> Vec<BlockGroup> {
    let boundary = boundary_blocks(from_block, to_block);
    let mut by_covering: HashMap<u64, Vec<u64>> = HashMap::new();
    for (&number, block_ref) in &refs.blocks {
        let wanted = block_ref.mask & !BLOCK_KEY_MASK;
        if !boundary.contains(&number) && known.covers(number, wanted) {
            continue;
        }
        // Every fetched block is read for the reorg fields too: they come in
        // the same response, and holding them lets a later partition skip the
        // block entirely.
        by_covering
            .entry(wanted | BLOCK_OBSERVATION_MASK)
            .or_default()
            .push(number);
    }
    for &number in &boundary {
        if !refs.blocks.contains_key(&number) {
            by_covering
                .entry(BLOCK_OBSERVATION_MASK)
                .or_default()
                .push(number);
        }
    }
    by_covering
        .into_iter()
        .map(|(covering, numbers)| BlockGroup {
            covering,
            fields: block_fields_in(covering),
            selected: block_fields_in(covering & !BLOCK_OBSERVATION_MASK),
            numbers,
        })
        .collect()
}

/// Which transactions to read, and for which fields. A transaction whose
/// selected fields all come off the log, or which the store already covers,
/// needs no request at all.
fn plan_transactions(refs: &PageRefs, known: &TransactionStore) -> Vec<TxGroup> {
    let mut by_covering: HashMap<u64, Vec<(TxKey, format::Hash)>> = HashMap::new();
    for (&key, tx_ref) in &refs.transactions {
        let wanted = tx_ref.mask & !TX_LOG_MASK;
        if known.covers(key, wanted) {
            continue;
        }
        by_covering
            .entry(wanted)
            .or_default()
            .push((key, tx_ref.hash.clone()));
    }
    by_covering
        .into_iter()
        .filter_map(|(covering, entries)| {
            let reads = TxReads::for_mask(covering);
            // Nothing to ask a provider for: every selected field is on the log.
            if reads.is_empty() {
                return None;
            }
            Some(TxGroup {
                covering,
                fields: tx_fields_in(covering),
                reads,
                entries,
            })
        })
        .collect()
}

/// Re-read the given blocks as a page of hash observations, for the
/// rollback-depth search. Each block is a separate request, so responses can
/// straddle a fork; every block's parent hash goes in as a second row, which
/// makes consecutive requests cross-validate each other through the page's own
/// hash-conflict check.
pub(crate) async fn fetch_block_hashes(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    stats: &Stats,
    block_numbers: &[u64],
    should_checksum: bool,
) -> Result<BlockStore, EnrichError> {
    let groups = [BlockGroup {
        covering: BLOCK_OBSERVATION_MASK,
        fields: block_fields_in(BLOCK_OBSERVATION_MASK),
        selected: Vec::new(),
        numbers: block_numbers.to_vec(),
    }];
    let blocks = fetch_blocks(client, fetches, stats, &groups).await?;

    let page = BlockStore::new_evm(should_checksum);
    fill_block_page(&page, Vec::new(), blocks);
    Ok(page)
}

/// Fetch and decode every planned block, one group at a time but all
/// concurrently, keeping each group's rows together for a single insert.
async fn fetch_blocks(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    stats: &Stats,
    groups: &[BlockGroup],
) -> Result<Vec<(u64, Vec<Block>)>, EnrichError> {
    let fetches = groups.iter().map(|group| async move {
        let blocks = join_all(group.numbers.iter().map(|&number| async move {
            let response = require(client, fetches, stats, FetchKey::Block(number)).await?;
            responses::build_block(&response, number, &group.fields, &group.selected)
                .map_err(|error| EnrichError::from_response(number, error))
        }))
        .await;
        let blocks = collect_worst(blocks)?;
        Ok((group.covering, blocks))
    });
    collect_worst(join_all(fetches).await)
}

async fn fetch_transactions(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    stats: &Stats,
    groups: &[TxGroup],
) -> Result<Vec<(u64, Vec<Transaction>)>, EnrichError> {
    let fetches = groups.iter().map(|group| async move {
        let txs = join_all(group.entries.iter().map(
            |((block_number, transaction_index), hash)| {
                let key = ***hash;
                async move {
                    let (transaction, receipt) = futures_util::future::try_join(
                        read_opt(
                            client,
                            fetches,
                            stats,
                            group
                                .reads
                                .transaction
                                .then_some(FetchKey::Transaction(key)),
                        ),
                        read_opt(
                            client,
                            fetches,
                            stats,
                            group.reads.receipt.then_some(FetchKey::Receipt(key)),
                        ),
                    )
                    .await?;

                    let mut tx = responses::build_transaction(
                        *block_number,
                        *transaction_index,
                        hash,
                        transaction.as_deref(),
                        receipt.as_deref(),
                        &group.fields,
                    )
                    .map_err(|error| EnrichError::from_response(*block_number, error))?;

                    if responses::needs_effective_gas_price(&tx, &group.fields) {
                        // The receipt came back without it, so this chain predates
                        // EIP-1559 and the transaction's own gasPrice is the answer.
                        // Only a selection that did not already read the transaction
                        // pays for a request here.
                        let transaction = match transaction {
                            Some(transaction) => transaction,
                            None => {
                                require(client, fetches, stats, FetchKey::Transaction(key)).await?
                            }
                        };
                        responses::fill_effective_gas_price(&mut tx, &transaction)
                            .map_err(|error| EnrichError::from_response(*block_number, error))?;
                    }

                    responses::check_transaction(&tx, &group.fields)
                        .map_err(|error| EnrichError::from_response(*block_number, error))?;
                    Ok(tx)
                }
            },
        ))
        .await;
        let txs = collect_worst(txs)?;
        Ok((group.covering | TX_LOG_MASK, txs))
    });
    collect_worst(join_all(fetches).await)
}

/// Read a response only if the selection needs one.
async fn read_opt(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    stats: &Stats,
    key: Option<FetchKey>,
) -> Result<Option<Arc<Json>>, EnrichError> {
    match key {
        None => Ok(None),
        Some(key) => require(client, fetches, stats, key).await.map(Some),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block_store::EvmBlockField;
    use crate::transaction_store::EvmTxField;

    fn hash(byte: u8) -> format::Hash {
        format::Hash::from([byte; 32])
    }

    fn block_bit(field: EvmBlockField) -> u64 {
        1u64 << (field as u32)
    }

    fn tx_bit(field: EvmTxField) -> u64 {
        1u64 << (field as u32)
    }

    /// One item in block `number`, transaction 0, wanting `block_mask` of its
    /// block and `tx_mask` of its transaction.
    fn refs_for(number: u64, block_mask: u64, tx_mask: u64) -> PageRefs {
        let mut refs = PageRefs::default();
        refs.add(
            number,
            0,
            &hash(0xbb),
            &hash(0xcc),
            ItemFields {
                block_mask,
                tx_mask,
            },
        );
        refs
    }

    fn planned_numbers(groups: &[BlockGroup]) -> Vec<u64> {
        let mut numbers: Vec<u64> = groups
            .iter()
            .flat_map(|group| group.numbers.iter().copied())
            .collect();
        numbers.sort_unstable();
        numbers
    }

    fn planned_keys(groups: &[TxGroup]) -> Vec<TxKey> {
        let mut keys: Vec<TxKey> = groups
            .iter()
            .flat_map(|group| group.entries.iter().map(|(key, _)| *key))
            .collect();
        keys.sort_unstable();
        keys
    }

    #[test]
    fn a_block_the_store_already_covers_is_not_read_again() {
        // The case several partitions scanning the same range hit: the first
        // fetched the block, and the rest must not fetch it again.
        let wanted = block_bit(EvmBlockField::GasUsed);
        let known = BlockStore::new_evm(false);
        known.insert_evm_blocks_covering(
            vec![Block {
                number: Some(50),
                ..Default::default()
            }],
            wanted,
        );
        let plan = plan_blocks(&refs_for(50, wanted, 0), 40, 60, &known);
        assert_eq!(planned_numbers(&plan), vec![40, 60]);
    }

    #[test]
    fn a_block_covered_only_for_other_fields_is_still_read() {
        let known = BlockStore::new_evm(false);
        known.insert_evm_blocks_covering(
            vec![Block {
                number: Some(50),
                ..Default::default()
            }],
            block_bit(EvmBlockField::GasUsed),
        );
        let plan = plan_blocks(
            &refs_for(50, block_bit(EvmBlockField::Miner), 0),
            40,
            60,
            &known,
        );
        assert_eq!(planned_numbers(&plan), vec![40, 50, 60]);
    }

    #[test]
    fn a_boundary_block_is_read_even_when_the_store_covers_it() {
        // The boundary blocks are this range's reorg observations, so a stored
        // answer — which is some earlier response's view of them — will not do.
        let known = BlockStore::new_evm(false);
        for number in [40u64, 60] {
            known.insert_evm_blocks_covering(
                vec![Block {
                    number: Some(number),
                    hash: Some(hash(1)),
                    ..Default::default()
                }],
                BLOCK_OBSERVATION_MASK,
            );
        }
        let plan = plan_blocks(&PageRefs::default(), 40, 60, &known);
        assert_eq!(planned_numbers(&plan), vec![40, 60]);
    }

    #[test]
    fn a_block_no_item_wants_fields_from_is_not_read() {
        // Its hash still reaches the page as an observation off the log, which
        // is all reorg detection needs from it.
        let plan = plan_blocks(&refs_for(50, 0, 0), 40, 60, &BlockStore::new_evm(false));
        assert_eq!(planned_numbers(&plan), vec![40, 60]);
    }

    #[test]
    fn a_boundary_block_an_item_wants_nothing_from_is_still_read() {
        // The item makes the block referenced but selects no field of it; it is
        // still the range's boundary, so its reorg observation is read.
        let plan = plan_blocks(&refs_for(40, 0, 0), 40, 40, &BlockStore::new_evm(false));
        assert_eq!(planned_numbers(&plan), vec![40]);
    }

    #[test]
    fn a_single_block_range_reads_that_block_once() {
        let plan = plan_blocks(&PageRefs::default(), 40, 40, &BlockStore::new_evm(false));
        assert_eq!(planned_numbers(&plan), vec![40]);
    }

    #[test]
    fn a_transaction_selected_only_for_log_derived_fields_is_not_read() {
        let refs = refs_for(
            50,
            0,
            tx_bit(EvmTxField::Hash) | tx_bit(EvmTxField::TransactionIndex),
        );
        let plan = plan_transactions(&refs, &TransactionStore::new_evm(false));
        assert_eq!(planned_keys(&plan), Vec::<TxKey>::new());
    }

    #[test]
    fn a_transaction_the_store_already_covers_is_not_read_again() {
        let wanted = tx_bit(EvmTxField::Gas);
        let known = TransactionStore::new_evm(false);
        known.insert_evm_txs_covering(
            vec![Transaction {
                block_number: Some(50u64.into()),
                transaction_index: Some(0u64.into()),
                ..Default::default()
            }],
            wanted,
        );
        let plan = plan_transactions(&refs_for(50, 0, wanted), &known);
        assert_eq!(planned_keys(&plan), Vec::<TxKey>::new());
    }

    #[test]
    fn a_field_that_came_back_null_still_counts_as_covered() {
        // `to` is null on a contract creation. Judged by stored values alone
        // the row would look unfetched and be requested on every later page.
        let wanted = tx_bit(EvmTxField::To);
        let known = TransactionStore::new_evm(false);
        known.insert_evm_txs_covering(
            vec![Transaction {
                block_number: Some(50u64.into()),
                transaction_index: Some(0u64.into()),
                to: None,
                ..Default::default()
            }],
            wanted,
        );
        let plan = plan_transactions(&refs_for(50, 0, wanted), &known);
        assert_eq!(planned_keys(&plan), Vec::<TxKey>::new());
    }

    #[test]
    fn one_item_selecting_nothing_does_not_widen_anothers_fetch() {
        // Masks are unioned per key, not taken across the whole partition, so an
        // event that selects no transaction fields adds no requests.
        let mut refs = PageRefs::default();
        refs.add(
            50,
            0,
            &hash(0xbb),
            &hash(0xcc),
            ItemFields {
                block_mask: 0,
                tx_mask: 0,
            },
        );
        refs.add(
            50,
            1,
            &hash(0xbb),
            &hash(0xdd),
            ItemFields {
                block_mask: 0,
                tx_mask: tx_bit(EvmTxField::Gas),
            },
        );
        let plan = plan_transactions(&refs, &TransactionStore::new_evm(false));
        assert_eq!(planned_keys(&plan), vec![(50, 1)]);
    }

    #[test]
    fn two_logs_disagreeing_on_a_blocks_hash_both_reach_the_page() {
        // One `eth_getLogs` per selection means a page's responses can straddle
        // a reorg. Keeping only the first hash would let the two forks' items
        // merge into one accepted page; keeping both makes the page conflict
        // with itself, which is what forces the retry.
        let mut refs = PageRefs::default();
        for (index, block_hash) in [(0u32, hash(0xaa)), (1, hash(0xbb)), (2, hash(0xaa))] {
            refs.add(
                50,
                index,
                &block_hash,
                &hash(0xcc),
                ItemFields {
                    block_mask: 0,
                    tx_mask: 0,
                },
            );
        }
        assert_eq!(refs.blocks[&50].log_hashes, vec![hash(0xaa), hash(0xbb)]);
    }

    #[test]
    fn rows_wanting_the_same_fields_are_planned_as_one_group() {
        // Grouping is what keeps the per-row work off the hot path: the field
        // list is resolved once per group and the rows merge in one batch.
        let mut refs = PageRefs::default();
        let gas = tx_bit(EvmTxField::Gas);
        let input = tx_bit(EvmTxField::Input);
        for (index, mask) in [(0u32, gas), (1, gas), (2, input)] {
            refs.add(
                50,
                index,
                &hash(0xbb),
                &hash(0xc0 + index as u8),
                ItemFields {
                    block_mask: 0,
                    tx_mask: mask,
                },
            );
        }
        let mut sizes: Vec<usize> = plan_transactions(&refs, &TransactionStore::new_evm(false))
            .iter()
            .map(|group| group.entries.len())
            .collect();
        sizes.sort_unstable();
        assert_eq!(sizes, vec![1, 2]);
    }

    #[test]
    fn the_carrier_of_the_selected_fields_decides_which_responses_are_read() {
        let plans = (
            // Transaction-only.
            TxReads::for_mask(tx_bit(EvmTxField::Input)),
            // Receipt-only.
            TxReads::for_mask(tx_bit(EvmTxField::GasUsed)),
            // One of each.
            TxReads::for_mask(tx_bit(EvmTxField::Input) | tx_bit(EvmTxField::GasUsed)),
            // Carried by both, so the transaction alone answers it.
            TxReads::for_mask(tx_bit(EvmTxField::From)),
            // Carried by both, alongside a receipt-only field: no second request.
            TxReads::for_mask(tx_bit(EvmTxField::From) | tx_bit(EvmTxField::GasUsed)),
        );
        assert_eq!(
            plans,
            (
                TxReads {
                    transaction: true,
                    receipt: false
                },
                TxReads {
                    transaction: false,
                    receipt: true
                },
                TxReads {
                    transaction: true,
                    receipt: true
                },
                TxReads {
                    transaction: true,
                    receipt: false
                },
                TxReads {
                    transaction: false,
                    receipt: true
                },
            )
        );
    }
}
