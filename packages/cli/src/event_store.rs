//! Per-chain store of fetched items, kept sorted in processing order until a
//! batch takes them. A row holds the item's sort key and the source's own item
//! object as a `JsTape`, so an item becomes a JS object only when a batch or a
//! contract register reads it. Sources return one store per response (a page),
//! merged into the chain's store once the response is applied.

use std::cmp::Ordering;
use std::sync::Mutex;

use napi_derive::napi;

use crate::js_value::JsTape;

/// Which JS conversion a row's data goes through, chosen by what produced it.
#[napi]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RowFormat {
    /// An EVM log routed by HyperSync or RPC.
    EvmLog = 0,
    FuelReceipt = 1,
    SvmInstruction = 2,
    /// A block handler's item, fetched or generated: `{blockNumber,
    /// onBlockRegistrationIndex, skipped}`.
    Block = 3,
    /// An item built in JS (simulate input), stored without its registration.
    JsItem = 4,
}

/// Events of a block run before its block handlers, whatever an ecosystem's
/// within-block key grows to.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(crate) enum ItemKind {
    Event = 0,
    Block = 1,
}

#[derive(Clone)]
pub(crate) struct Row {
    block_number: i64,
    kind: ItemKind,
    /// The ecosystem's within-block order: log index (EVM), receipt index
    /// (Fuel), transaction index (SVM). Zero for block items.
    log_index: i64,
    /// SVM's position in the transaction's CPI tree, parent before child.
    order_path: Option<Vec<i64>>,
    registration_index: i64,
    format: RowFormat,
    data: JsTape,
}

impl Row {
    pub(crate) fn event(
        block_number: i64,
        log_index: i64,
        order_path: Option<Vec<i64>>,
        registration_index: i64,
        format: RowFormat,
        data: JsTape,
    ) -> Self {
        Row {
            block_number,
            kind: ItemKind::Event,
            log_index,
            order_path,
            registration_index,
            format,
            data,
        }
    }

    pub(crate) fn block(block_number: i64, registration_index: i64, skipped: bool) -> Self {
        let mut data = JsTape::new();
        data.obj(3);
        data.key("blockNumber");
        data.num(block_number as f64);
        data.key("onBlockRegistrationIndex");
        data.num(registration_index as f64);
        data.key("skipped");
        data.bool(skipped);
        Row {
            block_number,
            kind: ItemKind::Block,
            log_index: 0,
            order_path: None,
            registration_index,
            format: RowFormat::Block,
            data,
        }
    }

    /// Total order on rows. `Equal` means a true duplicate: the same log routed
    /// to the same registration, which an overlapping re-fetch delivers again.
    fn compare(&self, other: &Row) -> Ordering {
        self.block_number
            .cmp(&other.block_number)
            .then(self.kind.cmp(&other.kind))
            .then(self.log_index.cmp(&other.log_index))
            .then_with(|| match (&self.order_path, &other.order_path) {
                // Lexicographic, so a parent instruction `[1]` precedes its
                // child `[1, 0]`.
                (Some(a), Some(b)) => a.cmp(b),
                _ => Ordering::Equal,
            })
            .then(self.registration_index.cmp(&other.registration_index))
    }
}

/// Merges `incoming` into the sorted, deduplicated `rows`. On a tie the row
/// already stored is kept.
fn merge_rows(rows: Vec<Row>, mut incoming: Vec<Row>) -> Vec<Row> {
    // Stable, so of two equal incoming rows the first is the one kept.
    incoming.sort_by(Row::compare);
    let mut merged: Vec<Row> = Vec::with_capacity(rows.len() + incoming.len());
    let mut push = |row: Row| {
        if merged
            .last()
            .is_none_or(|last| last.compare(&row) != Ordering::Equal)
        {
            merged.push(row);
        }
    };
    let mut stored = rows.into_iter().peekable();
    let mut incoming = incoming.into_iter().peekable();
    loop {
        match (stored.peek(), incoming.peek()) {
            (Some(a), Some(b)) => {
                if a.compare(b) != Ordering::Greater {
                    push(stored.next().unwrap());
                } else {
                    push(incoming.next().unwrap());
                }
            }
            (Some(_), None) => push(stored.next().unwrap()),
            (None, Some(_)) => push(incoming.next().unwrap()),
            (None, None) => break,
        }
    }
    merged
}

/// A row on its way to JS: the conversion to run and the object to run it on.
#[napi(object, object_from_js = false)]
pub struct StoredItem {
    pub format: RowFormat,
    pub registration_index: i64,
    pub data: JsTape,
}

impl From<Row> for StoredItem {
    fn from(row: Row) -> Self {
        StoredItem {
            format: row.format,
            registration_index: row.registration_index,
            data: row.data,
        }
    }
}

