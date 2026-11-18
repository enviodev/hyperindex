//! A chain's fetched data, from the moment a source returns it until the
//! caller removes it: logs, instructions or receipts, their transactions and
//! blocks, as sorted tables. The buffer keeps no processing state; a build
//! reads a range of it, matching and decoding as it walks.

pub(crate) mod decode;
pub(crate) mod decoded;
pub(crate) mod deliver;
pub(crate) mod evm;
pub(crate) mod matching;
pub(crate) mod merge;
pub(crate) mod page;
pub(crate) mod schedule;
pub(crate) mod table;
pub(crate) mod walk;

use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::Result;
use napi::bindgen_prelude::ArrayBuffer;
use napi::Env;
use napi_derive::napi;

use crate::address_store::AddressStore;
use crate::evm_hypersync_source::types::OnEventRegistrationInput;
use decoded::DecodedEvents;
use deliver::{BuiltItems, Columns};
use merge::HashMismatch;
use page::Page;
use schedule::{BlockHandlerInput, Schedule};
use table::{make_key, ChunkBuilder, RowRef, Schema, Table, POSITION_BITS};

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
            Ecosystem::Svm | Ecosystem::Fuel => [
                evm::logs_schema(),
                evm::transactions_schema(),
                evm::blocks_schema(),
            ],
        }
    }

    pub(crate) fn hash_column(self) -> usize {
        evm::BLOCK_HASH_COLUMN
    }

    pub(crate) fn hash_text(self, bytes: &[u8]) -> String {
        evm::hash_text(bytes)
    }

    pub(crate) fn parse_hash(self, text: &str) -> Result<Vec<u8>> {
        evm::hash_bytes(text)
    }

    pub(crate) fn push_observed_block(
        self,
        builder: &mut ChunkBuilder,
        number: u64,
        hash: Option<&[u8]>,
        timestamp: Option<u64>,
    ) {
        evm::push_observed_block(builder, number, hash, timestamp)
    }

    fn block_timestamp(self, row: &RowRef) -> Option<i64> {
        evm::block_timestamp(row)
    }
}

pub(crate) struct EvmRegistrations {
    pub(crate) matcher: matching::EvmMatcher,
    pub(crate) decoder: decode::evm::EvmDecoder,
}

/// What a build needs beside the rows, fixed when the buffer is made.
pub(crate) struct Shared {
    pub(crate) ecosystem: Ecosystem,
    pub(crate) should_checksum: bool,
    pub(crate) evm: Option<EvmRegistrations>,
    pub(crate) schedule: Schedule,
    /// By event registration index.
    transaction_masks: Vec<u64>,
    event_block_masks: Vec<u64>,
    contract_register: Vec<bool>,
}

impl Shared {
    pub(crate) fn has_contract_register(&self, registration: u32) -> bool {
        self.contract_register
            .get(registration as usize)
            .copied()
            .unwrap_or(false)
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
        evm::transaction_columns(rows, indexes, masks, self.should_checksum)
    }

    pub(crate) fn block_columns(
        &self,
        rows: &[Option<RowRef>],
        numbers: &[u64],
        masks: &[u64],
    ) -> Result<Columns> {
        evm::block_columns(rows, numbers, masks, self.should_checksum)
    }
}

pub(crate) struct Tables {
    pub(crate) events: Table,
    pub(crate) transactions: Table,
    pub(crate) blocks: Table,
    pub(crate) decoded: DecodedEvents,
}

