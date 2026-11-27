//! One forward walk over a range of the buffer: per block, the rows in key
//! order, each row's matching registrations in index order, each transaction's
//! handlers ahead of its events, then the block handlers running on the block.
//! Rows are matched and decoded here, on a worker thread; nothing about a
//! match is stored.

use std::iter::Peekable;

use anyhow::Result;

use super::decoded::DecodedEvent;
use super::deliver::{Columns, EMPTY_LINK};
use super::matching::transactions::TransactionView;
use super::tables::evm::{self, log_column, LogView};
use super::tables::fuel::ReceiptView;
use super::tables::svm::InstructionView;
use super::tables::table::{make_key, RowRef, Snapshot};
use super::{
    decode, matching, Ecosystem, EvmRegistrations, Registrations, Shared, SvmRegistrations,
};
use crate::ecosystems::evm::registration::EvmParams;
use crate::js_value::JsTape;

pub(crate) enum Item {
    EvmLog {
        block_number: u64,
        log_index: u64,
        transaction_index: u32,
        registration: u32,
        src_address: String,
        params: EvmParams,
    },
    Fuel {
        block_number: u64,
        receipt_index: u64,
        registration: u32,
        tx_id: String,
        src_address: String,
        params: JsTape,
    },
    Svm {
        slot: u64,
        transaction_index: u32,
        path: Vec<i64>,
        registration: u32,
        program_id: String,
        accounts: Vec<String>,
        data: Vec<u8>,
        is_inner: bool,
        args: Option<JsTape>,
        logs: Option<JsTape>,
    },
    Block {
        block_number: u64,
        registration: u32,
        skipped: bool,
    },
    Transaction {
        block_number: u64,
        transaction_index: u32,
        registration: u32,
    },
    Decoded {
        block_number: u64,
        log_index: u64,
        registration: u32,
        tape: JsTape,
        transaction_index: Option<u32>,
        block_from_store: bool,
        is_block: bool,
    },
}

/// Where an item's transaction and block are among the built ones: `None`
/// reads none, `EMPTY_LINK` an empty object of its own.
#[derive(Clone, Copy, Default)]
pub(crate) struct ItemLinks {
    pub(crate) transaction: Option<f64>,
    pub(crate) block: Option<f64>,
}

pub(crate) struct Built {
    pub(crate) items: Vec<Item>,
    pub(crate) links: Vec<ItemLinks>,
    pub(crate) transactions: Option<Columns>,
    pub(crate) blocks: Option<Columns>,
    pub(crate) last_block: Option<u64>,
}

/// The buffer as one build reads it.
pub(crate) struct Snapshots {
    pub(crate) events: Snapshot,
    pub(crate) transactions: Snapshot,
    pub(crate) blocks: Snapshot,
    /// Already-decoded events of the range, in order.
    pub(crate) decoded: Vec<DecodedEvent>,
}

pub(crate) enum Range {
    /// Blocks `[from_block, max_block]`, stopping at the first block boundary
    /// at or past the target.
    Handlers { from_block: u64, max_block: u64 },
    /// Exactly these blocks, ascending, and only registrations with a
    /// `contractRegister`.
    ContractRegister { blocks: Vec<u64> },
}

pub(crate) fn build(
    shared: &Shared,
    snapshots: &Snapshots,
    range: Range,
    target_items: usize,
) -> Result<Built> {
    let mut walker = Walker {
        shared,
        snapshots,
        items: Vec::new(),
        decoded_at: 0,
    };
    let last_block = match range {
        Range::Handlers {
            from_block,
            max_block,
        } => walker.walk_range(from_block, max_block, target_items),
        Range::ContractRegister { blocks } => walker.walk_blocks(&blocks, target_items),
    };
    let Walker { items, .. } = walker;
    let (links, transactions, blocks) = join(shared, snapshots, &items)?;
    Ok(Built {
        items,
        links,
        transactions,
        blocks,
        last_block,
    })
}

