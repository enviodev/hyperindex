//! Fills a page's block and transaction stores for the logs a query returned.
//!
//! Three rules decide what is requested:
//!
//! * A block or transaction is fetched only for the fields the items that
//!   reference it actually selected, unioned per key.
//! * A field the persistent store already holds for that key is not fetched
//!   again, which is what stops several partitions scanning the same block from
//!   each fetching it. Coverage is read from the store's fetched-field mask, so
//!   a field that came back null counts as fetched.
//! * The range's own boundary blocks are always fetched fresh, never served
//!   from the store. They are the reorg observations: the store holds the view
//!   an earlier response took of them, which is exactly the view a fork would
//!   invalidate. Concurrent partitions still share one request for them,
//!   because deduplication is by request rather than by stored result.
//!
//! Serving a field from the store cannot smuggle in an orphaned fork's data:
//! every log's own `blockHash` enters the page as an observation, so a stored
//! row belonging to a dead fork disagrees with this response and the merge
//! reports a reorg before any event is materialised.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
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
use super::responses;
use crate::block_store::BlockStore;
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::request_stats::RequestStat;
use crate::transaction_store::TransactionStore;

/// What a shared read hands to every waiter: the response, how long the
/// request took, and a claim flag so exactly one waiter records that timing —
/// a waiter that is by definition still running, unlike the call that happened
/// to create the request.
type Fetched = (Arc<Json>, f64, Arc<AtomicBool>);

pub(crate) type FetchCache = Inflight<FetchKey, Fetched, RpcError>;

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
    /// A row the provider should have is absent. Providers load-balance across
    /// nodes that drift from each other near the head, so a lookup routed to a
    /// node that has not caught up answers null for data that does exist.
    /// Transient by nature, so the caller retries rather than failing the sync.
    NotFound(String),
    /// Transport or JSON-RPC failure.
    Rpc(RpcError),
    /// The provider answered, but not with the fields the selection needs.
    /// Retrying cannot fix a chain or provider that does not serve them.
    FieldSelection(anyhow::Error),
}

/// Per-request timings. One request contributes exactly one entry, recorded by
/// whichever call is first to observe the finished read — a call still running,
/// so the timing always lands in a collector someone will drain. A page that
/// only joined requests others issued therefore reports none of its own.
#[derive(Clone, Default)]
pub(crate) struct Stats(Arc<Mutex<Vec<RequestStat>>>);

impl Stats {
    fn record(&self, method: &str, seconds: f64) {
        self.0.lock().unwrap().push(RequestStat {
            method: method.to_string(),
            seconds,
        });
    }

    /// The page's own `eth_getLogs` calls, which are issued directly rather
    /// than through the deduplication map: each selection is a distinct query.
    pub(crate) fn record_log_query(&self, seconds: f64) {
        self.record("eth_getLogs", seconds);
    }