/// An item built in JS, its registration replaced by the registration's index.
#[napi(object)]
pub struct JsItemInput {
    /// 0 for an event, 1 for a block handler's item.
    pub kind: i32,
    pub block_number: i64,
    pub log_index: i64,
    pub order_path: Option<Vec<i64>>,
    pub registration_index: i64,
    pub item: JsTape,
}

#[napi]
pub struct EventStore {
    rows: Mutex<Vec<Row>>,
}

impl EventStore {
    pub(crate) fn from_rows(rows: Vec<Row>) -> Self {
        EventStore {
            rows: Mutex::new(merge_rows(Vec::new(), rows)),
        }
    }

    fn rows(&self) -> std::sync::MutexGuard<'_, Vec<Row>> {
        self.rows.lock().unwrap()
    }

    fn insert(&self, incoming: Vec<Row>) {
        let mut rows = self.rows();
        let stored = std::mem::take(&mut *rows);
        *rows = merge_rows(stored, incoming);
    }
}

#[napi]
impl EventStore {
    #[napi(factory)]
    pub fn empty() -> Self {
        EventStore::from_rows(Vec::new())
    }

    #[napi(factory)]
    pub fn from_js_items(items: Vec<JsItemInput>) -> napi::Result<Self> {
        let rows = items
            .into_iter()
            .map(|item| {
                let kind = match item.kind {
                    0 => ItemKind::Event,
                    1 => ItemKind::Block,
                    other => {
                        return Err(napi::Error::from_reason(format!(
                            "unknown item kind {other}"
                        )))
                    }
                };
                Ok(Row {
                    block_number: item.block_number,
                    kind,
                    log_index: item.log_index,
                    order_path: item.order_path,
                    registration_index: item.registration_index,
                    format: RowFormat::JsItem,
                    data: item.item,
                })
            })
            .collect::<napi::Result<Vec<_>>>()?;
        Ok(EventStore::from_rows(rows))
    }

    /// Moves `page`'s rows in, leaving it empty.
    #[napi]
    pub fn merge(&self, page: &EventStore) {
        let incoming = std::mem::take(&mut *page.rows());
        self.insert(incoming);
    }

    /// Block handler items generated locally, one per `(blockNumber,
    /// registrationIndex)` pair.
    #[napi]
    pub fn insert_block_items(&self, block_numbers: Vec<i64>, registration_indexes: Vec<i64>) {
        let rows = block_numbers
            .into_iter()
            .zip(registration_indexes)
            .map(|(block_number, registration_index)| {
                Row::block(block_number, registration_index, false)
            })
            .collect();
        self.insert(rows);
    }

    #[napi]
    pub fn len(&self) -> u32 {
        self.rows().len() as u32
    }

    #[napi]
    pub fn block_number_at(&self, index: u32) -> Option<i64> {
        self.rows().get(index as usize).map(|row| row.block_number)
    }

    #[napi]
    pub fn first_event_block_number(&self) -> Option<i64> {
        self.rows()
            .iter()
            .find(|row| row.kind == ItemKind::Event)
            .map(|row| row.block_number)
    }

    /// How many rows are at or below `block_number`.
    #[napi]
    pub fn count_at_or_below(&self, block_number: i64) -> u32 {
        self.rows()
            .partition_point(|row| row.block_number <= block_number) as u32
    }

    /// How many rows from `from_index` on a batch takes: those at or below
    /// `frontier`, up to `target_size`, and then the rest of the last block, so
    /// a batch never splits a block.
    #[napi]
    pub fn ready_count(&self, frontier: i64, target_size: u32, from_index: u32) -> u32 {
        let rows = self.rows();
        let mut ready_block_number = frontier;
        let mut count = 0u32;
        for row in rows.iter().skip(from_index as usize) {
            if row.block_number > ready_block_number {
                break;
            }
            count += 1;
            if count == target_size {
                ready_block_number = row.block_number;
            }
        }
        count
    }

    /// Removes and returns the first `count` rows.
    #[napi]
    pub fn take(&self, count: u32) -> Vec<StoredItem> {
        let mut rows = self.rows();
        let count = (count as usize).min(rows.len());
        rows.drain(..count).map(StoredItem::from).collect()
    }

    /// Copies of the event rows routed to any of `registration_indexes`, in
    /// order. The rows stay.
    #[napi]
    pub fn events_of_registrations(&self, registration_indexes: Vec<i64>) -> Vec<StoredItem> {
        self.rows()
            .iter()
            .filter(|row| {
                row.kind == ItemKind::Event
                    && registration_indexes.contains(&row.registration_index)
            })
            .cloned()
            .map(StoredItem::from)
            .collect()
    }

