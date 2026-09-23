//! A chain's fetched-but-unprocessed items, kept in processing order.
//!
//! The items themselves are JS objects and stay in JS: each one sits at a slot
//! of a JS array the ReScript side owns, and this buffer holds only the item's
//! ordering key and slot. Every hot operation on a buffer of ~100k items (a
//! response merged in, the ready frontier searched, a batch taken off the front,
//! a rollback cut) then runs over plain structs instead of JS property reads,
//! and never rebuilds the JS array.

use std::cmp::Ordering;
use std::collections::VecDeque;

use napi::bindgen_prelude::{Int32Array, Uint32Array, Uint8Array};
use napi_derive::napi;

/// Width of one item's record in the flat key array `insert` takes:
/// `[blockNumber, kind, logIndex, registrationIndex, orderPathLength]`.
const KEY_WIDTH: usize = 5;

/// `orderPathLength` of an item with no order path.
const NO_ORDER_PATH: i32 = -1;

const EVENT_KIND: u8 = 0;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Key {
    block: i32,
    kind: u8,
    // Zero on a block item: it has no log index, and the comparison reads it
    // only once the kinds match.
    log_index: i32,
    order_path: Option<Box<[i32]>>,
    registration_index: i32,
}

impl Key {
    /// Block, then item kind, then the ecosystem's within-block order, then
    /// registration index. Kind outranks the log index so that every event of a
    /// block precedes that block's handlers by construction, whatever an
    /// ecosystem's log index grows to. `Equal` is a true duplicate: the same log
    /// routed to the same registration.
    fn cmp(&self, other: &Self) -> Ordering {
        self.block
            .cmp(&other.block)
            .then(self.kind.cmp(&other.kind))
            .then(self.log_index.cmp(&other.log_index))
            .then_with(|| self.cmp_order_path(other))
            .then(self.registration_index.cmp(&other.registration_index))
    }

    // Two instructions of one Solana transaction, ordered by their position in
    // its CPI tree: lexicographic, parent before child. Items without a path
    // leave the order to the registration index.
    fn cmp_order_path(&self, other: &Self) -> Ordering {
        match (&self.order_path, &other.order_path) {
            (Some(a), Some(b)) => a.cmp(b),
            _ => Ordering::Equal,
        }
    }

    /// Whether two items came from one log routed to two registrations:
    /// everything the order compares except the registration index is equal.
    fn is_same_log(&self, other: &Self) -> bool {
        self.kind == EVENT_KIND
            && other.kind == EVENT_KIND
            && self.block == other.block
            && self.log_index == other.log_index
            && self.cmp_order_path(other) == Ordering::Equal
    }
}

#[derive(Debug)]
struct Entry {
    key: Key,
    slot: u32,
}

#[derive(Debug, Default)]
struct Buffer {
    entries: VecDeque<Entry>,
    free_slots: Vec<u32>,
    next_slot: u32,
}

impl Buffer {
    fn allocate_slot(&mut self) -> u32 {
        self.free_slots.pop().unwrap_or_else(|| {
            let slot = self.next_slot;
            self.next_slot += 1;
            slot
        })
    }

    /// Merges `keys` in, in any order, dropping every key equal to one already
    /// buffered or to an earlier one of the same call. Returns each key's slot,
    /// in the order given, or `None` for a dropped duplicate.
    ///
    /// Only the buffered entries at or above the lowest new key are touched: a
    /// response lands at the top of the buffer almost always, so the common case
    /// is an append.
    fn insert(&mut self, keys: Vec<Key>) -> Vec<Option<u32>> {
        let mut slots = vec![None; keys.len()];
        let mut incoming: Vec<(usize, Key)> = keys.into_iter().enumerate().collect();
        // Stable, so equal keys keep their given order and the first is kept.
        incoming.sort_by(|(_, a), (_, b)| a.cmp(b));
        let Some((_, lowest)) = incoming.first() else {
            return slots;
        };

        // A buffered key equal to an incoming one sorts first and wins, so the
        // split keeps equal keys below it.
        let split = self
            .entries
            .partition_point(|entry| entry.key.cmp(lowest) != Ordering::Greater);
        let mut tail = self.entries.split_off(split).into_iter().peekable();
        let mut incoming = incoming.into_iter().peekable();

        loop {
            let take_tail = match (tail.peek(), incoming.peek()) {
                (Some(entry), Some((_, key))) => entry.key.cmp(key) != Ordering::Greater,
                (Some(_), None) => true,
                (None, Some(_)) => false,
                (None, None) => break,
            };
            if take_tail {
                // Buffered entries are deduplicated among themselves and against
                // everything merged before them, so they are always kept.
                let entry = tail.next().expect("peeked");
                self.entries.push_back(entry);
            } else {
                let (idx, key) = incoming.next().expect("peeked");
                let is_duplicate = self
                    .entries
                    .back()
                    .is_some_and(|last| last.key.cmp(&key) == Ordering::Equal);
                if !is_duplicate {
                    let slot = self.allocate_slot();
                    self.entries.push_back(Entry { key, slot });
                    slots[idx] = Some(slot);
                }
            }
        }
        slots
    }

