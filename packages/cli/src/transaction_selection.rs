//! Transaction handlers, for every native EVM client: the filters a source
//! asks for their transactions by, and the routing of each transaction that
//! comes back to the handlers it runs.

use std::collections::HashMap;

use anyhow::{Context, Result};
use hypersync_client::format::{FixedSizeData, Hex};
use hypersync_client::simple_types::Transaction;
use napi_derive::napi;

use crate::evm_hypersync_source::query::{BlockField, TransactionField, TransactionFilter};

#[napi(object)]
#[derive(Clone, Debug)]
pub struct OnTransactionRegistrationInput {
    pub index: i64,
    /// Accepted values per field, any of them matching; an empty list matches
    /// every value. The fields are ANDed.
    pub from: Vec<String>,
    pub to: Vec<String>,
    pub sighash: Vec<String>,
    /// `1` for a successful transaction, `0` for a reverted one, absent for
    /// either.
    pub status: Option<i64>,
    pub transaction_fields: Vec<TransactionField>,
    pub block_fields: Vec<BlockField>,
}

#[napi(object)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransactionItem {
    pub block_number: i64,
    pub transaction_index: i64,
    pub on_transaction_registration_index: i64,
}

/// What a transaction is matched on, read off whichever row a source built.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct TransactionView<'a> {
    pub from: Option<&'a [u8]>,
    pub to: Option<&'a [u8]>,
    /// The calldata, or just its selector where that is all the row carries.
    pub input: Option<&'a [u8]>,
    pub status: Option<u8>,
}

impl<'a> TransactionView<'a> {
    pub(crate) fn of(tx: &'a Transaction) -> Self {
        TransactionView {
            from: tx.from.as_ref().map(AsRef::as_ref),
            to: tx.to.as_ref().map(AsRef::as_ref),
            input: tx.input.as_ref().or(tx.sighash.as_ref()).map(AsRef::as_ref),
            status: tx.status.as_ref().map(|status| status.to_u8()),
        }
    }
}

#[derive(Clone)]
struct Registration {
    index: i64,
    from: Vec<FixedSizeData<20>>,
    to: Vec<FixedSizeData<20>>,
    sighash: Vec<FixedSizeData<4>>,
    status: Option<u8>,
    transaction_fields: Vec<TransactionField>,
    block_fields: Vec<BlockField>,
}

fn any_of<const N: usize>(accepted: &[FixedSizeData<N>], actual: Option<&[u8]>) -> bool {
    accepted.is_empty()
        || actual.is_some_and(|actual| {
            accepted
                .iter()
                .any(|value| value.as_ref() == &actual[..N.min(actual.len())])
        })
}

impl Registration {
    /// Whether the call matches, status aside: what a source can tell from
    /// the transaction alone.
    fn matches_call(&self, view: &TransactionView) -> bool {
        any_of(&self.from, view.from)
            && any_of(&self.to, view.to)
            && any_of(&self.sighash, view.input.filter(|input| input.len() >= 4))
    }

    fn matches(&self, view: &TransactionView) -> bool {
        self.matches_call(view)
            && self
                .status
                .is_none_or(|wanted| view.status.is_some_and(|status| status == wanted))
    }

    fn filter(&self) -> TransactionFilter {
        TransactionFilter {
            from: hex_list(&self.from),
            to: hex_list(&self.to),
            sighash: hex_list(&self.sighash),
            status: self.status.map(i64::from),
            ..Default::default()
        }
    }
}

fn hex_list<const N: usize>(values: &[FixedSizeData<N>]) -> Option<Vec<String>> {
    (!values.is_empty()).then(|| values.iter().map(Hex::encode_hex).collect())
}

pub(crate) struct TransactionRegistrations(HashMap<i64, Registration>);

fn decode_all<const N: usize>(values: &[String], what: &str) -> Result<Vec<FixedSizeData<N>>> {
    values
        .iter()
        .map(|value| {
            FixedSizeData::<N>::decode_hex(value)
                .with_context(|| format!("transaction handler {what} {value:?}"))
        })
        .collect()
}

impl TransactionRegistrations {
    pub(crate) fn new(inputs: &[OnTransactionRegistrationInput]) -> Result<Self> {
        let mut registrations = HashMap::new();
        for input in inputs {
            let status = input
                .status
                .map(|status| match status {
                    0 | 1 => Ok(status as u8),
                    _ => Err(anyhow::anyhow!(
                        "transaction handler {} has status {status}, expected 0 or 1",
                        input.index
                    )),
                })
                .transpose()?;
            registrations.insert(
                input.index,
                Registration {
                    index: input.index,
                    from: decode_all(&input.from, "from")?,
                    to: decode_all(&input.to, "to")?,
                    sighash: decode_all(&input.sighash, "sighash")?,
                    status,
                    transaction_fields: input.transaction_fields.clone(),
                    block_fields: input.block_fields.clone(),
                },
            );
        }
        Ok(TransactionRegistrations(registrations))
    }