    /// Copies of every row, in order. The rows stay.
    #[napi]
    pub fn all_items(&self) -> Vec<StoredItem> {
        self.rows().iter().cloned().map(StoredItem::from).collect()
    }

    /// Drops every row above `target_block_number`.
    #[napi]
    pub fn rollback(&self, target_block_number: i64) {
        self.rows()
            .retain(|row| row.block_number <= target_block_number);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_value::test_value::JsValue;

    fn event(block_number: i64, log_index: i64, registration_index: i64, tag: &str) -> Row {
        let mut data = JsTape::new();
        data.str(tag);
        Row::event(
            block_number,
            log_index,
            None,
            registration_index,
            RowFormat::EvmLog,
            data,
        )
    }

    fn svm(slot: i64, transaction_index: i64, path: &[i64], tag: &str) -> Row {
        let mut data = JsTape::new();
        data.str(tag);
        Row::event(
            slot,
            transaction_index,
            Some(path.to_vec()),
            0,
            RowFormat::SvmInstruction,
            data,
        )
    }

    fn tags(items: Vec<StoredItem>) -> Vec<JsValue> {
        items
            .into_iter()
            .map(|item| JsValue::of(&item.data))
            .collect()
    }

    fn take_all(store: &EventStore) -> Vec<JsValue> {
        tags(store.take(u32::MAX))
    }

    #[test]
    fn orders_by_block_then_events_before_block_items_then_log_and_registration() {
        let store = EventStore::from_rows(vec![
            Row::block(2, 0, false),
            event(2, 5, 1, "b2-l5-r1"),
            event(1, 9, 0, "b1-l9"),
            event(2, 5, 0, "b2-l5-r0"),
            event(2, 1, 0, "b2-l1"),
        ]);
        assert_eq!(
            take_all(&store),
            vec![
                JsValue::str("b1-l9"),
                JsValue::str("b2-l1"),
                JsValue::str("b2-l5-r0"),
                JsValue::str("b2-l5-r1"),
                JsValue::obj([
                    ("blockNumber", JsValue::Num(2.0)),
                    ("onBlockRegistrationIndex", JsValue::Num(0.0)),
                    ("skipped", JsValue::Bool(false)),
                ]),
            ]
        );
    }

    #[test]
    fn orders_svm_instructions_parent_before_child() {
        let store = EventStore::from_rows(vec![
            svm(7, 3, &[1, 0], "child"),
            svm(7, 3, &[2], "sibling"),
            svm(7, 3, &[1], "parent"),
        ]);
        assert_eq!(
            take_all(&store),
            vec![
                JsValue::str("parent"),
                JsValue::str("child"),
                JsValue::str("sibling")
            ]
        );
    }

    #[test]
    fn merge_keeps_the_stored_row_of_a_duplicate_and_empties_the_page() {
        let store = EventStore::from_rows(vec![event(1, 0, 0, "stored"), event(3, 0, 0, "b3")]);
        let page = EventStore::from_rows(vec![event(1, 0, 0, "refetched"), event(2, 0, 0, "b2")]);
        store.merge(&page);
        assert_eq!(
            (page.len(), take_all(&store)),
            (
                0,
                vec![
                    JsValue::str("stored"),
                    JsValue::str("b2"),
                    JsValue::str("b3")
                ]
            )
        );
    }

    #[test]
    fn ready_count_stops_at_the_frontier_and_finishes_the_target_block() {
        let store = EventStore::from_rows(vec![
            event(1, 0, 0, "a"),
            event(2, 0, 0, "b"),
            event(2, 1, 0, "c"),
            event(3, 0, 0, "d"),
            event(5, 0, 0, "e"),
        ]);
        assert_eq!(
            (
                store.ready_count(4, 100, 0),
                store.ready_count(4, 2, 0),
                store.ready_count(4, 1, 1),
                store.count_at_or_below(2),
            ),
            (4, 3, 2, 3)
        );
    }

    #[test]
    fn take_rollback_and_lookups_read_the_sorted_rows() {
        let store = EventStore::from_rows(vec![
            Row::block(1, 0, false),
            event(2, 0, 4, "cr"),
            event(3, 0, 0, "plain"),
            event(4, 0, 4, "dropped by rollback"),
        ]);
        store.rollback(3);
        let contract_registers = tags(store.events_of_registrations(vec![4]));
        let first_event = store.first_event_block_number();
        let second = store.block_number_at(1);
        let taken = store.take(1).len();
        assert_eq!(
            (
                contract_registers,
                first_event,
                second,
                taken,
                take_all(&store)
            ),
            (
                vec![JsValue::str("cr")],
                Some(2),
                Some(2),
                1,
                vec![JsValue::str("cr"), JsValue::str("plain")]
            )
        );
    }
}
