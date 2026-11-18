//! What a source returns: raw rows per table, the blocks among them that
//! hold an event a `contractRegister` runs on, and what validating the
//! response needs.

use std::sync::Mutex;

use napi_derive::napi;

use super::decoded::{DecodedEvent, DecodedEventInput, DecodedEvents};
use super::merge::{first_hash_mismatch, HashMismatch};
use super::table::{block_of_key, Chunk, Table};
use super::Ecosystem;

pub(crate) struct PageData {
    pub(crate) ecosystem: Ecosystem,
    pub(crate) events: Table,
    pub(crate) transactions: Table,
    pub(crate) blocks: Table,
    pub(crate) decoded: DecodedEvents,
    /// Ascending, unique.
    pub(crate) registering_blocks: Vec<u64>,
    /// The lowest block this response reported two hashes for.
    pub(crate) conflict: Option<HashMismatch>,
    /// SVM: half-open ranges the cursor fully processed, where a slot with no
    /// block was skipped by the chain.
    pub(crate) covered: Vec<(u64, u64)>,
}

impl PageData {
    pub(crate) fn new(ecosystem: Ecosystem) -> Self {
        let [events, transactions, blocks] = ecosystem.schemas();
        PageData {
            ecosystem,
            events: Table::new(events),
            transactions: Table::new(transactions),
            blocks: Table::new(blocks),
            decoded: DecodedEvents::default(),
            registering_blocks: Vec::new(),
            conflict: None,
            covered: Vec::new(),
        }
    }

    pub(crate) fn add_events(&mut self, chunk: Chunk) {
        self.events.merge(chunk);
    }

    pub(crate) fn add_transactions(&mut self, chunk: Chunk) {
        self.transactions.merge(chunk);
    }

    /// Adds blocks, recording a block this response now holds two hashes
    /// for.
    pub(crate) fn add_blocks(&mut self, chunk: Chunk) {
        let mut incoming = Table::new((**self.blocks.schema()).clone());
        incoming.merge(chunk);
        self.add_block_table(incoming);
    }

    fn add_block_table(&mut self, incoming: Table) {
        if let Some(conflict) = first_hash_mismatch(&self.blocks, &incoming, 0, self.ecosystem) {
            self.record_conflict(conflict);
        }
        self.blocks.merge_table(&incoming);
    }

    fn record_conflict(&mut self, conflict: HashMismatch) {
        match &self.conflict {
            Some(kept) if kept.block_number <= conflict.block_number => {}
            _ => self.conflict = Some(conflict),
        }
    }

    pub(crate) fn add_registering_blocks(&mut self, blocks: impl IntoIterator<Item = u64>) {
        self.registering_blocks.extend(blocks);
        self.registering_blocks.sort_unstable();
        self.registering_blocks.dedup();
    }

    pub(crate) fn add_covered(&mut self, from: u64, to_exclusive: u64) {
        if from >= to_exclusive {
            return;
        }
        self.covered.push((from, to_exclusive));
        self.covered.sort_unstable();
        let mut merged: Vec<(u64, u64)> = Vec::new();
        for (from, to) in self.covered.drain(..) {
            match merged.last_mut() {
                Some(last) if last.1 >= from => last.1 = last.1.max(to),
                _ => merged.push((from, to)),
            }
        }
        self.covered = merged;
    }

    fn is_covered(&self, block_number: u64) -> bool {
        self.covered
            .iter()
            .any(|(from, to)| *from <= block_number && block_number < *to)
    }

    /// Appends another response's page.
    pub(crate) fn append(&mut self, mut other: PageData) {
        if let Some(conflict) = other.conflict.take() {
            self.record_conflict(conflict);
        }
        self.events.merge_table(&other.events);
        self.transactions.merge_table(&other.transactions);
        let blocks = std::mem::replace(
            &mut other.blocks,
            Table::new((**self.blocks.schema()).clone()),
        );
        self.add_block_table(blocks);
        self.decoded.merge(&other.decoded);
        self.add_registering_blocks(other.registering_blocks);
        for (from, to) in other.covered {
            self.add_covered(from, to);
        }
    }

    pub(crate) fn row_count(&self) -> usize {
        self.events.len() + self.decoded.len()
    }

    pub(crate) fn first_row_block_number(&self) -> Option<u64> {
        let event = self
            .events
            .rows_in_block_range(0, u64::MAX >> super::table::POSITION_BITS)
            .next()
            .map(|row| block_of_key(row.key()));
        [event, self.decoded.first_block()]
            .into_iter()
            .flatten()
            .min()
    }

    pub(crate) fn hash(&self, block_number: u64) -> Option<&[u8]> {
        self.blocks
            .find(super::table::make_key(block_number, 0), 0)
            .and_then(|row| row.bytes_at(self.ecosystem.hash_column()))
    }
}