/// The lowest block among the next row of each stream, the next decoded event
/// and the next block handler run.
fn first_block_to_walk<'r>(
    rows: &mut Peekable<impl Iterator<Item = RowRef<'r>>>,
    transactions: Option<&mut Peekable<impl Iterator<Item = RowRef<'r>>>>,
    decoded: Option<&DecodedEvent>,
    next_block_handler_run: Option<u64>,
) -> Option<u64> {
    [
        rows.peek().map(RowRef::block_number),
        transactions.and_then(|rows| rows.peek().map(RowRef::block_number)),
        decoded.map(|event| event.block_number),
        next_block_handler_run,
    ]
    .into_iter()
    .flatten()
    .min()
}

struct Walker<'a> {
    shared: &'a Shared,
    snapshots: &'a Snapshots,
    items: Vec<Item>,
    /// The first decoded event not walked yet.
    decoded_at: usize,
}

impl Walker<'_> {
    fn walk_range(&mut self, from_block: u64, max_block: u64, target_items: usize) -> Option<u64> {
        if from_block > max_block {
            return None;
        }
        let snapshots = self.snapshots;
        let mut rows = snapshots
            .events
            .rows_in_block_range(from_block, max_block)
            .peekable();
        let mut transactions = (!self.shared.transaction_matcher.is_empty()).then(|| {
            snapshots
                .transactions
                .rows_in_block_range(from_block, max_block)
                .peekable()
        });
        let mut block = from_block;
        loop {
            let next = first_block_to_walk(
                &mut rows,
                transactions.as_mut(),
                snapshots.decoded.get(self.decoded_at),
                self.shared.schedule.first_from(block),
            )
            .filter(|next| *next <= max_block);
            let Some(next) = next else {
                return Some(max_block);
            };
            let mut block_rows = Vec::new();
            while let Some(row) = rows.next_if(|row| row.block_number() == next) {
                block_rows.push(row);
            }
            let mut block_transactions = Vec::new();
            if let Some(transactions) = transactions.as_mut() {
                while let Some(row) = transactions.next_if(|row| row.block_number() == next) {
                    block_transactions.push(row);
                }
            }
            self.walk_block(next, &block_rows, &block_transactions, false);
            if self.items.len() >= target_items {
                // The blocks up to the next one holding anything are done too.
                let following = first_block_to_walk(
                    &mut rows,
                    transactions.as_mut(),
                    snapshots.decoded.get(self.decoded_at),
                    next.checked_add(1)
                        .and_then(|after| self.shared.schedule.first_from(after)),
                );
                return Some(match following {
                    Some(following) if following <= max_block => following - 1,
                    _ => max_block,
                });
            }
            if next == max_block {
                return Some(max_block);
            }
            block = next + 1;
        }
    }

    fn walk_blocks(&mut self, blocks: &[u64], target_items: usize) -> Option<u64> {
        let mut last = None;
        for block in blocks {
            let rows: Vec<RowRef> = self
                .snapshots
                .events
                .rows_in_block_range(*block, *block)
                .collect();
            self.decoded_at = self
                .snapshots
                .decoded
                .partition_point(|event| event.block_number < *block);
            self.walk_block(*block, &rows, &[], true);
            last = Some(*block);
            if self.items.len() >= target_items {
                break;
            }
        }
        last
    }

    /// A transaction's handlers run ahead of the first event, fetched or
    /// decoded, of that transaction or a later one; an event naming no
    /// transaction moves none. The rest run after the block's events.
    fn walk_block(
        &mut self,
        block_number: u64,
        rows: &[RowRef],
        transactions: &[RowRef],
        contract_register_only: bool,
    ) {
        let decoded = &self.snapshots.decoded;
        let decoded_end = self.decoded_at
            + decoded[self.decoded_at..]
                .partition_point(|event| event.block_number <= block_number);
        let block_decoded = &decoded[self.decoded_at..decoded_end];
        self.decoded_at = decoded_end;

        let mut transactions = transactions.iter().peekable();
        let mut decoded_events = block_decoded
            .iter()
            .filter(|event| !event.is_block)
            .peekable();
        for row in rows {
            while let Some(event) = decoded_events.next_if(|event| event.log_index < row.position())
            {
                self.push_transactions_through(&mut transactions, event.transaction_index);
                self.push_decoded(event, contract_register_only);
            }
            if transactions.peek().is_some() {
                let index = row.u64_at(log_column::TRANSACTION_INDEX).map(|i| i as u32);
                self.push_transactions_through(&mut transactions, index);
            }
            self.push_row(row, contract_register_only);
        }
        for event in decoded_events {
            self.push_transactions_through(&mut transactions, event.transaction_index);
            self.push_decoded(event, contract_register_only);
        }
        self.push_transactions_through(&mut transactions, Some(u32::MAX));
        if contract_register_only {
            return;
        }
        for event in block_decoded.iter().filter(|event| event.is_block) {
            self.push_decoded(event, false);
        }
        // A slot the chain skipped has no block: a handler that fetched its
        // slots finds none there and runs without one.
        let has_block = || {
            self.snapshots
                .blocks
                .find(make_key(block_number, 0), 0)
                .is_some()
        };
        for handler in self.shared.schedule.handlers_on(block_number) {
            // A simulated block item stands in for the scheduled one, carrying
            // the block the test gave it.
            if block_decoded
                .iter()
                .any(|event| event.is_block && event.registration == handler.index)
            {
                continue;
            }
            let skipped = self.shared.ecosystem == Ecosystem::Svm
                && handler.block_field_mask.is_some()
                && !has_block();
            self.items.push(Item::Block {
                block_number,
                registration: handler.index,
                skipped,
            });
        }
    }

    fn push_transactions_through<'r>(
        &mut self,
        transactions: &mut Peekable<impl Iterator<Item = &'r RowRef<'r>>>,
        transaction_index: Option<u32>,
    ) {
        let Some(through) = transaction_index else {
            return;
        };
        while let Some(row) = transactions.next_if(|row| row.position() <= through as u64) {
            let shared = self.shared;
            let items = &mut self.items;
            shared.transaction_matcher.for_each_match(
                &TransactionView::of_row(row),
                |registration| {
                    items.push(Item::Transaction {
                        block_number: row.block_number(),
                        transaction_index: row.position() as u32,
                        registration: registration.index,
                    })
                },
            );
        }
    }

    fn push_decoded(&mut self, event: &DecodedEvent, contract_register_only: bool) {
        if contract_register_only && !self.shared.has_contract_register(event.registration) {
            return;
        }
        self.items.push(Item::Decoded {
            block_number: event.block_number,
            log_index: event.log_index,
            registration: event.registration,
            tape: event.tape.clone(),
            transaction_index: event.transaction_index,
            block_from_store: event.block_from_store,
            is_block: event.is_block,
        });
    }

    fn push_row(&mut self, row: &RowRef, contract_register_only: bool) {
        let shared = self.shared;
        match &shared.registrations {
            Registrations::Evm(evm) => self.push_log(evm, row, contract_register_only),
            Registrations::Svm(svm) => self.push_instruction(svm, row, contract_register_only),
            Registrations::Fuel(fuel) => {
                self.push_receipt(&fuel.matcher, row, contract_register_only)
            }
        }
    }

    fn push_instruction(
        &mut self,
        svm: &SvmRegistrations,
        row: &RowRef,
        contract_register_only: bool,
    ) {
        let Some(call) = InstructionView::of_row(row) else {
            return;
        };
        let store = svm.matcher.read_store();
        let matched = svm.matcher.matches(&call, &store);
        decode::svm::instruction_items(
            &call,
            &matched,
            |registration| {
                !contract_register_only
                    || self.shared.has_contract_register(registration.index as u32)
            },
            &mut self.items,
        );
    }

    fn push_receipt(
        &mut self,
        fuel: &matching::fuel::FuelMatcher,
        row: &RowRef,
        contract_register_only: bool,
    ) {
        let Some(receipt) = ReceiptView::of_row(row) else {
            return;
        };
        let store = fuel.read_store();
        let mut identity = None;
        fuel.for_each_match(&receipt, &store, |registration| {
            if contract_register_only && !self.shared.has_contract_register(registration.index()) {
                return;
            }
            let Some(params) = decode::fuel::params(&registration.registration.kind, &receipt)
            else {
                return;
            };
            let (tx_id, src_address) = identity
                .get_or_insert_with(|| (receipt.tx_id(), receipt.src_address()))
                .clone();
            self.items.push(Item::Fuel {
                block_number: receipt.block_height,
                receipt_index: receipt.receipt_index,
                registration: registration.index(),
                tx_id,
                src_address,
                params,
            });
        });
    }

    fn push_log(&mut self, evm: &EvmRegistrations, row: &RowRef, contract_register_only: bool) {
        let Some(log) = LogView::of_row(row) else {
            return;
        };
        let data = row.bytes_at(log_column::DATA).unwrap_or(&[]);
        let transaction_index = row.u64_at(log_column::TRANSACTION_INDEX).unwrap_or(0) as u32;
        let store = evm.matcher.read_store();
        let mut src_address = None;
        evm.matcher.for_each_match(&log, &store, |registration| {
            if contract_register_only && !self.shared.has_contract_register(registration.index) {
                return;
            }
            let Some(params) = evm.decoder.decode(registration.index, &log.topics, data) else {
                return;
            };
            let src_address = src_address
                .get_or_insert_with(|| evm::address_text(log.address, self.shared.should_checksum))
                .clone();
            self.items.push(Item::EvmLog {
                block_number: log.block_number,
                log_index: row.position(),
                transaction_index,
                registration: registration.index,
                src_address,
                params,
            });
        });
    }
}