    fn block_at(&self, index: usize) -> Option<i32> {
        self.entries.get(index).map(|entry| entry.key.block)
    }

    /// Items at or below `frontier`, which are the ones ready to process: the
    /// buffer is sorted, so they are a prefix.
    fn ready_count(&self, frontier: i32) -> usize {
        self.entries
            .partition_point(|entry| entry.key.block <= frontier)
    }

    /// Ready items from `from` on, at least `target` of them when that many are
    /// ready, extended to the end of the block the `target`-th one sits in: a
    /// batch never splits a block.
    fn ready_items_count(&self, target: usize, from: usize, frontier: i32) -> usize {
        let ready = self.ready_count(frontier);
        if from >= ready {
            return 0;
        }
        let available = ready - from;
        if target == 0 || available <= target {
            return available;
        }
        let last_block = self.entries[from + target - 1].key.block;
        let block_end = self
            .entries
            .range(from + target..ready)
            .take_while(|entry| entry.key.block == last_block)
            .count();
        target + block_end
    }

    fn slots(&self, count: usize) -> impl Iterator<Item = u32> + '_ {
        self.entries.iter().take(count).map(|entry| entry.slot)
    }

    /// Whether each of the first `count` items is the first of its log. The
    /// first item always is: a batch counts events from where it starts.
    fn new_event_flags(&self, count: usize) -> Vec<u8> {
        let mut prev: Option<&Key> = None;
        self.entries
            .iter()
            .take(count)
            .map(|entry| {
                let is_new = !prev.is_some_and(|prev| prev.is_same_log(&entry.key));
                prev = Some(&entry.key);
                u8::from(is_new)
            })
            .collect()
    }

    fn release(&mut self, removed: impl IntoIterator<Item = Entry>) -> Vec<u32> {
        let slots: Vec<u32> = removed.into_iter().map(|entry| entry.slot).collect();
        self.free_slots.extend_from_slice(&slots);
        slots
    }

    fn consume(&mut self, count: usize) -> Vec<u32> {
        let count = count.min(self.entries.len());
        let removed: Vec<Entry> = self.entries.drain(..count).collect();
        self.release(removed)
    }

    fn truncate_above(&mut self, block: i32) -> Vec<u32> {
        let keep = self.ready_count(block);
        let removed = self.entries.split_off(keep);
        self.release(removed)
    }
}

/// Decodes `insert`'s flat key records. `order_paths` holds every present
/// path back to back, in item order.
fn decode_keys(keys: &[i32], order_paths: &[i32]) -> napi::Result<Vec<Key>> {
    if !keys.len().is_multiple_of(KEY_WIDTH) {
        return Err(napi::Error::from_reason(format!(
            "Item keys must come in records of {KEY_WIDTH}, got {} values",
            keys.len()
        )));
    }
    let mut path_offset = 0;
    keys.chunks_exact(KEY_WIDTH)
        .map(|record| {
            let [block, kind, log_index, registration_index, path_len] = record else {
                unreachable!("chunks_exact yields KEY_WIDTH values");
            };
            let kind = u8::try_from(*kind)
                .map_err(|_| napi::Error::from_reason(format!("Invalid item kind {kind}")))?;
            let order_path = if *path_len == NO_ORDER_PATH {
                None
            } else {
                let len = usize::try_from(*path_len).map_err(|_| {
                    napi::Error::from_reason(format!("Invalid order path length {path_len}"))
                })?;
                let path = order_paths
                    .get(path_offset..path_offset + len)
                    .ok_or_else(|| {
                        napi::Error::from_reason("Order paths are shorter than their lengths")
                    })?;
                path_offset += len;
                Some(path.into())
            };
            Ok(Key {
                block: *block,
                kind,
                log_index: *log_index,
                order_path,
                registration_index: *registration_index,
            })
        })
        .collect()
}

