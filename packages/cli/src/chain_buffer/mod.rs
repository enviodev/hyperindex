//! A chain's fetched data, from the moment a source returns it until the
//! caller removes it: logs, instructions or receipts, their transactions and
//! blocks, as sorted tables. The buffer keeps no processing state; a build
//! reads a range of it, matching and decoding as it walks.

pub(crate) mod decode;
pub(crate) mod decoded;
pub(crate) mod deliver;
pub(crate) mod evm;
pub(crate) mod fuel;
pub(crate) mod matching;
pub(crate) mod matching_fuel;
pub(crate) mod matching_svm;
pub(crate) mod matching_transactions;
pub(crate) mod merge;
pub(crate) mod page;
pub(crate) mod schedule;
pub(crate) mod simulate_evm;
pub(crate) mod svm;
pub(crate) mod table;
pub(crate) mod walk;

use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::Result;
use napi::bindgen_prelude::ArrayBuffer;
use napi::Env;
use napi_derive::napi;
use strum::VariantArray;

use crate::address_store::AddressStore;
use crate::evm_hypersync_source::selection as evm_selection;
use crate::evm_hypersync_source::types::OnEventRegistrationInput;
use crate::fuel_hypersync_source::selection as fuel_selection;
use crate::fuel_hypersync_source::selection::FuelOnEventRegistrationInput;
use crate::svm_hypersync_source::selection as svm_selection;
use crate::svm_hypersync_source::selection::SvmProgramInput;
use decoded::DecodedEvents;
use deliver::{BuiltItems, Columns};
use matching_transactions::{OnTransactionRegistrationInput, TransactionMatcher};
use merge::HashMismatch;
use page::Page;
use schedule::{BlockHandlerInput, Schedule};
use table::{make_key, ChunkBuilder, RowRef, Schema, Table, LAST_BLOCK};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Ecosystem {
    Evm,
    Svm,
    Fuel,
}

impl Ecosystem {
    pub(crate) fn parse(name: &str) -> Result<Self> {
        Ok(match name {
            "evm" => Ecosystem::Evm,
            "svm" => Ecosystem::Svm,
            "fuel" => Ecosystem::Fuel,
            other => anyhow::bail!("Unknown ecosystem {other}"),
        })
    }

    /// The events, transactions and blocks tables.
    pub(crate) fn schemas(self) -> [Schema; 3] {
        match self {
            Ecosystem::Evm => [
                evm::logs_schema(),
                evm::transactions_schema(),
                evm::blocks_schema(),
            ],
            Ecosystem::Svm => [
                svm::instructions_schema(),
                svm::transactions_schema(),
                svm::blocks_schema(),
            ],
            Ecosystem::Fuel => [
                fuel::receipts_schema(),
                evm::transactions_schema(),
                fuel::blocks_schema(),
            ],
        }
    }

    pub(crate) fn hash_column(self) -> usize {
        match self {
            Ecosystem::Svm => svm::BLOCK_HASH_COLUMN,
            Ecosystem::Fuel => fuel::BLOCK_HASH_COLUMN,
            Ecosystem::Evm => evm::BLOCK_HASH_COLUMN,
        }
    }

    pub(crate) fn hash_text(self, bytes: &[u8]) -> String {
        match self {
            Ecosystem::Svm => svm::hash_text(bytes),
            Ecosystem::Evm | Ecosystem::Fuel => evm::hash_text(bytes),
        }
    }

    pub(crate) fn parse_hash(self, text: &str) -> Result<Vec<u8>> {
        match self {
            Ecosystem::Svm => Ok(svm::hash_bytes(text)),
            Ecosystem::Fuel => fuel::hash_bytes(text),
            Ecosystem::Evm => evm::hash_bytes(text),
        }
    }