    pub(crate) fn select(&self, indexes: &[i64]) -> Result<TransactionSelection> {
        let mut registrations = Vec::with_capacity(indexes.len());
        for index in indexes {
            let registration = self.0.get(index).with_context(|| {
                format!("Unknown transaction handler index {index} in query selection")
            })?;
            registrations.push(registration.clone());
        }
        registrations.sort_unstable_by_key(|r| r.index);
        Ok(TransactionSelection { registrations })
    }
}

/// The transaction handlers a query runs.
pub(crate) struct TransactionSelection {
    registrations: Vec<Registration>,
}

fn union<T: Copy + Ord>(lists: impl Iterator<Item = T>) -> Vec<T> {
    let mut fields: Vec<T> = lists.collect();
    fields.sort_unstable();
    fields.dedup();
    fields
}

impl TransactionSelection {
    pub(crate) fn is_empty(&self) -> bool {
        self.registrations.is_empty()
    }

    pub(crate) fn indexes(&self) -> impl Iterator<Item = i64> + '_ {
        self.registrations.iter().map(|r| r.index)
    }

    /// One server-side filter per handler. HyperSync ORs them, so a
    /// transaction matching several comes back once and `route` fans it out.
    pub(crate) fn filters(&self) -> Vec<TransactionFilter> {
        self.registrations
            .iter()
            .map(Registration::filter)
            .collect()
    }

    /// Every transaction field some handler selected.
    pub(crate) fn transaction_fields(&self) -> Vec<TransactionField> {
        union(
            self.registrations
                .iter()
                .flat_map(|r| r.transaction_fields.iter().copied()),
        )
    }

    /// Every block field some handler selected.
    pub(crate) fn block_fields(&self) -> Vec<BlockField> {
        union(
            self.registrations
                .iter()
                .flat_map(|r| r.block_fields.iter().copied()),
        )
    }

    /// The fields `route` reads: the parties always, the selector and the
    /// status only where a filter names them.
    pub(crate) fn routing_fields(&self) -> Vec<TransactionField> {
        let mut fields = vec![TransactionField::From, TransactionField::To];
        if self.registrations.iter().any(|r| !r.sighash.is_empty()) {
            fields.push(TransactionField::Sighash);
        }
        if self.registrations.iter().any(|r| r.status.is_some()) {
            fields.push(TransactionField::Status);
        }
        fields
    }

    /// The handlers a transaction runs, in registration order.
    pub(crate) fn route(&self, view: &TransactionView) -> Vec<i64> {
        self.registrations
            .iter()
            .filter(|r| r.matches(view))
            .map(|r| r.index)
            .collect()
    }

    /// Whether some handler's call filter matches, so the transaction is
    /// worth reading further for: a source without a server-side filter asks
    /// this of every transaction it scans.
    pub(crate) fn matches_call(&self, view: &TransactionView) -> bool {
        self.registrations.iter().any(|r| r.matches_call(view))
    }

    /// Whether routing needs the transaction's status, which only a receipt
    /// carries: a handler whose call filter matches filters on it.
    pub(crate) fn needs_status(&self, view: &TransactionView) -> bool {
        self.registrations
            .iter()
            .any(|r| r.status.is_some() && r.matches_call(view))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALICE: &str = "0x00000000000000000000000000000000000000aa";
    const BOB: &str = "0x00000000000000000000000000000000000000bb";
    const TRANSFER: &str = "0xa9059cbb";

    fn input(
        index: i64,
        from: &[&str],
        to: &[&str],
        sighash: &[&str],
        status: Option<i64>,
    ) -> OnTransactionRegistrationInput {
        let strings = |values: &[&str]| values.iter().map(|s| s.to_string()).collect();
        OnTransactionRegistrationInput {
            index,
            from: strings(from),
            to: strings(to),
            sighash: strings(sighash),
            status,
            transaction_fields: vec![TransactionField::Input],
            block_fields: vec![BlockField::Timestamp],
        }
    }

    fn selection(inputs: &[OnTransactionRegistrationInput]) -> TransactionSelection {
        let indexes: Vec<i64> = inputs.iter().map(|i| i.index).collect();
        TransactionRegistrations::new(inputs)
            .unwrap()
            .select(&indexes)
            .unwrap()
    }

    fn address(hex: &str) -> FixedSizeData<20> {
        FixedSizeData::decode_hex(hex).unwrap()
    }

    #[test]
    fn routes_a_transaction_to_every_handler_it_matches() {
        let selection = selection(&[
            input(0, &[ALICE], &[], &[], None),
            input(1, &[], &[BOB], &[TRANSFER], None),
            input(2, &[], &[BOB], &[], Some(1)),
            input(3, &[BOB], &[], &[], None),
        ]);
        let from = address(ALICE);
        let to = address(BOB);
        let input = [0xa9, 0x05, 0x9c, 0xbb, 0x00, 0x01];
        let reverted_transfer = TransactionView {
            from: Some(from.as_ref()),
            to: Some(to.as_ref()),
            input: Some(&input),
            status: Some(0),
        };
        let successful_transfer = TransactionView {
            status: Some(1),
            ..reverted_transfer
        };
        let plain_send = TransactionView {
            input: Some(&[]),
            ..successful_transfer
        };
        assert_eq!(
            (
                selection.route(&reverted_transfer),
                selection.route(&successful_transfer),
                selection.route(&plain_send),
            ),
            (vec![0, 1], vec![0, 1, 2], vec![0, 2])
        );
    }

    #[test]
    fn a_contract_creation_matches_no_recipient_filter() {
        let selection = selection(&[input(0, &[], &[BOB], &[], None)]);
        let view = TransactionView {
            to: None,
            ..Default::default()
        };
        assert!(selection.route(&view).is_empty());
    }

    #[test]
    fn only_a_matching_call_with_a_status_filter_needs_the_status() {
        let selection = selection(&[
            input(0, &[ALICE], &[], &[], None),
            input(1, &[BOB], &[], &[], Some(1)),
        ]);
        let alice = address(ALICE);
        let bob = address(BOB);
        let from_alice = TransactionView {
            from: Some(alice.as_ref()),
            ..Default::default()
        };
        let from_bob = TransactionView {
            from: Some(bob.as_ref()),
            ..Default::default()
        };
        let from_nobody = TransactionView::default();
        assert_eq!(
            (
                selection.needs_status(&from_alice),
                selection.needs_status(&from_bob),
                selection.matches_call(&from_nobody),
            ),
            (false, true, false)
        );
    }

    #[test]
    fn builds_one_server_filter_per_handler_and_unions_the_fields() {
        let selection = selection(&[
            input(
                0,
                &["0x00000000000000000000000000000000000000AA"],
                &[],
                &[],
                None,
            ),
            input(1, &[], &[BOB], &[TRANSFER], Some(0)),
        ]);
        let filters: Vec<String> = selection
            .filters()
            .into_iter()
            .map(|f| format!("{:?} {:?} {:?} {:?}", f.from, f.to, f.sighash, f.status))
            .collect();
        assert_eq!(
            (
                filters,
                selection.transaction_fields(),
                selection.block_fields(),
                selection.routing_fields(),
            ),
            (
                vec![
                    format!("{:?} None None None", Some(vec![ALICE])),
                    format!(
                        "None {:?} {:?} Some(0)",
                        Some(vec![BOB]),
                        Some(vec![TRANSFER])
                    ),
                ],
                vec![TransactionField::Input],
                vec![BlockField::Timestamp],
                vec![
                    TransactionField::From,
                    TransactionField::To,
                    TransactionField::Sighash,
                    TransactionField::Status,
                ],
            )
        );
    }

    #[test]
    fn routes_on_the_parties_alone_without_a_selector_or_status_filter() {
        let selection = selection(&[input(0, &[ALICE], &[BOB], &[], None)]);
        assert_eq!(
            selection.routing_fields(),
            vec![TransactionField::From, TransactionField::To]
        );
    }

    #[test]
    fn a_row_carrying_only_the_selector_routes_on_it() {
        let selection = selection(&[input(0, &[], &[], &[TRANSFER], None)]);
        let selector_only = Transaction {
            sighash: Some(hypersync_client::format::Data::decode_hex(TRANSFER).unwrap()),
            ..Default::default()
        };
        let other_selector = Transaction {
            sighash: Some(hypersync_client::format::Data::decode_hex("0x095ea7b3").unwrap()),
            ..Default::default()
        };
        assert_eq!(
            (
                selection.route(&TransactionView::of(&selector_only)),
                selection.route(&TransactionView::of(&other_selector)),
            ),
            (vec![0], vec![])
        );
    }

    #[test]
    fn rejects_a_value_the_filter_cannot_hold() {
        let short_selector = TransactionRegistrations::new(&[input(0, &[], &[], &["0xa9"], None)]);
        let bad_status = TransactionRegistrations::new(&[input(0, &[], &[], &[], Some(2))]);
        assert!(short_selector.is_err() && bad_status.is_err());
    }
}