fn to_usize(value: u32) -> usize {
    usize::try_from(value).expect("u32 fits in usize")
}

#[napi]
pub struct ItemBuffer {
    buffer: Buffer,
}

#[napi]
impl ItemBuffer {
    #[napi(factory)]
    pub fn make() -> Self {
        Self {
            buffer: Buffer::default(),
        }
    }

    /// Merges items in by their keys (see `KEY_WIDTH`). Returns, per item in
    /// the order given, the slot to store it at, or -1 for a duplicate that was
    /// dropped.
    #[napi]
    pub fn insert(
        &mut self,
        keys: Int32Array,
        order_paths: Int32Array,
    ) -> napi::Result<Int32Array> {
        let keys = decode_keys(&keys, &order_paths)?;
        let slots = self.buffer.insert(keys);
        Ok(Int32Array::new(
            slots
                .into_iter()
                .map(|slot| slot.map_or(-1, |slot| i32::try_from(slot).expect("slot fits in i32")))
                .collect(),
        ))
    }

    #[napi(getter)]
    pub fn length(&self) -> u32 {
        u32::try_from(self.buffer.entries.len()).expect("buffer length fits in u32")
    }

    #[napi]
    pub fn block_number_at(&self, index: u32) -> Option<i32> {
        self.buffer.block_at(to_usize(index))
    }

    #[napi]
    pub fn ready_count(&self, frontier: i32) -> u32 {
        u32::try_from(self.buffer.ready_count(frontier)).expect("count fits in u32")
    }

    #[napi]
    pub fn ready_items_count(&self, target_size: u32, from_item: u32, frontier: i32) -> u32 {
        let count =
            self.buffer
                .ready_items_count(to_usize(target_size), to_usize(from_item), frontier);
        u32::try_from(count).expect("count fits in u32")
    }

    /// Slots of the first `count` items, in order. Leaves them buffered.
    #[napi]
    pub fn peek_slots(&self, count: u32) -> Uint32Array {
        Uint32Array::new(self.buffer.slots(to_usize(count)).collect())
    }

    /// Per each of the first `count` items, 1 when it is the first item of its
    /// log, so a batch counts a log routed to several registrations once.
    #[napi]
    pub fn new_event_flags(&self, count: u32) -> Uint8Array {
        Uint8Array::new(self.buffer.new_event_flags(to_usize(count)))
    }

    /// Removes the first `count` items. Returns their slots, now free.
    #[napi]
    pub fn consume(&mut self, count: u32) -> Uint32Array {
        Uint32Array::new(self.buffer.consume(to_usize(count)))
    }