    pub(crate) fn take(&self) -> Vec<RequestStat> {
        std::mem::take(&mut *self.0.lock().unwrap())
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
    hash: format::Hash,
}

/// The blocks and transactions a page's routed logs reference, with the fields
/// their items selected unioned per key.
#[derive(Default)]
pub(crate) struct PageRefs {
    blocks: HashMap<u64, BlockRef>,
    transactions: HashMap<(u64, u32), TxRef>,
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
        self.transactions
            .entry((block_number, transaction_index))
            .and_modify(|existing| existing.mask |= fields.tx_mask)
            .or_insert_with(|| TxRef {
                mask: fields.tx_mask,
                hash: transaction_hash.clone(),
            });
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
/// A null result is `None`: for these methods it means "this node does not have
/// it", which the caller decides how to treat.
async fn read(
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
    stats: &Stats,
    key: FetchKey,
) -> Result<Option<Arc<Json>>, EnrichError> {
    let method = key.method();
    let (value, seconds, unclaimed) = cache
        .get(key.clone(), || {
            let client = client.clone();
            let params = key.params();
            async move {
                let started = Instant::now();
                let result = client.request::<Json>(method, params).await;
                let seconds = started.elapsed().as_secs_f64();
                result.map(|value| (Arc::new(value), seconds, Arc::new(AtomicBool::new(false))))
            }
        })
        .await
        .map_err(|err| EnrichError::Rpc((*err).clone()))?;

    // One request, one timing, recorded by whichever waiter gets there first.
    if !unclaimed.swap(true, Ordering::SeqCst) {
        stats.record(method, seconds);
    }
    Ok((!value.is_null()).then_some(value))
}

/// Read something the chain must have. A null answer is the load-balancing
/// symptom `EnrichError::NotFound` describes, so it is reported the same way
/// for a block, a transaction and a receipt alike.
async fn require(
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
    stats: &Stats,
    key: FetchKey,
) -> Result<Arc<Json>, EnrichError> {
    let description = key.describe();
    read(client, cache, stats, key).await?.ok_or_else(|| {
        EnrichError::NotFound(format!(
            "The RPC returned null for {description}. The provider may be load-balanced between \
             nodes that drift from the head independently; indexing continues correctly once the \
             query is retried."
        ))
    })
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
        for field in tx_fields_in(mask) {
            let Some(column) = super::fields::tx_field_column(field) else {
                continue;
            };
            match tx_carrier(column) {
                Carrier::Log => {}
                Carrier::Transaction => transaction = true,
                Carrier::Receipt => receipt = true,
                Carrier::Either => either = true,
            }
        }
        // A selection of only shared fields is served by the transaction.
        if either && !receipt {
            transaction = true;
        }
        TxReads {
            transaction,
            receipt,
        }
    }