    pub(crate) fn push_observed_block(
        self,
        builder: &mut ChunkBuilder,
        number: u64,
        hash: Option<&[u8]>,
        timestamp: Option<u64>,
    ) {
        match self {
            Ecosystem::Svm => svm::push_observed_block(builder, number, hash, timestamp),
            Ecosystem::Fuel => {
                fuel::push_block(builder, number, hash, timestamp.map(|time| time as i64))
            }
            Ecosystem::Evm => evm::push_observed_block(builder, number, hash, timestamp),
        }
    }

    fn block_timestamp(self, row: &RowRef) -> Option<i64> {
        match self {
            Ecosystem::Svm => svm::block_timestamp(row),
            Ecosystem::Fuel => fuel::block_timestamp(row),
            Ecosystem::Evm => evm::block_timestamp(row),
        }
    }
}

pub(crate) struct EvmRegistrations {
    pub(crate) inputs: Vec<OnEventRegistrationInput>,
    pub(crate) selection: evm_selection::SelectionBuilder,
    pub(crate) matcher: matching::EvmMatcher,
    pub(crate) decoder: decode::evm::EvmDecoder,
}

pub(crate) struct SvmRegistrations {
    pub(crate) selection: svm_selection::SelectionBuilder,
    pub(crate) matcher: matching_svm::SvmMatcher,
}

pub(crate) struct FuelRegistrations {
    pub(crate) selection: fuel_selection::SelectionBuilder,
    pub(crate) matcher: matching_fuel::FuelMatcher,
}

pub(crate) enum Registrations {
    Evm(Arc<EvmRegistrations>),
    Svm(Arc<SvmRegistrations>),
    Fuel(Arc<FuelRegistrations>),
}

impl Registrations {
    fn compile(
        input: RegistrationsInput,
        contract_registers: &matching::ContractRegisters,
        should_checksum: bool,
        address_store: &AddressStore,
    ) -> Result<Self> {
        Ok(match input {
            RegistrationsInput::Evm { registrations } => {
                Registrations::Evm(Arc::new(EvmRegistrations {
                    selection: evm_selection::SelectionBuilder::from_registrations(&registrations)?,
                    matcher: matching::EvmMatcher::new(
                        &registrations,
                        contract_registers.clone(),
                        address_store,
                    )?,
                    decoder: decode::evm::EvmDecoder::new(&registrations, should_checksum)?,
                    inputs: registrations,
                }))
            }
            RegistrationsInput::Svm { programs } => {
                let selection = svm_selection::SelectionBuilder::from_programs(
                    &programs,
                    &address_store.handle().read().unwrap(),
                )?;
                Registrations::Svm(Arc::new(SvmRegistrations {
                    matcher: matching_svm::SvmMatcher::new(
                        &selection,
                        contract_registers.clone(),
                        address_store,
                    )?,
                    selection,
                }))
            }
            RegistrationsInput::Fuel { registrations } => {
                Registrations::Fuel(Arc::new(FuelRegistrations {
                    selection: fuel_selection::SelectionBuilder::from_registrations(
                        &registrations,
                        &address_store.handle().read().unwrap(),
                    )?,
                    matcher: matching_fuel::FuelMatcher::new(
                        &registrations,
                        contract_registers.clone(),
                        address_store,
                    )?,
                }))
            }
        })
    }

    fn ecosystem(&self) -> Ecosystem {
        match self {
            Registrations::Evm(_) => Ecosystem::Evm,
            Registrations::Svm(_) => Ecosystem::Svm,
            Registrations::Fuel(_) => Ecosystem::Fuel,
        }
    }
}

/// A chain's registrations compiled once, for its buffer's builds and for
/// every source querying the chain.
pub(crate) struct Shared {
    pub(crate) ecosystem: Ecosystem,
    pub(crate) should_checksum: bool,
    pub(crate) registrations: Registrations,
    pub(crate) schedule: Schedule,
    pub(crate) transaction_matcher: TransactionMatcher,
    /// By event registration index.
    transaction_masks: Vec<u64>,
    event_block_masks: Vec<u64>,
    contract_registers: matching::ContractRegisters,
}