type Joined = (Vec<ItemLinks>, Option<Columns>, Option<Columns>);

/// Each item's transaction and block, and those rows' selected fields. Items
/// of one transaction or block share its row, selecting the union of their
/// fields; items are in order, so they are consecutive.
fn join(shared: &Shared, snapshots: &Snapshots, items: &[Item]) -> Result<Joined> {
    let mut links = vec![ItemLinks::default(); items.len()];
    let mut transaction_keys: Vec<(u64, u32)> = Vec::new();
    let mut transaction_masks: Vec<u64> = Vec::new();
    let mut block_numbers: Vec<u64> = Vec::new();
    let mut block_masks: Vec<u64> = Vec::new();
    for (link, item) in links.iter_mut().zip(items) {
        let (transaction, block) = shared.reads(item);
        if let Some((key, mask)) = transaction {
            if transaction_keys.last() == Some(&key) {
                *transaction_masks.last_mut().unwrap() |= mask;
            } else {
                transaction_keys.push(key);
                transaction_masks.push(mask);
            }
            link.transaction = Some((transaction_keys.len() - 1) as f64);
        }
        if let Some((number, mask)) = block {
            if block_numbers.last() == Some(&number) {
                *block_masks.last_mut().unwrap() |= mask;
            } else {
                block_numbers.push(number);
                block_masks.push(mask);
            }
            link.block = Some((block_numbers.len() - 1) as f64);
        }
    }
    let transactions = if transaction_masks.iter().any(|mask| *mask != 0) {
        let rows: Vec<Option<RowRef>> = transaction_keys
            .iter()
            .map(|(block, index)| {
                snapshots
                    .transactions
                    .find(make_key(*block, *index as u64), 0)
            })
            .collect();
        let indexes: Vec<u32> = transaction_keys.iter().map(|(_, index)| *index).collect();
        Some(shared.transaction_columns(&rows, &indexes, &transaction_masks)?)
    } else {
        for link in &mut links {
            if link.transaction.is_some() {
                link.transaction = Some(EMPTY_LINK);
            }
        }
        None
    };
    let blocks = if block_masks.iter().any(|mask| *mask != 0) {
        let rows: Vec<Option<RowRef>> = block_numbers
            .iter()
            .map(|number| snapshots.blocks.find(make_key(*number, 0), 0))
            .collect();
        Some(shared.block_columns(&rows, &block_numbers, &block_masks)?)
    } else {
        for link in &mut links {
            if link.block.is_some() {
                link.block = Some(EMPTY_LINK);
            }
        }
        None
    };
    Ok((links, transactions, blocks))
}

