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
use crate::request_stats::RequestStat;
use crate::transaction_store::TransactionStore;

pub(crate) type FetchCache = Inflight<FetchKey, Arc<Json>, RpcError>;

/// One outstanding JSON-RPC read, as the deduplication map keys it. The hash is
/// kept in the hex form the request sends so a key needs no re-encoding.
#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) enum FetchKey {
    Block(u64),
    Transaction(Box<str>),
    Receipt(Box<str>),
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
            FetchKey::Transaction(hash) | FetchKey::Receipt(hash) => json!([hash]),
        }
    }

    fn describe(&self) -> String {
        match self {
            FetchKey::Block(number) => format!("block {number}"),
            FetchKey::Transaction(hash) => format!("transaction {hash}"),
            FetchKey::Receipt(hash) => format!("the receipt of transaction {hash}"),
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

/// Per-request timings, attributed to the call that issued them: a loader
/// records into the collector of whichever call created it, and a call that
/// joins an in-flight request records nothing because it made no request.
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
    /// The hash the logs in this block reported, which enters the page as an
    /// observation whether or not the block itself is fetched.
    log_hash: format::Hash,
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
        self.blocks
            .entry(block_number)
            .and_modify(|existing| existing.mask |= fields.block_mask)
            .or_insert_with(|| BlockRef {
                mask: fields.block_mask,
                log_hash: block_hash.clone(),
            });
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
    let value = cache
        .get(key.clone(), || {
            let client = client.clone();
            let stats = stats.clone();
            let method = key.method();
            let params = key.params();
            async move {
                let started = Instant::now();
                let result = client.request::<Json>(method, params).await;
                stats.record(method, started.elapsed().as_secs_f64());
                result.map(Arc::new)
            }
        })
        .await
        .map_err(|err| match Arc::try_unwrap(err) {
            Ok(err) => EnrichError::Rpc(err),
            // Another waiter still holds the error; describe it rather than
            // cloning a type that cannot be cloned.
            Err(shared) => EnrichError::Rpc(RpcError::Other(anyhow::anyhow!(
                "{}",
                match &*shared {
                    RpcError::JsonRpc { code, message } =>
                        format!("JSON-RPC error {code}: {message}"),
                    RpcError::Other(e) => format!("{e:#}"),
                }
            ))),
        })?;
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
struct TxPlan {
    transaction: bool,
    receipt: bool,
}

impl TxPlan {
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
        TxPlan {
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
        .map(|(&number, block_ref)| Block {
            number: Some(number),
            hash: Some(block_ref.log_hash.clone()),
            ..Default::default()
        })
        .collect();
    for (number, _, block) in &blocks {
        if *number > 0 {
            if let Some(parent_hash) = block.parent_hash.clone() {
                observations.push(Block {
                    number: Some(number - 1),
                    hash: Some(parent_hash),
                    ..Default::default()
                });
            }
        }
    }
    page_blocks.insert_evm_blocks(observations);

    for (_, covering, block) in blocks {
        page_blocks.insert_evm_blocks_covering(vec![block], covering);
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

    for (_, covering, tx) in transactions {
        page_transactions.insert_evm_txs_covering(vec![tx], covering);
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

/// Which blocks to read, and for which fields. A referenced block is skipped
/// when the store was already asked for everything this page needs of it; a
/// boundary block never is.
fn plan_blocks(
    refs: &PageRefs,
    from_block: u64,
    to_block: u64,
    known: &BlockStore,
) -> Vec<(u64, u64)> {
    let boundary = boundary_blocks(from_block, to_block);
    refs.blocks
        .iter()
        .filter_map(|(&number, block_ref)| {
            let wanted = block_ref.mask & !BLOCK_KEY_MASK;
            if !boundary.contains(&number) && (wanted == 0 || known.covers(number, wanted)) {
                return None;
            }
            // Every fetched block is read for the reorg fields too: they come
            // in the same response, and holding them lets a later partition
            // skip the block entirely.
            Some((number, wanted | BLOCK_OBSERVATION_MASK))
        })
        .chain(
            boundary
                .iter()
                .filter(|number| !refs.blocks.contains_key(number))
                .map(|&number| (number, BLOCK_OBSERVATION_MASK)),
        )
        .collect()
}

/// Which transactions to read, and for which fields. A transaction whose
/// selected fields all come off the log, or which the store already covers,
/// needs no request at all.
fn plan_transactions(
    refs: &PageRefs,
    known: &TransactionStore,
) -> Vec<((u64, u32), u64, Box<str>)> {
    refs.transactions
        .iter()
        .filter_map(|(&key, tx_ref)| {
            let wanted = tx_ref.mask & !TX_LOG_MASK;
            if wanted == 0 || TxPlan::for_mask(wanted).is_empty() || known.covers(key, wanted) {
                return None;
            }
            Some((key, wanted, tx_ref.hash.encode_hex().into_boxed_str()))
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
    let plan: Vec<(u64, u64)> = block_numbers
        .iter()
        .map(|&number| (number, BLOCK_OBSERVATION_MASK))
        .collect();
    let blocks = fetch_blocks(client, cache, stats, &plan).await?;

    let page = BlockStore::new_evm(should_checksum);
    let mut parents = Vec::new();
    for (number, _, block) in &blocks {
        if *number > 0 {
            if let Some(parent_hash) = block.parent_hash.clone() {
                parents.push(Block {
                    number: Some(number - 1),
                    hash: Some(parent_hash),
                    ..Default::default()
                });
            }
        }
    }
    page.insert_evm_blocks(parents);
    for (_, covering, block) in blocks {
        page.insert_evm_blocks_covering(vec![block], covering);
    }
    Ok(page)
}

/// Fetch and decode each planned block, returning it with the mask it covers.
async fn fetch_blocks(
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
    stats: &Stats,
    plan: &[(u64, u64)],
) -> Result<Vec<(u64, u64, Block)>, EnrichError> {
    let fetches = plan.iter().map(|&(number, covering)| async move {
        let response = require(client, cache, stats, FetchKey::Block(number)).await?;
        let block = responses::build_block(&response, &block_fields_in(covering))
            .map_err(EnrichError::FieldSelection)?;
        Ok((number, covering, block))
    });
    join_all(fetches).await.into_iter().collect()
}

async fn fetch_transactions(
    client: &Arc<JsonRpcClient>,
    cache: &FetchCache,
    stats: &Stats,
    plan: &[((u64, u32), u64, Box<str>)],
) -> Result<Vec<((u64, u32), u64, Transaction)>, EnrichError> {
    let fetches = plan.iter().map(
        |((block_number, transaction_index), covering, hash)| async move {
            let selection = tx_fields_in(*covering);
            let plan = TxPlan::for_mask(*covering);
            let (transaction, receipt) = futures_util::future::try_join(
                read_if(plan.transaction, client, cache, stats, || {
                    FetchKey::Transaction(hash.clone())
                }),
                read_if(plan.receipt, client, cache, stats, || {
                    FetchKey::Receipt(hash.clone())
                }),
            )
            .await?;

            let tx_ref = refs_hash(hash)?;
            let mut tx = responses::build_transaction(
                *block_number,
                *transaction_index,
                &tx_ref,
                transaction.as_deref(),
                receipt.as_deref(),
                &selection,
            )
            .map_err(EnrichError::FieldSelection)?;

            if responses::needs_effective_gas_price(&tx, &selection) {
                // The receipt came back without it, so this chain predates
                // EIP-1559 and the transaction's own gasPrice is the answer.
                let transaction = match transaction {
                    Some(transaction) => transaction,
                    None => {
                        require(client, cache, stats, FetchKey::Transaction(hash.clone())).await?
                    }
                };
                responses::fill_effective_gas_price(&mut tx, &transaction)
                    .map_err(EnrichError::FieldSelection)?;
            }

            responses::check_transaction(&tx, &selection).map_err(EnrichError::FieldSelection)?;
            Ok((
                (*block_number, *transaction_index),
                *covering | TX_LOG_MASK,
                tx,
            ))
        },
    );
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

fn refs_hash(hash: &str) -> Result<format::Hash, EnrichError> {
    format::Hash::decode_hex(hash)
        .map_err(|e| EnrichError::FieldSelection(anyhow::anyhow!("transaction hash {hash}: {e}")))
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

    fn planned_numbers(plan: &[(u64, u64)]) -> Vec<u64> {
        let mut numbers: Vec<u64> = plan.iter().map(|&(number, _)| number).collect();
        numbers.sort_unstable();
        numbers
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
        assert!(plan.is_empty(), "planned {} requests", plan.len());
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
        assert!(plan.is_empty(), "planned {} requests", plan.len());
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
        assert!(plan.is_empty(), "planned {} requests", plan.len());
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
        assert_eq!(
            plan.iter().map(|(key, _, _)| *key).collect::<Vec<_>>(),
            vec![(50, 1)]
        );
    }

    #[test]
    fn the_carrier_of_the_selected_fields_decides_which_responses_are_read() {
        let plans = (
            // Transaction-only.
            TxPlan::for_mask(tx_bit(EvmTxField::Input)),
            // Receipt-only.
            TxPlan::for_mask(tx_bit(EvmTxField::GasUsed)),
            // One of each.
            TxPlan::for_mask(tx_bit(EvmTxField::Input) | tx_bit(EvmTxField::GasUsed)),
            // Carried by both, so the transaction alone answers it.
            TxPlan::for_mask(tx_bit(EvmTxField::From)),
            // Carried by both, alongside a receipt-only field: no second request.
            TxPlan::for_mask(tx_bit(EvmTxField::From) | tx_bit(EvmTxField::GasUsed)),
        );
        assert_eq!(
            plans,
            (
                TxPlan { transaction: true, receipt: false },
                TxPlan { transaction: false, receipt: true },
                TxPlan { transaction: true, receipt: true },
                TxPlan { transaction: true, receipt: false },
                TxPlan { transaction: false, receipt: true },
            )
        );
    }
}