impl Shared {
    pub(crate) fn evm(&self) -> Result<Arc<EvmRegistrations>> {
        match &self.registrations {
            Registrations::Evm(evm) => Ok(evm.clone()),
            _ => anyhow::bail!("the chain buffer holds no EVM registrations"),
        }
    }

    pub(crate) fn svm(&self) -> Result<Arc<SvmRegistrations>> {
        match &self.registrations {
            Registrations::Svm(svm) => Ok(svm.clone()),
            _ => anyhow::bail!("the chain buffer holds no SVM registrations"),
        }
    }

    pub(crate) fn fuel(&self) -> Result<Arc<FuelRegistrations>> {
        match &self.registrations {
            Registrations::Fuel(fuel) => Ok(fuel.clone()),
            _ => anyhow::bail!("the chain buffer holds no Fuel registrations"),
        }
    }

    pub(crate) fn has_contract_register(&self, registration: u32) -> bool {
        self.contract_registers.has(registration)
    }

    pub(crate) fn transaction_mask(&self, registration: u32) -> u64 {
        self.transaction_masks
            .get(registration as usize)
            .copied()
            .unwrap_or(0)
    }

    pub(crate) fn event_block_mask(&self, registration: u32) -> u64 {
        self.event_block_masks
            .get(registration as usize)
            .copied()
            .unwrap_or(0)
    }

    /// The transaction and block fields a transaction registration reads.
    pub(crate) fn on_transaction_masks(&self, registration: u32) -> (u64, u64) {
        self.transaction_matcher
            .registration(registration)
            .map_or((0, 0), |registration| {
                (registration.transaction_mask, registration.block_mask)
            })
    }

    pub(crate) fn block_handler_mask(&self, registration: u32) -> Option<u64> {
        self.schedule
            .handler(registration)
            .and_then(|handler| handler.block_field_mask)
    }

    pub(crate) fn transaction_columns(
        &self,
        rows: &[Option<RowRef>],
        indexes: &[u32],
        masks: &[u64],
    ) -> Result<Columns> {
        match self.ecosystem {
            Ecosystem::Svm => svm::transaction_columns(rows, indexes, masks),
            Ecosystem::Evm | Ecosystem::Fuel => {
                evm::transaction_columns(rows, indexes, masks, self.should_checksum)
            }
        }
    }

    pub(crate) fn block_columns(
        &self,
        rows: &[Option<RowRef>],
        numbers: &[u64],
        masks: &[u64],
    ) -> Result<Columns> {
        match self.ecosystem {
            Ecosystem::Svm => svm::block_columns(rows, numbers, masks),
            Ecosystem::Fuel => fuel::block_columns(rows, numbers, masks),
            Ecosystem::Evm => evm::block_columns(rows, numbers, masks, self.should_checksum),
        }
    }
}

pub(crate) struct Tables {
    pub(crate) events: Table,
    pub(crate) transactions: Table,
    pub(crate) blocks: Table,
    pub(crate) decoded: DecodedEvents,
}

/// A chain's event registrations, tagged by its ecosystem.
#[napi(discriminant = "ecosystem", discriminant_case = "lowercase")]
pub enum RegistrationsInput {
    Evm {
        registrations: Vec<OnEventRegistrationInput>,
    },
    /// The programs with their instructions and registrations.
    Svm { programs: Vec<SvmProgramInput> },
    Fuel {
        registrations: Vec<FuelOnEventRegistrationInput>,
    },
}

#[napi(object)]
pub struct ChainBufferConfig {
    pub registrations: RegistrationsInput,
    pub should_checksum: bool,
    pub contract_register_indexes: Vec<i64>,
    pub block_handlers: Vec<BlockHandlerInput>,
    /// By event registration index: the transaction fields each selects.
    pub transaction_masks: Vec<f64>,
    /// By event registration index: the block fields each selects.
    pub event_block_masks: Vec<f64>,
    /// EVM only.
    pub transaction_registrations: Vec<OnTransactionRegistrationInput>,
}

