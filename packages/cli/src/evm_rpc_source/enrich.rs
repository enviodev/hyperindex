//! Fills a page's block and transaction stores for the logs a query returned.
//! `plan_blocks` and `plan_transactions` decide what that costs in requests.
//!
//! Whether a response is fetched is decided by what the page itself wants; how
//! much of it is decoded is not. A response already carries every field of what
//! it describes, so it is read for everything any registration on the chain
//! selects — never, though, for a field that would drag in a second response.
//!
//! Serving a field from the store rather than refetching it is safe because
//! every log carries its own `blockHash` into the page: a stored row from a
//! dead fork disagrees with the response, and the merge reports a reorg before
//! anything is materialised. Where a reorg is not handled at all — detect-only
//! mode, or a fork deeper than the configured window — such a row keeps the
//! dead fork's values until it is pruned.
//!
//! The range's own boundary blocks are the exception. The comparison rests on
//! them, so they are never answered from the store.

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::future::join_all;
use hypersync_client::format::{self, Hex};
use hypersync_client::simple_types::{Block, Transaction};
use serde_json::{json, Value as Json};

use super::client::{JsonRpcClient, RpcError};
use super::fields::{
    block_fields_in, tx_fields_in, tx_mask_of, Carrier, BLOCK_KEY_MASK, BLOCK_OBSERVATION_MASK,
    TX_EAGER_EXCLUDED_MASK, TX_LOG_MASK,
};
use super::inflight::Inflight;
use super::responses::{self, ResponseError};
use crate::block_store::BlockStore;
use crate::evm_hypersync_source::query::{BlockField, TransactionField};
use crate::transaction_store::TransactionStore;

/// What a shared read hands to every waiter. The failure rides inside the
/// value so that every waiter receives it.
type Fetched = std::result::Result<Arc<Json>, Arc<RpcError>>;

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

/// The most severe of several failures, rather than whichever settled first. A
/// page's reads are grouped by field selection in a `HashMap`, so "first" is
/// not stable between runs — and the choice decides whether the source is
/// disabled or merely backs off.
fn worst_of(errors: impl IntoIterator<Item = EnrichError>) -> Option<EnrichError> {
    errors.into_iter().max_by_key(EnrichError::severity)
}

/// Collect a fan-out's results, or its worst failure.
fn collect_worst<T>(
    results: impl IntoIterator<Item = Result<T, EnrichError>>,
) -> Result<Vec<T>, EnrichError> {
    let mut values = Vec::new();
    let mut errors = Vec::new();
    for result in results {
        match result {
            Ok(value) => values.push(value),
            Err(error) => errors.push(error),
        }
    }
    match worst_of(errors) {
        Some(error) => Err(error),
        None => Ok(values),
    }
}

/// Block and transaction fields as store masks: what one registration selects,
/// unioned per referenced key into what a page wants, and over the whole chain
/// into what a response is read for.
#[derive(Clone, Copy, Default)]
pub(crate) struct SelectedFields {
    pub block_mask: u64,
    pub tx_mask: u64,
}

impl SelectedFields {
    /// Every field any registration on the chain selects. A block or
    /// transaction response carries them all at once, so reading them now is
    /// what lets a later page with a different selection be served from the
    /// store instead of the provider.
    pub(crate) fn union(fields: impl IntoIterator<Item = SelectedFields>) -> Self {
        fields
            .into_iter()
            .fold(SelectedFields::default(), |acc, f| SelectedFields {
                block_mask: acc.block_mask | f.block_mask,
                tx_mask: acc.tx_mask | f.tx_mask,
            })
    }
}

struct ReferencedBlock {
    mask: u64,
    /// Every distinct hash the logs of this block reported. Each enters the
    /// page as its own observation, so two selections whose `eth_getLogs`
    /// responses straddle a fork disagree inside the page and are caught,
    /// rather than the second hash being dropped as a duplicate.
    log_hashes: Vec<format::Hash>,
}

struct ReferencedTransaction {
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
    blocks: HashMap<u64, ReferencedBlock>,
    transactions: HashMap<TxKey, ReferencedTransaction>,
}