#[napi(object)]
pub struct ChainBufferConfig {
    /// `evm`, `svm` or `fuel`.
    pub ecosystem: String,
    pub should_checksum: bool,
    pub evm_registrations: Option<Vec<OnEventRegistrationInput>>,
    pub contract_register_indexes: Vec<i64>,
    pub block_handlers: Vec<BlockHandlerInput>,
    /// By event registration index: the transaction fields each selects.
    pub transaction_masks: Vec<f64>,
    /// By event registration index: the block fields each selects.
    pub event_block_masks: Vec<f64>,
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

fn to_napi(error: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{error:#}"))
}

fn block(number: i64) -> u64 {
    u64::try_from(number).unwrap_or(0)
}

const LAST_BLOCK: u64 = u64::MAX >> POSITION_BITS;

impl ChainBuffer {
    pub(crate) fn tables(&self) -> MutexGuard<'_, Tables> {
        self.tables.lock().unwrap()
    }

    pub(crate) fn shared(&self) -> &Arc<Shared> {
        &self.shared
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
    #[napi(constructor)]
    pub fn new(config: ChainBufferConfig, address_store: &AddressStore) -> napi::Result<Self> {
        let ecosystem = Ecosystem::parse(&config.ecosystem).map_err(to_napi)?;
        let evm = match &config.evm_registrations {
            Some(registrations) => Some(EvmRegistrations {
                matcher: matching::EvmMatcher::new(
                    registrations,
                    &config.contract_register_indexes,
                    address_store,
                )
                .map_err(to_napi)?,
                decoder: decode::evm::EvmDecoder::new(registrations, config.should_checksum)
                    .map_err(to_napi)?,
            }),
            None => None,
        };
        let mut contract_register = Vec::new();
        for index in &config.contract_register_indexes {
            let index = usize::try_from(*index)
                .map_err(|_| napi::Error::from_reason("registration index can't be negative"))?;
            if contract_register.len() <= index {
                contract_register.resize(index + 1, false);
            }
            contract_register[index] = true;
        }
        let [events, transactions, blocks] = ecosystem.schemas();
        Ok(ChainBuffer {
            shared: Arc::new(Shared {
                ecosystem,
                should_checksum: config.should_checksum,
                evm,
                schedule: Schedule::new(&config.block_handlers).map_err(to_napi)?,
                transaction_masks: config.transaction_masks.iter().map(|m| *m as u64).collect(),
                event_block_masks: config.event_block_masks.iter().map(|m| *m as u64).collect(),
                contract_register,
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
    /// events. Returns the event rows removed.
    #[napi]
    pub fn remove_transaction_data_in_block_range(&self, from_block: i64, to_block: i64) -> u32 {
        let (from, to) = (block(from_block), block(to_block).min(LAST_BLOCK));
        let mut tables = self.tables();
        tables.transactions.remove_block_range(from, to);
        (tables.events.remove_block_range(from, to) + tables.decoded.remove_block_range(from, to))
            as u32
    }

    /// Removes block rows of `[from_block, to_block]`, hashes included.
    #[napi]
    pub fn remove_blocks_in_block_range(&self, from_block: i64, to_block: i64) -> u32 {
        let (from, to) = (block(from_block), block(to_block).min(LAST_BLOCK));
        self.tables().blocks.remove_block_range(from, to) as u32
    }

    /// Event rows of blocks `[from_block, to_block]`.
    #[napi]
    pub fn count_rows_in_block_range(&self, from_block: i64, to_block: i64) -> u32 {
        if to_block < from_block {
            return 0;
        }
        let (from, to) = (block(from_block), block(to_block).min(LAST_BLOCK));
        let tables = self.tables();
        (tables.events.count_in_block_range(from, to) + tables.decoded.count_range(from, to)) as u32
    }

    /// Block handler runs on blocks `[from_block, to_block]`.
    #[napi]
    pub fn count_block_handler_runs_in_block_range(&self, from_block: i64, to_block: i64) -> f64 {
        if to_block < from_block {
            return 0.0;
        }
        self.shared
            .schedule
            .count_runs(block(from_block), block(to_block).min(LAST_BLOCK)) as f64
    }

    /// The block of the event row `row_offset` rows past the first one at or
    /// above `from_block`.
    #[napi]
    pub fn get_block_number_of_row_at(&self, from_block: i64, row_offset: u32) -> Option<i64> {
        let from = block(from_block);
        let tables = self.tables();
        if tables.decoded.len() == 0 {
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
        let mut remaining = row_offset;
        loop {
            let next = match (events.peek(), decoded.peek()) {
                (Some(a), Some(b)) if a <= b => events.next(),
                (Some(_), Some(_)) | (None, Some(_)) => decoded.next(),
                (Some(_), None) => events.next(),
                (None, None) => return None,
            };
            if remaining == 0 {
                return next.map(|block| block as i64);
            }
            remaining -= 1;
        }
    }

    /// Every stored event row.
    #[napi]
    pub fn row_count(&self) -> u32 {
        let tables = self.tables();
        (tables.events.len() + tables.decoded.len()) as u32
    }

    /// Memory the tables hold.
    #[napi]
    pub fn heap_bytes(&self) -> f64 {
        let tables = self.tables();
        (tables.events.heap_bytes() + tables.transactions.heap_bytes() + tables.blocks.heap_bytes())
            as f64
    }

    #[napi]
    pub fn get_block_hash(&self, block_number: i64) -> Option<String> {
        let tables = self.tables();
        let ecosystem = self.shared.ecosystem;
        tables
            .blocks
            .find(make_key(u64::try_from(block_number).ok()?, 0), 0)?
            .bytes_at(ecosystem.hash_column())
            .map(|hash| ecosystem.hash_text(hash))
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
        tables
            .blocks
            .rows_in_block_range(0, number)
            .filter_map(|row| ecosystem.block_timestamp(&row))
            .last()
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