#[napi(object)]
pub struct MergedPage {
    /// The block whose received hash differs from the stored one. Unless the
    /// merge only reports, nothing was merged.
    pub mismatch: Option<HashMismatch>,
    pub rows_kept: u32,
    /// Blocks holding an event a `contractRegister` runs on, ascending.
    pub registering_block_numbers: Vec<i64>,
}

#[napi(object)]
pub struct HashedBlocks {
    pub block_numbers: Vec<i64>,
    pub hashes: Vec<String>,
}

#[napi]
pub struct ChainBuffer {
    shared: Arc<Shared>,
    tables: Mutex<Tables>,
}

pub(crate) fn to_napi(error: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{error:#}"))
}

fn block(number: i64) -> u64 {
    u64::try_from(number).unwrap_or(0)
}

impl ChainBuffer {
    /// The chain's compiled registrations, for a source querying the chain.
    pub(crate) fn shared(&self) -> Arc<Shared> {
        self.shared.clone()
    }

    pub(crate) fn tables(&self) -> MutexGuard<'_, Tables> {
        self.tables.lock().unwrap()
    }

    fn snapshots(&self, from_block: u64, to_block: u64) -> walk::Snapshots {
        let tables = self.tables();
        walk::Snapshots {
            events: tables.events.snapshot(),
            transactions: tables.transactions.snapshot(),
            blocks: tables.blocks.snapshot(),
            decoded: tables.decoded.copy_range(from_block, to_block),
        }
    }

    /// The items of blocks `[from_block, to_block]`, built on this thread.
    #[cfg(test)]
    pub(crate) fn build_items_for_test(&self, from_block: u64, to_block: u64) -> Vec<walk::Item> {
        let snapshots = self.snapshots(from_block, to_block);
        walk::build(
            &self.shared,
            &snapshots,
            walk::Range::Handlers {
                from_block,
                max_block: to_block,
            },
            usize::MAX,
        )
        .unwrap()
        .items
    }

    async fn build(
        &self,
        range: walk::Range,
        from_block: u64,
        to_block: u64,
        target_items: u32,
    ) -> napi::Result<BuiltItems> {
        let snapshots = self.snapshots(from_block, to_block);
        let shared = self.shared.clone();
        tokio::task::spawn_blocking(move || {
            walk::build(&shared, &snapshots, range, target_items as usize)
                .and_then(deliver::lay_out)
        })
        .await
        .map_err(|error| napi::Error::from_reason(format!("build failed: {error}")))?
        .map_err(to_napi)
    }

    /// Whether transaction rows count as rows a build makes items from: with
    /// transaction handlers they do, matched or only joined to a log.
    fn counts_transaction_rows(&self) -> bool {
        !self.shared.transaction_matcher.is_empty()
    }

    /// The rows of blocks `[from, to]` a build makes items from.
    fn count_rows_in_block_range(&self, tables: &Tables, from: u64, to: u64) -> usize {
        let transactions = if self.counts_transaction_rows() {
            tables.transactions.count_in_block_range(from, to)
        } else {
            0
        };
        tables.events.count_in_block_range(from, to)
            + tables.decoded.count_range(from, to)
            + transactions
    }

    /// Whether the stored transaction holds every field of `mask`.
    pub(crate) fn has_transaction_fields(&self, block_number: u64, index: u32, mask: u64) -> bool {
        mask == 0
            || self
                .tables()
                .transactions
                .find(make_key(block_number, index as u64), 0)
                .is_some_and(|row| row.fetched() & mask == mask)
    }

    /// Whether the stored block holds every field of `mask`.
    pub(crate) fn has_block_fields(&self, block_number: u64, mask: u64) -> bool {
        mask == 0
            || self
                .tables()
                .blocks
                .find(make_key(block_number, 0), 0)
                .is_some_and(|row| row.fetched() & mask == mask)
    }
}

