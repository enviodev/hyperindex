//! Events that arrive already decoded, from the simulate and mock sources:
//! their key, registration and record, read by the walk in order with every
//! other row.

use std::collections::BTreeMap;

use napi_derive::napi;

use crate::js_value::JsTape;

/// An item built in JS, its registration replaced by the registration's
/// index.
#[napi(object)]
pub struct DecodedEventInput {
    /// 0 for an event, 1 for a block handler's item.
    pub kind: i32,
    pub block_number: i64,
    pub log_index: i64,
    pub order_path: Option<Vec<i64>>,
    pub registration_index: i64,
    pub item: JsTape,
    /// The key of the item's transaction in the buffer, when the item doesn't
    /// carry the transaction itself.
    pub transaction_index: Option<i64>,
    /// The index of the transaction the item carries itself, which places it
    /// among the block's transactions.
    pub inline_transaction_index: Option<i64>,
    /// Whether the item's block comes from the buffer.
    pub block_from_store: bool,
}

#[derive(Clone)]
pub(crate) struct DecodedEvent {
    pub(crate) block_number: u64,
    pub(crate) is_block: bool,
    pub(crate) log_index: u64,
    pub(crate) order_path: Vec<i64>,
    pub(crate) registration: u32,
    pub(crate) tape: JsTape,
    pub(crate) transaction_index: Option<u32>,
    pub(crate) inline_transaction_index: Option<u32>,
    pub(crate) block_from_store: bool,
}

type Key = (u64, bool, u64, Vec<i64>, u32);

impl DecodedEvent {
    pub(crate) fn from_input(input: DecodedEventInput) -> anyhow::Result<Self> {
        anyhow::ensure!(
            input.block_number >= 0 && input.log_index >= 0 && input.registration_index >= 0,
            "an item's block number, log index and registration can't be negative, got {}, {} and {}",
            input.block_number,
            input.log_index,
            input.registration_index
        );
        let is_block = match input.kind {
            0 => false,
            1 => true,
            other => anyhow::bail!("unknown item kind {other}"),
        };
        Ok(DecodedEvent {
            block_number: input.block_number as u64,
            is_block,
            log_index: input.log_index as u64,
            order_path: input.order_path.unwrap_or_default(),
            registration: input.registration_index as u32,
            tape: input.item,
            transaction_index: input.transaction_index.map(|index| index as u32),
            inline_transaction_index: input.inline_transaction_index.map(|index| index as u32),
            block_from_store: input.block_from_store,
        })
    }

    /// The transaction whose handlers run ahead of this item.
    pub(crate) fn place_among_transactions(&self) -> Option<u32> {
        self.transaction_index.or(self.inline_transaction_index)
    }

    fn key(&self) -> Key {
        (
            self.block_number,
            self.is_block,
            self.log_index,
            self.order_path.clone(),
            self.registration,
        )
    }
}

/// Decoded events in processing order, one per key: the first one stored
/// stays.
#[derive(Default, Clone)]
pub(crate) struct DecodedEvents {
    events: BTreeMap<Key, DecodedEvent>,
}

impl DecodedEvents {
    pub(crate) fn len(&self) -> usize {
        self.events.len()
    }

    pub(crate) fn insert(&mut self, event: DecodedEvent) -> bool {
        let key = event.key();
        if self.events.contains_key(&key) {
            return false;
        }
        self.events.insert(key, event);
        true
    }

    pub(crate) fn merge(&mut self, other: &DecodedEvents) -> usize {
        other
            .events
            .values()
            .filter(|event| self.insert((*event).clone()))
            .count()
    }

    fn range(&self, from_block: u64, to_block: u64) -> impl Iterator<Item = &DecodedEvent> {
        self.events
            .range((from_block, false, 0, Vec::new(), 0)..)
            .take_while(move |(key, _)| key.0 <= to_block)
            .map(|(_, event)| event)
    }

    pub(crate) fn copy_range(&self, from_block: u64, to_block: u64) -> Vec<DecodedEvent> {
        self.range(from_block, to_block).cloned().collect()
    }

    pub(crate) fn count_range(&self, from_block: u64, to_block: u64) -> usize {
        self.range(from_block, to_block).count()
    }

    /// Blocks holding an event of a registration `registers` accepts.
    pub(crate) fn registering_blocks(&self, registers: impl Fn(u32) -> bool) -> Vec<u64> {
        let mut blocks: Vec<u64> = self
            .events
            .values()
            .filter(|event| !event.is_block && registers(event.registration))
            .map(|event| event.block_number)
            .collect();
        blocks.dedup();
        blocks
    }

    pub(crate) fn remove_block_range(&mut self, from_block: u64, to_block: u64) -> usize {
        let before = self.events.len();
        self.events
            .retain(|key, _| key.0 < from_block || key.0 > to_block);
        before - self.events.len()
    }

    pub(crate) fn first_block(&self) -> Option<u64> {
        self.events.keys().next().map(|key| key.0)
    }
}