    fn is_empty(self) -> bool {
        !self.transaction && !self.receipt
    }
}

pub(crate) async fn enrich(
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
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

    let (blocks, transactions) = futures_util::future::try_join(
        fetch_blocks(client, cache, stats, &block_plan),
        fetch_transactions(client, cache, stats, &tx_plan),
    )
    .await?;

    let page_blocks = BlockStore::new_evm(should_checksum);
    let page_transactions = TransactionStore::new_evm(should_checksum);

    // Hash-only rows for what the logs themselves observed, and for the parent
    // of every fetched block. Both are this response's view of the chain, so
    // together with the fetched hashes they cross-validate each other and the
    // stored chain.
    let mut observations: Vec<Block> = refs
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
    observations.extend(
        blocks
            .iter()
            .flat_map(|(_, blocks)| blocks)
            .filter_map(|block| {
                let number = block.number.filter(|&number| number > 0)?;
                Some(Block {
                    number: Some(number - 1),
                    hash: Some(block.parent_hash.clone()?),
                    ..Default::default()
                })
            }),
    );
    page_blocks.insert_evm_blocks(observations);

    for (covering, blocks) in blocks {
        page_blocks.insert_evm_blocks_covering(blocks, covering);
    }

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

/// The range's own boundary blocks, which are read fresh however much the
/// store already holds. `from_block` stands in for the seam below it: reading
/// the seam directly would be answered from the previous range's view of it,
/// whereas `from_block`'s parent hash is this response's.
fn boundary_blocks(from_block: u64, to_block: u64) -> Vec<u64> {
    let mut blocks = vec![to_block];
    if from_block > 0 && from_block <= to_block && from_block != to_block {
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
    numbers: Vec<u64>,
}

struct TxGroup {
    covering: u64,
    fields: Vec<TransactionField>,
    reads: TxReads,
    entries: Vec<((u64, u32), format::Hash)>,
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
        if !boundary.contains(&number) && (wanted == 0 || known.covers(number, wanted)) {
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
            numbers,
        })
        .collect()
}

/// Which transactions to read, and for which fields. A transaction whose
/// selected fields all come off the log, or which the store already covers,
/// needs no request at all.
fn plan_transactions(refs: &PageRefs, known: &TransactionStore) -> Vec<TxGroup> {
    let mut by_covering: HashMap<u64, Vec<((u64, u32), format::Hash)>> = HashMap::new();
    for (&key, tx_ref) in &refs.transactions {
        let wanted = tx_ref.mask & !TX_LOG_MASK;
        if wanted == 0 || known.covers(key, wanted) {
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
    cache: &FetchCache,
    stats: &Stats,
    block_numbers: &[u64],
    should_checksum: bool,
) -> Result<BlockStore, EnrichError> {
    let groups = [BlockGroup {
        covering: BLOCK_OBSERVATION_MASK,
        fields: block_fields_in(BLOCK_OBSERVATION_MASK),
        numbers: block_numbers.to_vec(),
    }];
    let blocks = fetch_blocks(client, cache, stats, &groups).await?;

    let page = BlockStore::new_evm(should_checksum);
    let parents: Vec<Block> = blocks
        .iter()
        .flat_map(|(_, blocks)| blocks)
        .filter_map(|block| {
            let number = block.number.filter(|&number| number > 0)?;
            Some(Block {
                number: Some(number - 1),
                hash: Some(block.parent_hash.clone()?),
                ..Default::default()
            })
        })
        .collect();
    page.insert_evm_blocks(parents);
    for (covering, blocks) in blocks {
        page.insert_evm_blocks_covering(blocks, covering);
    }
    Ok(page)
}

/// Fetch and decode every planned block, one group at a time but all
/// concurrently, keeping each group's rows together for a single insert.
async fn fetch_blocks(
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
    stats: &Stats,
    groups: &[BlockGroup],
) -> Result<Vec<(u64, Vec<Block>)>, EnrichError> {
    let fetches = groups.iter().map(|group| async move {
        let blocks = join_all(group.numbers.iter().map(|&number| async move {
            let response = require(client, cache, stats, FetchKey::Block(number)).await?;
            responses::build_block(&response, number, &group.fields)
                .map_err(EnrichError::FieldSelection)
        }))
        .await
        .into_iter()
        .collect::<Result<Vec<_>, EnrichError>>()?;
        Ok((group.covering, blocks))
    });
    join_all(fetches).await.into_iter().collect()
}

async fn fetch_transactions(
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
    stats: &Stats,
    groups: &[TxGroup],
) -> Result<Vec<(u64, Vec<Transaction>)>, EnrichError> {
    let fetches = groups.iter().map(|group| async move {
        let txs = join_all(group.entries.iter().map(
            |((block_number, transaction_index), hash)| {
                let key = ***hash;
                async move {
                    let (transaction, receipt) = futures_util::future::try_join(
                        read_if(group.reads.transaction, client, cache, stats, || {
                            FetchKey::Transaction(key)
                        }),
                        read_if(group.reads.receipt, client, cache, stats, || {
                            FetchKey::Receipt(key)
                        }),
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
                    .map_err(EnrichError::FieldSelection)?;

                    if responses::needs_effective_gas_price(&tx, &group.fields) {
                        // The receipt came back without it, so this chain predates
                        // EIP-1559 and the transaction's own gasPrice is the answer.
                        // Only a selection that did not already read the transaction
                        // pays for a request here.
                        let transaction = match transaction {
                            Some(transaction) => transaction,
                            None => {
                                require(client, cache, stats, FetchKey::Transaction(key)).await?
                            }
                        };
                        responses::fill_effective_gas_price(&mut tx, &transaction)
                            .map_err(EnrichError::FieldSelection)?;
                    }

                    responses::check_transaction(&tx, &group.fields)
                        .map_err(EnrichError::FieldSelection)?;
                    Ok(tx)
                }
            },
        ))
        .await
        .into_iter()
        .collect::<Result<Vec<_>, EnrichError>>()?;
        Ok((group.covering | TX_LOG_MASK, txs))
    });
    join_all(fetches).await.into_iter().collect()
}

async fn read_if(
    wanted: bool,
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
    stats: &Stats,
    key: impl FnOnce() -> FetchKey,
) -> Result<Option<Arc<Json>>, EnrichError> {
    if !wanted {
        return Ok(None);
    }
    require(client, cache, stats, key()).await.map(Some)
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

    fn planned_keys(groups: &[TxGroup]) -> Vec<(u64, u32)> {
        let mut keys: Vec<(u64, u32)> = groups
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
        assert!(plan.is_empty(), "planned {} groups", plan.len());
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
        assert!(plan.is_empty(), "planned {} groups", plan.len());
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
        assert!(plan.is_empty(), "planned {} groups", plan.len());
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