#[napi]
impl ChainBuffer {
    #[napi(factory)]
    pub fn make(config: ChainBufferConfig, address_store: &AddressStore) -> napi::Result<Self> {
        let contract_registers =
            matching::ContractRegisters::from_indexes(&config.contract_register_indexes)
                .map_err(to_napi)?;
        let registrations = Registrations::compile(
            config.registrations,
            &contract_registers,
            config.should_checksum,
            address_store,
        )
        .map_err(to_napi)?;
        let ecosystem = registrations.ecosystem();
        if ecosystem != Ecosystem::Evm && !config.transaction_registrations.is_empty() {
            return Err(napi::Error::from_reason(
                "transaction handlers are supported on EVM chains only",
            ));
        }
        let [events, transactions, blocks] = ecosystem.schemas();
        Ok(ChainBuffer {
            shared: Arc::new(Shared {
                ecosystem,
                should_checksum: config.should_checksum,
                registrations,
                schedule: Schedule::new(&config.block_handlers).map_err(to_napi)?,
                transaction_matcher: TransactionMatcher::new(&config.transaction_registrations)
                    .map_err(to_napi)?,
                transaction_masks: config.transaction_masks.iter().map(|m| *m as u64).collect(),
                event_block_masks: config.event_block_masks.iter().map(|m| *m as u64).collect(),
                contract_registers,
            }),
            tables: Mutex::new(Tables {
                events: Table::new(events),
                transactions: Table::new(transactions),
                blocks: Table::new(blocks),
                decoded: DecodedEvents::default(),
            }),
        })
    }

    /// Compares the page's block hashes at or above `reorg_threshold` with
    /// the stored ones, and merges the page unless one differs; with
    /// `report_only` it merges either way. The page is left empty.
    #[napi]
    pub fn merge_page(&self, page: &Page, reorg_threshold: i64, report_only: bool) -> MergedPage {
        let data = page.take();
        let merged = merge::merge_page(
            &self.shared,
            &mut self.tables(),
            data,
            block(reorg_threshold),
            report_only,
        );
        MergedPage {
            mismatch: merged.mismatch,
            rows_kept: merged.rows_kept as u32,
            registering_block_numbers: merged
                .registering_blocks
                .into_iter()
                .map(|block| block as i64)
                .collect(),
        }
    }

    /// Builds the items of blocks `[from_block, max_block]`, stopping at the
    /// first block boundary at or past `target_items`.
    #[napi]
    pub async fn build_handler_items(
        &self,
        from_block: i64,
        max_block: i64,
        target_items: u32,
    ) -> napi::Result<BuiltItems> {
        let (from_block, max_block) = (block(from_block), block(max_block));
        self.build(
            walk::Range::Handlers {
                from_block,
                max_block,
            },
            from_block,
            max_block,
            target_items,
        )
        .await
    }

    /// Builds the items of exactly these blocks for the registrations with a
    /// `contractRegister`, stopping at the first block boundary at or past
    /// `target_items`.
    #[napi]
    pub async fn build_contract_register_items(
        &self,
        block_numbers: Vec<i64>,
        target_items: u32,
    ) -> napi::Result<BuiltItems> {
        let mut blocks: Vec<u64> = block_numbers.into_iter().map(block).collect();
        blocks.sort_unstable();
        blocks.dedup();
        let (from, to) = match (blocks.first(), blocks.last()) {
            (Some(from), Some(to)) => (*from, *to),
            _ => (1, 0),
        };
        self.build(
            walk::Range::ContractRegister { blocks },
            from,
            to,
            target_items,
        )
        .await
    }

    /// Removes transactions and everything inside them in blocks
    /// `[from_block, to_block]`: logs, instructions, receipts and decoded
    /// events.
    #[napi]
    pub fn remove_transaction_data_in_block_range(&self, from_block: i64, to_block: i64) {
        let (from, to) = (block(from_block), block(to_block).min(LAST_BLOCK));
        let mut tables = self.tables();
        tables.transactions.remove_block_range(from, to);
        tables.events.remove_block_range(from, to);
        tables.decoded.remove_block_range(from, to);
    }