    /// Removes every item above `block_number`. Returns their slots, now free.
    #[napi]
    pub fn truncate_above(&mut self, block_number: i32) -> Uint32Array {
        Uint32Array::new(self.buffer.truncate_above(block_number))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(block: i32, log_index: i32) -> Key {
        Key {
            block,
            kind: EVENT_KIND,
            log_index,
            order_path: None,
            registration_index: 0,
        }
    }

    fn with_registration(key: Key, registration_index: i32) -> Key {
        Key {
            registration_index,
            ..key
        }
    }

    fn with_path(key: Key, path: &[i32]) -> Key {
        Key {
            order_path: Some(path.into()),
            ..key
        }
    }

    fn block_item(block: i32, registration_index: i32) -> Key {
        Key {
            block,
            kind: 1,
            log_index: 0,
            order_path: None,
            registration_index,
        }
    }

    fn keys(buffer: &Buffer) -> Vec<Key> {
        buffer
            .entries
            .iter()
            .map(|entry| entry.key.clone())
            .collect()
    }

    #[test]
    fn merges_unsorted_input_into_order_and_drops_duplicates() {
        let mut buffer = Buffer::default();
        buffer.insert(vec![event(1, 0), event(3, 0), event(5, 0)]);

        let slots = buffer.insert(vec![event(4, 0), event(3, 0), event(2, 0), event(4, 0)]);

        assert_eq!(
            (slots, keys(&buffer)),
            (
                vec![Some(4), None, Some(3), None],
                vec![
                    event(1, 0),
                    event(2, 0),
                    event(3, 0),
                    event(4, 0),
                    event(5, 0)
                ],
            )
        );
    }

    #[test]
    fn keeps_one_log_routed_to_two_registrations() {
        let mut buffer = Buffer::default();

        buffer.insert(vec![
            with_registration(event(1, 0), 1),
            with_registration(event(1, 0), 0),
        ]);

        assert_eq!(
            (keys(&buffer), buffer.new_event_flags(2)),
            (
                vec![
                    with_registration(event(1, 0), 0),
                    with_registration(event(1, 0), 1),
                ],
                vec![1, 0],
            )
        );
    }

    #[test]
    fn orders_every_event_of_a_block_before_its_block_items() {
        let mut buffer = Buffer::default();

        buffer.insert(vec![block_item(1, 0), event(1, i32::MAX), event(2, 0)]);

        assert_eq!(
            keys(&buffer),
            vec![event(1, i32::MAX), block_item(1, 0), event(2, 0)]
        );
    }

    #[test]
    fn orders_instructions_of_a_transaction_by_their_call_path() {
        let mut buffer = Buffer::default();
        let outer = with_path(event(1, 0), &[0]);
        let inner = with_path(event(1, 0), &[0, 0]);
        let next_outer = with_path(event(1, 0), &[1]);

        let slots = buffer.insert(vec![
            next_outer.clone(),
            inner.clone(),
            outer.clone(),
            inner.clone(),
        ]);

        assert_eq!(
            (
                slots.iter().filter(|slot| slot.is_none()).count(),
                keys(&buffer),
                buffer.new_event_flags(3)
            ),
            (1, vec![outer, inner, next_outer], vec![1, 1, 1])
        );
    }

    #[test]
    fn counts_ready_items_to_the_end_of_the_target_block() {
        let mut buffer = Buffer::default();
        buffer.insert(vec![
            event(1, 0),
            event(2, 0),
            event(2, 1),
            event(2, 2),
            event(3, 0),
            event(9, 0),
        ]);

        assert_eq!(
            (
                buffer.ready_count(3),
                buffer.ready_items_count(2, 0, 3),
                buffer.ready_items_count(10, 0, 3),
                buffer.ready_items_count(1, 4, 3),
                buffer.ready_items_count(1, 5, 3),
            ),
            (5, 4, 5, 1, 0)
        );
    }

    #[test]
    fn reuses_the_slots_a_batch_and_a_rollback_free() {
        let mut buffer = Buffer::default();
        buffer.insert(vec![event(1, 0), event(2, 0), event(3, 0), event(4, 0)]);

        let consumed = buffer.consume(1);
        let truncated = buffer.truncate_above(2);
        let slots = buffer.insert(vec![event(5, 0), event(6, 0), event(7, 0)]);

        assert_eq!(
            (consumed, truncated, slots, keys(&buffer)),
            (
                vec![0],
                vec![2, 3],
                vec![Some(3), Some(2), Some(0)],
                vec![event(2, 0), event(5, 0), event(6, 0), event(7, 0)],
            )
        );
    }

    #[test]
    fn decodes_keys_with_and_without_order_paths() {
        let keys = decode_keys(&[1, 0, 2, 3, 2, 4, 1, 0, 5, NO_ORDER_PATH], &[7, 8]).unwrap();

        assert_eq!(
            keys,
            vec![
                with_registration(with_path(event(1, 2), &[7, 8]), 3),
                block_item(4, 5),
            ]
        );
    }

    #[test]
    fn rejects_keys_whose_order_paths_are_missing() {
        assert!(decode_keys(&[1, 0, 2, 3, 2], &[7]).is_err());
    }
}