#[napi]
pub struct Page {
    pub(crate) data: Mutex<PageData>,
}

/// A block a source saw, known by its hash and maybe its time.
#[napi(object)]
pub struct ObservedBlock {
    pub block_number: i64,
    pub block_hash: Option<String>,
    pub block_timestamp: Option<i64>,
}

impl Page {
    pub(crate) fn from_data(data: PageData) -> Self {
        Page {
            data: Mutex::new(data),
        }
    }

    pub(crate) fn take(&self) -> PageData {
        let mut data = self.data.lock().unwrap();
        let ecosystem = data.ecosystem;
        std::mem::replace(&mut *data, PageData::new(ecosystem))
    }
}

fn to_napi(error: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{error:#}"))
}

#[napi]
impl Page {
    #[napi(factory)]
    pub fn empty(ecosystem: String) -> napi::Result<Self> {
        let ecosystem = Ecosystem::parse(&ecosystem).map_err(to_napi)?;
        Ok(Page::from_data(PageData::new(ecosystem)))
    }

    /// A page of blocks JS observed (RPC heads, stored reorg checkpoints) and
    /// of events built in JS (simulate and mock sources).
    #[napi(factory)]
    pub fn from_js(
        ecosystem: String,
        blocks: Vec<ObservedBlock>,
        decoded_events: Option<Vec<DecodedEventInput>>,
    ) -> napi::Result<Self> {
        let ecosystem = Ecosystem::parse(&ecosystem).map_err(to_napi)?;
        let mut data = PageData::new(ecosystem);
        // One block at a time, so two observations of one block with two
        // hashes read as the response's own conflict.
        for block in &blocks {
            let number = u64::try_from(block.block_number)
                .map_err(|_| napi::Error::from_reason("block number can't be negative"))?;
            let hash = block
                .block_hash
                .as_deref()
                .map(|hash| ecosystem.parse_hash(hash))
                .transpose()
                .map_err(to_napi)?;
            let mut builder = data.blocks.builder();
            ecosystem.push_observed_block(
                &mut builder,
                number,
                hash.as_deref(),
                block.block_timestamp.map(|time| time as u64),
            );
            data.add_blocks(builder.finish());
        }
        for input in decoded_events.unwrap_or_default() {
            data.decoded
                .insert(DecodedEvent::from_input(input).map_err(to_napi)?);
        }
        Ok(Page::from_data(data))
    }

    /// A page of simulated SVM transactions, their account activity and
    /// slots, which simulated instructions read from the buffer as fetched
    /// ones do.
    #[napi(factory)]
    pub fn from_svm_js(
        transactions: Vec<crate::chain_buffer::svm::SvmTxInput>,
        activities: Vec<crate::chain_buffer::svm::SvmActivityInput>,
        blocks: Vec<ObservedBlock>,
    ) -> napi::Result<Self> {
        let page = Page::from_js("svm".to_string(), blocks, None)?;
        {
            let mut data = page.data.lock().unwrap();
            let mut rows = data.transactions.builder();
            crate::chain_buffer::svm::push_simulated_transactions(&mut rows, transactions, activities)
                .map_err(to_napi)?;
            data.add_transactions(rows.finish());
        }
        Ok(page)
    }

    /// Event rows: the logs, instructions or receipts the page keeps, and its
    /// decoded events.
    #[napi]
    pub fn row_count(&self) -> u32 {
        self.data.lock().unwrap().row_count() as u32
    }

    #[napi]
    pub fn first_row_block_number(&self) -> Option<i64> {
        self.data
            .lock()
            .unwrap()
            .first_row_block_number()
            .map(|block| block as i64)
    }

    /// Moves another page's rows into this one.
    #[napi]
    pub fn append(&self, other: &Page) {
        if std::ptr::eq(self, other) {
            return;
        }
        let other = other.take();
        self.data.lock().unwrap().append(other);
    }

    /// A block this response reported two hashes for. Such a response is
    /// retried rather than taken for a reorg.
    #[napi]
    pub fn response_conflict(&self) -> Option<HashMismatch> {
        self.data.lock().unwrap().conflict.clone()
    }

    /// The requested blocks this response holds no hash for. On SVM a slot
    /// the cursor covered without a block was skipped, and counts as held.
    #[napi]
    pub fn missing_hashes(&self, block_numbers: Vec<i64>) -> Vec<i64> {
        let data = self.data.lock().unwrap();
        block_numbers
            .into_iter()
            .filter(|number| {
                let Ok(block) = u64::try_from(*number) else {
                    return true;
                };
                data.hash(block).is_none()
                    && !(data.ecosystem == Ecosystem::Svm && data.is_covered(block))
            })
            .collect()
    }
}