    /// Removes block rows of `[from_block, to_block]`, hashes included.
    #[napi]
    pub fn remove_blocks_in_block_range(&self, from_block: i64, to_block: i64) {
        let (from, to) = (block(from_block), block(to_block).min(LAST_BLOCK));
        self.tables().blocks.remove_block_range(from, to);
    }

    /// Rows and block handler runs of blocks `[from_block, to_block]`: what a
    /// build of the range produces at most.
    #[napi]
    pub fn count_items_in_block_range(&self, from_block: i64, to_block: i64) -> u32 {
        if to_block < from_block {
            return 0;
        }
        let (from, to) = (block(from_block), block(to_block).min(LAST_BLOCK));
        let rows = self.count_rows_in_block_range(&self.tables(), from, to);
        rows as u32 + self.shared.schedule.count_runs(from, to, |_| true) as u32
    }

    /// Runs of the block handlers `registration_indexes` names on blocks
    /// `[from_block, to_block]`.
    #[napi]
    pub fn count_block_handler_runs_in_block_range(
        &self,
        from_block: i64,
        to_block: i64,
        registration_indexes: Vec<u32>,
    ) -> u32 {
        if to_block < from_block {
            return 0;
        }
        self.shared.schedule.count_runs(
            block(from_block),
            block(to_block).min(LAST_BLOCK),
            |index| registration_indexes.contains(&index),
        ) as u32
    }

    /// The block of the row `row_offset` rows past the first one at or above
    /// `from_block`, counting the rows `count_items_in_block_range` counts.
    #[napi]
    pub fn get_block_number_of_row_at(&self, from_block: i64, row_offset: u32) -> Option<i64> {
        let from = block(from_block);
        let tables = self.tables();
        if tables.decoded.len() == 0 && !self.counts_transaction_rows() {
            return tables
                .events
                .block_number_of_row_at(from, row_offset as usize)
                .map(|block| block as i64);
        }
        let mut events = tables
            .events
            .rows_in_block_range(from, LAST_BLOCK)
            .map(|row| row.block_number())
            .peekable();
        let decoded = tables.decoded.copy_range(from, LAST_BLOCK);
        let mut decoded = decoded.iter().map(|event| event.block_number).peekable();
        let mut transactions = self
            .counts_transaction_rows()
            .then(|| tables.transactions.rows_in_block_range(from, LAST_BLOCK))
            .into_iter()
            .flatten()
            .map(|row| row.block_number())
            .peekable();
        let mut remaining = row_offset;
        loop {
            let next = [events.peek(), decoded.peek(), transactions.peek()]
                .into_iter()
                .enumerate()
                .filter_map(|(stream, block)| block.map(|block| (*block, stream)))
                .min()
                .and_then(|(_, stream)| match stream {
                    0 => events.next(),
                    1 => decoded.next(),
                    _ => transactions.next(),
                });
            match next {
                None => return None,
                Some(block) if remaining == 0 => return Some(block as i64),
                Some(_) => remaining -= 1,
            }
        }
    }

    /// The bytes the buffer's tables hold.
    #[napi]
    pub fn heap_bytes(&self) -> f64 {
        let tables = self.tables();
        (tables.events.heap_bytes() + tables.transactions.heap_bytes() + tables.blocks.heap_bytes())
            as f64
    }

    /// Every stored row a build makes items from.
    #[napi]
    pub fn row_count(&self) -> u32 {
        let tables = self.tables();
        let transactions = if self.counts_transaction_rows() {
            tables.transactions.len()
        } else {
            0
        };
        (tables.events.len() + tables.decoded.len() + transactions) as u32
    }