impl Shared {
    /// The transaction key and block number an item reads, each with the
    /// fields it selects.
    #[allow(clippy::type_complexity)]
    fn reads(&self, item: &Item) -> (Option<((u64, u32), u64)>, Option<(u64, u64)>) {
        match item {
            Item::EvmLog {
                block_number,
                transaction_index,
                registration,
                ..
            } => (
                Some((
                    (*block_number, *transaction_index),
                    self.transaction_mask(*registration),
                )),
                Some((*block_number, self.event_block_mask(*registration))),
            ),
            Item::Svm {
                slot,
                transaction_index,
                registration,
                ..
            } => (
                Some((
                    (*slot, *transaction_index),
                    self.transaction_mask(*registration),
                )),
                Some((*slot, self.event_block_mask(*registration))),
            ),
            Item::Fuel {
                block_number,
                registration,
                ..
            } => (
                None,
                Some((*block_number, self.event_block_mask(*registration))),
            ),
            Item::Transaction {
                block_number,
                transaction_index,
                registration,
            } => {
                let (transaction_mask, block_mask) = self.on_transaction_masks(*registration);
                (
                    Some(((*block_number, *transaction_index), transaction_mask)),
                    Some((*block_number, block_mask)),
                )
            }
            Item::Block {
                block_number,
                registration,
                skipped,
            } => (
                None,
                if *skipped {
                    None
                } else {
                    self.block_handler_mask(*registration)
                        .map(|mask| (*block_number, mask))
                },
            ),
            Item::Decoded {
                block_number,
                registration,
                transaction_index,
                block_from_store,
                is_block,
                ..
            } => (
                transaction_index
                    .map(|index| ((*block_number, index), self.transaction_mask(*registration))),
                block_from_store.then(|| {
                    let mask = if *is_block {
                        self.block_handler_mask(*registration).unwrap_or(0)
                    } else {
                        self.event_block_mask(*registration)
                    };
                    (*block_number, mask)
                }),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use hypersync_client::format::{Address, Hex};
    use hypersync_client::simple_types::Transaction;

    use super::*;
    use crate::address_store::test_support::evm_store;
    use crate::chain_buffer::matching::transactions::OnTransactionRegistrationInput;
    use crate::chain_buffer::page::{Page, PageData};
    use crate::chain_buffer::tables::evm::push_transaction;
    use crate::chain_buffer::{ChainBuffer, ChainBufferConfig, RegistrationsInput};
    use crate::ecosystems::evm::fields::EvmTxField;

    const SENDER: &str = "0x00000000000000000000000000000000000000aa";

    fn registration(index: i64, from: Option<&str>) -> OnTransactionRegistrationInput {
        OnTransactionRegistrationInput {
            index,
            from: from.map(|from| vec![from.to_string()]),
            to: None,
            status: None,
            transaction_field_mask: 0.0,
            block_field_mask: 0.0,
        }
    }

    fn transaction(block_number: u64, index: u64, from: Option<&str>) -> Transaction {
        Transaction {
            block_number: Some(block_number.into()),
            transaction_index: Some(index.into()),
            from: from.map(|from| Address::decode_hex(from).unwrap()),
            ..Default::default()
        }
    }

    fn walked(rows: &[(Transaction, u64)]) -> Vec<(u64, u32, u32)> {
        let store = evm_store(&[]);
        let buffer = ChainBuffer::make(
            ChainBufferConfig {
                registrations: RegistrationsInput::Evm {
                    registrations: vec![],
                },
                should_checksum: false,
                contract_register_indexes: vec![],
                block_handlers: vec![],
                transaction_masks: vec![],
                event_block_masks: vec![],
                transaction_registrations: vec![
                    registration(0, Some(SENDER)),
                    registration(1, None),
                ],
            },
            &store,
        )
        .unwrap();
        let mut page = PageData::new(Ecosystem::Evm);
        let mut builder = page.transactions.builder();
        for (row, fetched) in rows {
            push_transaction(&mut builder, row, *fetched).unwrap();
        }
        page.add_transactions(builder.finish());
        buffer.merge_page(&Page::from_data(page), 0, false);
        buffer
            .build_items_for_test(0, 100)
            .into_iter()
            .map(|item| match item {
                Item::Transaction {
                    block_number,
                    transaction_index,
                    registration,
                } => (block_number, transaction_index, registration),
                _ => panic!("only transaction items were stored"),
            })
            .collect()
    }

    #[test]
    fn transactions_run_their_handlers_in_order_and_a_row_without_the_filters_field_runs_none_of_its(
    ) {
        let from_bit = 1 << EvmTxField::From as u64;
        assert_eq!(
            walked(&[
                (transaction(7, 2, Some(SENDER)), from_bit),
                (transaction(7, 0, None), from_bit),
                (transaction(9, 1, Some(SENDER)), 0),
            ]),
            vec![(7, 0, 1), (7, 2, 0), (7, 2, 1), (9, 1, 1)]
        );
    }
}