impl PageRefs {
    pub(crate) fn add(
        &mut self,
        block_number: u64,
        transaction_index: u32,
        block_hash: &format::Hash,
        transaction_hash: &format::Hash,
        fields: SelectedFields,
    ) {
        let block = self
            .blocks
            .entry(block_number)
            .or_insert_with(|| ReferencedBlock {
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
            .or_insert_with(|| ReferencedTransaction {
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
    /// The union of every registration's selection on this chain.
    pub chain_fields: SelectedFields,
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
    key: FetchKey,
) -> Result<Arc<Json>, EnrichError> {
    let result = fetches
        .get(key, || {
            let client = client.clone();
            let params = key.params();
            async move {
                client
                    .request::<Json>(key.method(), params)
                    .await
                    .map(Arc::new)
                    .map_err(Arc::new)
            }
        })
        .await;

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
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct ResponsesToRead {
    transaction: bool,
    receipt: bool,
}

impl ResponsesToRead {
    fn for_mask(mask: u64) -> Self {
        let wants = |carrier| mask & tx_mask_of(carrier) != 0;
        let receipt = wants(Carrier::Receipt);
        ResponsesToRead {
            // A selection of only shared fields is served by the transaction.
            transaction: wants(Carrier::Transaction) || (wants(Carrier::Either) && !receipt),
            receipt,
        }
    }

    fn is_empty(self) -> bool {
        !self.transaction && !self.receipt
    }

    /// Every field these responses can fill, which is how far a read may widen
    /// beyond what the page asked for without costing another request.
    fn carries(self) -> u64 {
        let mut mask = 0;
        if self.transaction {
            mask |= tx_mask_of(Carrier::Transaction);
        }
        if self.receipt {
            mask |= tx_mask_of(Carrier::Receipt);
        }
        if !self.is_empty() {
            mask |= tx_mask_of(Carrier::Either);
        }
        mask
    }
}

pub(crate) async fn page(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    request: EnrichRequest<'_>,
) -> Result<EnrichedPage, EnrichError> {
    let EnrichRequest {
        from_block,
        to_block,
        refs,
        known_blocks,
        known_transactions,
        chain_fields,
    } = request;

    let block_plan = plan_blocks(
        &refs,
        from_block,
        to_block,
        known_blocks,
        chain_fields.block_mask,
    );
    let tx_plan = plan_transactions(&refs, known_transactions, chain_fields.tx_mask);

    // Both sides are awaited, then judged together. Taking whichever failed
    // first would make the verdict a race: an unservable selection on the block
    // side would be reported on the attempts where the transactions happened to
    // answer and swallowed as a backoff on the ones where they did not. Waiting
    // on the slower side costs at most one more request timeout, since every
    // read is bounded by its own.
    let (blocks, transactions) = futures_util::future::join(
        fetch_blocks(client, fetches, &block_plan),
        fetch_transactions(client, fetches, &tx_plan),
    )
    .await;
    let (blocks, transactions) = match (blocks, transactions) {
        (Ok(blocks), Ok(transactions)) => (blocks, transactions),
        (blocks, transactions) => {
            return Err(
                worst_of([blocks.err(), transactions.err()].into_iter().flatten())
                    .expect("one of the two sides failed"),
            )
        }
    };

    let page_blocks = BlockStore::new_evm();
    let page_transactions = TransactionStore::new_evm();

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
    fill_block_page(&page_blocks, log_observations, block_plan.covering, blocks);

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
/// they claim no field coverage, then the fetched blocks under the fields they
/// were read for. Every fetched block contributes its parent as one more
/// observation — this response's own view of the block below, which
/// cross-validates against the stored chain at no extra request.
fn fill_block_page(
    page: &BlockStore,
    mut observations: Vec<Block>,
    covering: u64,
    fetched: Vec<Block>,
) {
    observations.extend(fetched.iter().filter_map(|block| {
        // Genesis has no parent to observe, and its `parentHash` is
        // zero rather than absent, so it would enter the page as a
        // hash-only row for block -1 if it were not skipped.
        let number = block.number.filter(|&number| number > 0)?;
        Some(Block {
            number: Some(number - 1),
            hash: Some(block.parent_hash.clone()?),
            ..Default::default()
        })
    }));
    page.insert_evm_blocks(observations);
    page.insert_evm_blocks_covering(fetched, covering);
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

/// The blocks to read and the fields to read them for. One response carries
/// every block field, so the whole page reads the same ones and merges into the
/// store in a single batch.
struct BlockReadPlan {
    covering: u64,
    fields: Vec<BlockField>,
    /// The subset of `fields` some registration on this chain selected. The
    /// rest are read for the reorg check alone, and a response missing one of
    /// those is a bad answer rather than a selection the chain cannot serve.
    selected: Vec<BlockField>,
    numbers: Vec<u64>,
}

/// The transactions to read from one pair of responses. Unlike blocks, what a
/// transaction costs depends on its selection — a receipt, a transaction, or
/// both — so the page's rows are grouped by that and each group is read for as
/// much as its own responses happen to carry.
struct TxReadPlan {
    covering: u64,
    fields: Vec<TransactionField>,
    reads: ResponsesToRead,
    entries: Vec<(TxKey, format::Hash)>,
}

/// Which blocks to read. A referenced block is skipped when the store was
/// already asked for everything this page needs of it; a boundary block never
/// is.
///
/// What they are read for does not depend on the page: one response carries
/// every field, so a block is decoded for everything any registration on the
/// chain selects, plus the reorg fields. That is what lets a page with a
/// different selection be served from the store rather than refetched.
fn plan_blocks(
    refs: &PageRefs,
    from_block: u64,
    to_block: u64,
    known: &BlockStore,
    chain_mask: u64,
) -> BlockReadPlan {
    let boundary = boundary_blocks(from_block, to_block);
    let mut numbers: Vec<u64> = refs
        .blocks
        .iter()
        .filter(|(&number, block_ref)| {
            boundary.contains(&number) || !known.covers(number, block_ref.mask & !BLOCK_KEY_MASK)
        })
        .map(|(&number, _)| number)
        .collect();
    numbers.extend(
        boundary
            .iter()
            .filter(|number| !refs.blocks.contains_key(number)),
    );

    let covering = chain_mask | BLOCK_OBSERVATION_MASK;
    BlockReadPlan {
        covering,
        fields: block_fields_in(covering),
        selected: block_fields_in(chain_mask & !BLOCK_OBSERVATION_MASK),
        numbers,
    }
}

/// Which transactions to read, and from which responses. A transaction whose
/// selected fields all come off the log, or which the store already covers,
/// needs no request at all.
///
/// Whether to read is decided by what the page itself wants; how much to decode
/// is not. Once a response is being fetched anyway it is read for everything
/// the chain selects that it happens to carry — but never for a field that
/// would drag in a second response, which would turn a wider selection
/// elsewhere into requests this page does not need.
fn plan_transactions(
    refs: &PageRefs,
    known: &TransactionStore,
    chain_mask: u64,
) -> Vec<TxReadPlan> {
    #[derive(Default)]
    struct Group {
        wanted: u64,
        entries: Vec<(TxKey, format::Hash)>,
    }

    let mut by_reads: HashMap<ResponsesToRead, Group> = HashMap::new();
    for (&key, tx_ref) in &refs.transactions {
        let wanted = tx_ref.mask & !TX_LOG_MASK;
        if known.covers(key, wanted) {
            continue;
        }
        let reads = ResponsesToRead::for_mask(wanted);
        // Nothing to ask a provider for: every selected field is on the log.
        if reads.is_empty() {
            continue;
        }
        let group = by_reads.entry(reads).or_default();
        group.wanted |= wanted;
        group.entries.push((key, tx_ref.hash.clone()));
    }
    by_reads
        .into_iter()
        .map(|(reads, group)| {
            let covering = group.wanted | (chain_mask & !TX_EAGER_EXCLUDED_MASK & reads.carries());
            TxReadPlan {
                covering,
                fields: tx_fields_in(covering),
                reads,
                entries: group.entries,
            }
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
    block_numbers: &[u64],
) -> Result<BlockStore, EnrichError> {
    let plan = BlockReadPlan {
        covering: BLOCK_OBSERVATION_MASK,
        fields: block_fields_in(BLOCK_OBSERVATION_MASK),
        selected: Vec::new(),
        numbers: block_numbers.to_vec(),
    };
    let blocks = fetch_blocks(client, fetches, &plan).await?;

    let page = BlockStore::new_evm();
    fill_block_page(&page, Vec::new(), plan.covering, blocks);
    Ok(page)
}

/// Fetch and decode every planned block concurrently, keeping the rows together
/// for a single insert.
async fn fetch_blocks(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    plan: &BlockReadPlan,
) -> Result<Vec<Block>, EnrichError> {
    let blocks = join_all(plan.numbers.iter().map(|&number| async move {
        let response = require(client, fetches, FetchKey::Block(number)).await?;
        responses::build_block(&response, number, &plan.fields, &plan.selected)
            .map_err(|error| EnrichError::from_response(number, error))
    }))
    .await;
    collect_worst(blocks)
}

async fn fetch_transactions(
    client: &Arc<JsonRpcClient>,
    fetches: &Fetches,
    groups: &[TxReadPlan],
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
                            group
                                .reads
                                .transaction
                                .then_some(FetchKey::Transaction(key)),
                        ),
                        read_opt(
                            client,
                            fetches,
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
                            None => require(client, fetches, FetchKey::Transaction(key)).await?,
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
    key: Option<FetchKey>,
) -> Result<Option<Arc<Json>>, EnrichError> {
    match key {
        None => Ok(None),
        Some(key) => require(client, fetches, key).await.map(Some),
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
            SelectedFields {
                block_mask,
                tx_mask,
            },
        );
        refs
    }

    fn planned_numbers(plan: &BlockReadPlan) -> Vec<u64> {
        let mut numbers = plan.numbers.clone();
        numbers.sort_unstable();
        numbers
    }

    fn planned_keys(groups: &[TxReadPlan]) -> Vec<TxKey> {
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
        let known = BlockStore::new_evm();
        known.insert_evm_blocks_covering(
            vec![Block {
                number: Some(50),
                ..Default::default()
            }],
            wanted,
        );
        let plan = plan_blocks(&refs_for(50, wanted, 0), 40, 60, &known, wanted);
        assert_eq!(planned_numbers(&plan), vec![40, 60]);
    }

    #[test]
    fn a_block_covered_only_for_other_fields_is_still_read() {
        let known = BlockStore::new_evm();
        known.insert_evm_blocks_covering(
            vec![Block {
                number: Some(50),
                ..Default::default()
            }],
            block_bit(EvmBlockField::GasUsed),
        );
        let miner = block_bit(EvmBlockField::Miner);
        let plan = plan_blocks(&refs_for(50, miner, 0), 40, 60, &known, miner);
        assert_eq!(planned_numbers(&plan), vec![40, 50, 60]);
    }

    #[test]
    fn a_boundary_block_is_read_even_when_the_store_covers_it() {
        // The boundary blocks are this range's reorg observations, so a stored
        // answer — which is some earlier response's view of them — will not do.
        let known = BlockStore::new_evm();
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
        let plan = plan_blocks(&PageRefs::default(), 40, 60, &known, 0);
        assert_eq!(planned_numbers(&plan), vec![40, 60]);
    }

    #[test]
    fn a_block_no_item_wants_fields_from_is_not_read() {
        // Its hash still reaches the page as an observation off the log, which
        // is all reorg detection needs from it.
        let plan = plan_blocks(&refs_for(50, 0, 0), 40, 60, &BlockStore::new_evm(), 0);
        assert_eq!(planned_numbers(&plan), vec![40, 60]);
    }

    #[test]
    fn a_boundary_block_an_item_wants_nothing_from_is_still_read() {
        // The item makes the block referenced but selects no field of it; it is
        // still the range's boundary, so its reorg observation is read.
        let plan = plan_blocks(&refs_for(40, 0, 0), 40, 40, &BlockStore::new_evm(), 0);
        assert_eq!(planned_numbers(&plan), vec![40]);
    }

    #[test]
    fn a_single_block_range_reads_that_block_once() {
        let plan = plan_blocks(&PageRefs::default(), 40, 40, &BlockStore::new_evm(), 0);
        assert_eq!(planned_numbers(&plan), vec![40]);
    }

    #[test]
    fn a_transaction_selected_only_for_log_derived_fields_is_not_read() {
        let refs = refs_for(
            50,
            0,
            tx_bit(EvmTxField::Hash) | tx_bit(EvmTxField::TransactionIndex),
        );
        let plan = plan_transactions(&refs, &TransactionStore::new_evm(), 0);
        assert_eq!(planned_keys(&plan), Vec::<TxKey>::new());
    }

    #[test]
    fn a_transaction_the_store_already_covers_is_not_read_again() {
        let wanted = tx_bit(EvmTxField::Gas);
        let known = TransactionStore::new_evm();
        known.insert_evm_txs_covering(
            vec![Transaction {
                block_number: Some(50u64.into()),
                transaction_index: Some(0u64.into()),
                ..Default::default()
            }],
            wanted,
        );
        let plan = plan_transactions(&refs_for(50, 0, wanted), &known, wanted);
        assert_eq!(planned_keys(&plan), Vec::<TxKey>::new());
    }

    #[test]
    fn a_field_that_came_back_null_still_counts_as_covered() {
        // `to` is null on a contract creation. Judged by stored values alone
        // the row would look unfetched and be requested on every later page.
        let wanted = tx_bit(EvmTxField::To);
        let known = TransactionStore::new_evm();
        known.insert_evm_txs_covering(
            vec![Transaction {
                block_number: Some(50u64.into()),
                transaction_index: Some(0u64.into()),
                to: None,
                ..Default::default()
            }],
            wanted,
        );
        let plan = plan_transactions(&refs_for(50, 0, wanted), &known, wanted);
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
            SelectedFields {
                block_mask: 0,
                tx_mask: 0,
            },
        );
        refs.add(
            50,
            1,
            &hash(0xbb),
            &hash(0xdd),
            SelectedFields {
                block_mask: 0,
                tx_mask: tx_bit(EvmTxField::Gas),
            },
        );
        let plan = plan_transactions(&refs, &TransactionStore::new_evm(), tx_bit(EvmTxField::Gas));
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
                SelectedFields {
                    block_mask: 0,
                    tx_mask: 0,
                },
            );
        }
        assert_eq!(refs.blocks[&50].log_hashes, vec![hash(0xaa), hash(0xbb)]);
    }

    #[test]
    fn rows_read_from_the_same_responses_are_planned_as_one_group() {
        // Grouping is what keeps the per-row work off the hot path: the field
        // list is resolved once per group and the rows merge in one batch. Two
        // selections that differ but are answered by the same request share a
        // group, since what they are decoded for no longer depends on the row.
        let mut refs = PageRefs::default();
        let gas = tx_bit(EvmTxField::Gas);
        let input = tx_bit(EvmTxField::Input);
        let gas_used = tx_bit(EvmTxField::GasUsed);
        for (index, mask) in [(0u32, gas), (1, input), (2, gas_used)] {
            refs.add(
                50,
                index,
                &hash(0xbb),
                &hash(0xc0 + index as u8),
                SelectedFields {
                    block_mask: 0,
                    tx_mask: mask,
                },
            );
        }
        let mut sizes: Vec<usize> = plan_transactions(&refs, &TransactionStore::new_evm(), 0)
            .iter()
            .map(|group| group.entries.len())
            .collect();
        sizes.sort_unstable();
        assert_eq!(sizes, vec![1, 2]);
    }

    #[test]
    fn a_block_is_read_for_every_field_the_chain_selects() {
        // The response carries them whether or not they are decoded, and a page
        // that asks for one of them later must not have to ask again.
        let miner = block_bit(EvmBlockField::Miner);
        let gas_used = block_bit(EvmBlockField::GasUsed);
        let plan = plan_blocks(
            &refs_for(50, miner, 0),
            40,
            60,
            &BlockStore::new_evm(),
            miner | gas_used,
        );
        assert_eq!(
            (plan.covering, plan.fields, plan.selected),
            (
                miner | gas_used | BLOCK_OBSERVATION_MASK,
                block_fields_in(miner | gas_used | BLOCK_OBSERVATION_MASK),
                block_fields_in(miner | gas_used),
            )
        );
    }

    #[test]
    fn a_page_is_served_from_what_an_earlier_pages_read_left_behind() {
        // The payoff, end to end: one page reads block 50 for its own field,
        // the store records what that read covered, and a page selecting a
        // different field of the same block plans no request for it.
        let miner = block_bit(EvmBlockField::Miner);
        let gas_used = block_bit(EvmBlockField::GasUsed);
        let chain_mask = miner | gas_used;
        let known = BlockStore::new_evm();
        let first = plan_blocks(&refs_for(50, miner, 0), 40, 60, &known, chain_mask);
        known.insert_evm_blocks_covering(
            vec![Block {
                number: Some(50),
                ..Default::default()
            }],
            first.covering,
        );
        let second = plan_blocks(&refs_for(50, gas_used, 0), 40, 60, &known, chain_mask);
        assert_eq!(
            (planned_numbers(&first), planned_numbers(&second)),
            (vec![40, 50, 60], vec![40, 60])
        );
    }

    #[test]
    fn a_transaction_is_read_for_every_chain_field_its_responses_carry() {
        // `input` rides the same `eth_getTransactionByHash` the page already
        // pays for, so it is decoded too — but `gasUsed` is on the receipt, and
        // widening to it would cost a request this page never needed.
        let gas = tx_bit(EvmTxField::Gas);
        let input = tx_bit(EvmTxField::Input);
        let gas_used = tx_bit(EvmTxField::GasUsed);
        let plan = plan_transactions(
            &refs_for(50, 0, gas),
            &TransactionStore::new_evm(),
            gas | input | gas_used,
        );
        assert_eq!(
            plan.iter()
                .map(|group| (group.covering, group.reads))
                .collect::<Vec<_>>(),
            vec![(
                gas | input,
                ResponsesToRead {
                    transaction: true,
                    receipt: false
                }
            )]
        );
    }

    #[test]
    fn a_chain_wide_selection_never_turns_into_a_request_of_its_own() {
        // The rule the widening lives under: what the chain selects decides how
        // much of a response is read, never whether one is read. A page whose
        // every field comes off the log still costs nothing.
        let plan = plan_transactions(
            &refs_for(50, 0, tx_bit(EvmTxField::Hash)),
            &TransactionStore::new_evm(),
            tx_bit(EvmTxField::Gas) | tx_bit(EvmTxField::GasUsed),
        );
        assert_eq!(planned_keys(&plan), Vec::<TxKey>::new());
    }

    #[test]
    fn fields_that_cost_more_than_the_response_are_left_to_the_page_that_wants_them() {
        // `effectiveGasPrice` falls back to a second request on chains predating
        // EIP-1559, and the list-shaped fields are the only ones whose decoding
        // is more than a word. None is worth reading for a page that did not ask.
        let gas = tx_bit(EvmTxField::Gas);
        let plan = plan_transactions(
            &refs_for(50, 0, gas),
            &TransactionStore::new_evm(),
            gas | TX_EAGER_EXCLUDED_MASK,
        );
        assert_eq!(
            plan.iter().map(|group| group.covering).collect::<Vec<_>>(),
            vec![gas]
        );
    }

    #[test]
    fn a_page_that_wants_an_excluded_field_is_still_read_for_it() {
        // Excluded from the widening, not from the selection.
        let access_list = tx_bit(EvmTxField::AccessList);
        let plan = plan_transactions(
            &refs_for(50, 0, access_list),
            &TransactionStore::new_evm(),
            access_list,
        );
        assert_eq!(
            plan.iter().map(|group| group.covering).collect::<Vec<_>>(),
            vec![access_list]
        );
    }

    #[test]
    fn the_carrier_of_the_selected_fields_decides_which_responses_are_read() {
        let plans = (
            // Transaction-only.
            ResponsesToRead::for_mask(tx_bit(EvmTxField::Input)),
            // Receipt-only.
            ResponsesToRead::for_mask(tx_bit(EvmTxField::GasUsed)),
            // One of each.
            ResponsesToRead::for_mask(tx_bit(EvmTxField::Input) | tx_bit(EvmTxField::GasUsed)),
            // Carried by both, so the transaction alone answers it.
            ResponsesToRead::for_mask(tx_bit(EvmTxField::From)),
            // Carried by both, alongside a receipt-only field: no second request.
            ResponsesToRead::for_mask(tx_bit(EvmTxField::From) | tx_bit(EvmTxField::GasUsed)),
        );
        assert_eq!(
            plans,
            (
                ResponsesToRead {
                    transaction: true,
                    receipt: false
                },
                ResponsesToRead {
                    transaction: false,
                    receipt: true
                },
                ResponsesToRead {
                    transaction: true,
                    receipt: true
                },
                ResponsesToRead {
                    transaction: true,
                    receipt: false
                },
                ResponsesToRead {
                    transaction: false,
                    receipt: true
                },
            )
        );
    }
}

#[cfg(test)]
mod shared_read_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    /// A JSON-RPC server that answers every request with a block after
    /// `delay`, counting what it served.
    async fn rpc_server(delay: Duration, served: Arc<AtomicUsize>) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let served = served.clone();
                tokio::spawn(async move {
                    let mut buffered = Vec::new();
                    while let Ok(Some(_)) =
                        crate::mock_http::read_request(&mut stream, &mut buffered).await
                    {
                        tokio::time::sleep(delay).await;
                        served.fetch_add(1, Ordering::SeqCst);
                        crate::mock_http::write_response(
                            &mut stream,
                            200,
                            &[("Content-Type", "application/json")],
                            br#"{"jsonrpc":"2.0","id":1,"result":{"number":"0x1"}}"#,
                        )
                        .await
                        .unwrap();
                    }
                });
            }
        });
        url
    }

    fn client(url: String) -> Arc<JsonRpcClient> {
        Arc::new(JsonRpcClient::new(url, 5_000, 10, None).unwrap())
    }

    #[tokio::test]
    async fn callers_sharing_one_read_bill_it_once() {
        // Two partitions at the head read the same block at once. One request
        // goes out, and the source's metrics must count exactly one.
        let served = Arc::new(AtomicUsize::new(0));
        let client = client(rpc_server(Duration::from_millis(30), served.clone()).await);
        let fetches = Fetches::default();
        let (first, second) = tokio::join!(
            require(&client, &fetches, FetchKey::Block(1)),
            require(&client, &fetches, FetchKey::Block(1)),
        );
        assert_eq!(
            (
                first.is_ok(),
                second.is_ok(),
                served.load(Ordering::SeqCst),
                client.take_stats().len(),
            ),
            (true, true, 1, 1)
        );
    }

    #[tokio::test]
    async fn a_read_whose_creator_gave_up_is_still_billed_once_it_answers() {
        // The call that issued the request gives up; another that joined it
        // drives it to the end, and the request it cost still reaches the
        // source's metrics.
        let served = Arc::new(AtomicUsize::new(0));
        let client = client(rpc_server(Duration::from_millis(100), served.clone()).await);
        let fetches = Fetches::default();
        let cancelled = tokio::time::timeout(
            Duration::from_millis(30),
            require(&client, &fetches, FetchKey::Block(1)),
        );
        let joined = async {
            tokio::time::sleep(Duration::from_millis(1)).await;
            require(&client, &fetches, FetchKey::Block(1)).await
        };
        let (cancelled, joined) = tokio::join!(cancelled, joined);
        assert_eq!(
            (
                cancelled.is_err(),
                joined.is_ok(),
                served.load(Ordering::SeqCst),
                client.take_stats().len(),
            ),
            (true, true, 1, 1)
        );
    }
}