    /// Every stored hash of blocks `[from_block, below_block)`, ascending.
    #[napi]
    pub fn get_block_hashes(&self, from_block: i64, below_block: i64) -> HashedBlocks {
        let mut hashed = HashedBlocks {
            block_numbers: Vec::new(),
            hashes: Vec::new(),
        };
        if below_block <= from_block.max(0) {
            return hashed;
        }
        let ecosystem = self.shared.ecosystem;
        let tables = self.tables();
        for row in tables
            .blocks
            .rows_in_block_range(block(from_block), block(below_block - 1).min(LAST_BLOCK))
        {
            if let Some(hash) = row.bytes_at(ecosystem.hash_column()) {
                hashed.block_numbers.push(row.block_number() as i64);
                hashed.hashes.push(ecosystem.hash_text(hash));
            }
        }
        hashed
    }

    /// The highest of `block_numbers`, taken in ascending order, up to which
    /// the page's hashes all match the stored ones.
    #[napi]
    pub fn find_latest_block_with_matching_hash(
        &self,
        page: &Page,
        block_numbers: Vec<i64>,
    ) -> Option<i64> {
        let mut requested = block_numbers;
        requested.sort_unstable();
        requested.dedup();
        let tables = self.tables();
        let page = page.data.lock().unwrap();
        let column = self.shared.ecosystem.hash_column();
        let mut latest = None;
        for block_number in requested {
            let Ok(number) = u64::try_from(block_number) else {
                return latest;
            };
            let stored = tables
                .blocks
                .find(make_key(number, 0), 0)
                .and_then(|row| row.bytes_at(column).map(<[u8]>::to_vec));
            match (stored, page.hash(number)) {
                (Some(stored), Some(received)) if stored == received => latest = Some(block_number),
                _ => return latest,
            }
        }
        latest
    }

    /// The time of a stored block. With `allow_skipped_slot`, an SVM slot
    /// with no block reads the time of the last slot below it that has one.
    #[napi]
    pub fn get_block_timestamp(&self, block_number: i64, allow_skipped_slot: bool) -> Option<i64> {
        let number = u64::try_from(block_number).ok()?;
        let ecosystem = self.shared.ecosystem;
        let tables = self.tables();
        if let Some(row) = tables.blocks.find(make_key(number, 0), 0) {
            return ecosystem.block_timestamp(&row);
        }
        if ecosystem != Ecosystem::Svm || !allow_skipped_slot {
            return None;
        }
        let timestamp = tables
            .blocks
            .rows_down_from_block(number)
            .find_map(|row| ecosystem.block_timestamp(&row));
        timestamp
    }

    #[napi]
    pub fn lend_rows<'env>(env: &'env Env, handle: u32) -> napi::Result<Vec<ArrayBuffer<'env>>> {
        deliver::lend_rows(env, handle)
    }

    #[napi]
    pub fn release_rows(handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        deliver::release_rows(handle, buffers)
    }
}

fn field_names<F: Copy>(variants: &[F], name: impl Fn(F) -> &'static str) -> Vec<String> {
    variants
        .iter()
        .map(|&field| name(field).to_string())
        .collect()
}

// The field orders below are the bit positions of the selection masks, which
// the ReScript field arrays are tested against. Reached only through the
// addon's C ABI, which the test target does not build.

#[allow(dead_code)]
#[napi]
pub(crate) fn evm_block_field_names() -> Vec<String> {
    field_names(evm::EvmBlockField::VARIANTS, evm::EvmBlockField::name)
}

#[allow(dead_code)]
#[napi]
pub(crate) fn evm_transaction_field_names() -> Vec<String> {
    field_names(evm::EvmTxField::VARIANTS, evm::EvmTxField::name)
}

#[allow(dead_code)]
#[napi]
pub(crate) fn svm_block_field_names() -> Vec<String> {
    field_names(svm::SvmBlockField::VARIANTS, svm::SvmBlockField::name)
}

#[allow(dead_code)]
#[napi]
pub(crate) fn svm_transaction_field_names() -> Vec<String> {
    field_names(svm::SvmTxField::VARIANTS, svm::SvmTxField::name)
}

#[allow(dead_code)]
#[napi]
pub(crate) fn fuel_block_field_names() -> Vec<String> {
    field_names(fuel::FuelBlockField::VARIANTS, fuel::FuelBlockField::name)
}
