//! A chain's transaction registrations compiled once, and which of them a
//! transaction belongs to. A filter is source-agnostic: each source maps it to
//! its own protocol, and every copy of a row matches the same registrations
//! whichever source fetched it.

use anyhow::{ensure, Context, Result};
use napi_derive::napi;

use hypersync_client::simple_types::Transaction;

use crate::chain_buffer::tables::table::RowRef;
use crate::ecosystems::evm::fields::EvmTxField;

/// One `indexer.onTransaction` registration, as JS resolved it for a chain.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct OnTransactionRegistrationInput {
    pub index: i64,
    /// Absent matches any value of the field; a listed field matches any of
    /// its values.
    pub from: Option<Vec<String>>,
    pub to: Option<Vec<String>>,
    pub status: Option<i64>,
    /// The transaction fields the handler reads, as the transactions table's
    /// bitmask.
    pub transaction_field_mask: f64,
    /// The block fields the handler reads, as the blocks table's bitmask.
    pub block_field_mask: f64,
}

/// What a filter compares: fields ANDed, the values of one field ORed, an
/// empty list matching any value.
#[derive(Debug)]
pub(crate) struct TransactionFilter {
    pub(crate) from: Vec<[u8; 20]>,
    pub(crate) to: Vec<[u8; 20]>,
    pub(crate) status: Option<u8>,
}

/// A transaction's fields as matching reads them. A field is `None` when the
/// transaction has none (a contract creation's `to`, a receipt predating
/// `status`) or the row wasn't fetched with it: either way no filter on it
/// matches.
#[derive(Clone, Copy, Debug)]
pub(crate) struct TransactionView<'a> {
    pub(crate) from: Option<&'a [u8]>,
    pub(crate) to: Option<&'a [u8]>,
    pub(crate) status: Option<u64>,
}

pub(crate) const fn bit(field: EvmTxField) -> u64 {
    1 << field as u32
}

impl<'a> TransactionView<'a> {
    pub(crate) fn of_row(row: &RowRef<'a>) -> Self {
        let row = *row;
        let fetched = row.fetched();
        let fetched_with = |field: EvmTxField| fetched & bit(field) != 0;
        TransactionView {
            from: row
                .bytes_at(EvmTxField::From as usize)
                .filter(|_| fetched_with(EvmTxField::From)),
            to: row
                .bytes_at(EvmTxField::To as usize)
                .filter(|_| fetched_with(EvmTxField::To)),
            status: row
                .u64_at(EvmTxField::Status as usize)
                .filter(|_| fetched_with(EvmTxField::Status)),
        }
    }

    /// A source's transaction, read for the fields of `fetched`.
    pub(crate) fn of_transaction(transaction: &'a Transaction, fetched: u64) -> Self {
        let fetched_with = |field: EvmTxField| fetched & bit(field) != 0;
        TransactionView {
            from: transaction
                .from
                .as_deref()
                .map(|from| from.as_slice())
                .filter(|_| fetched_with(EvmTxField::From)),
            to: transaction
                .to
                .as_deref()
                .map(|to| to.as_slice())
                .filter(|_| fetched_with(EvmTxField::To)),
            status: transaction
                .status
                .map(|status| status.to_u8() as u64)
                .filter(|_| fetched_with(EvmTxField::Status)),
        }
    }
}

fn any_of(values: &[[u8; 20]], actual: Option<&[u8]>) -> bool {
    values.is_empty()
        || actual.is_some_and(|actual| values.iter().any(|value| value.as_slice() == actual))
}

impl TransactionFilter {
    /// The fields matching compares, as the transactions table's bitmask: what
    /// a source fetches for a row to be matched.
    pub(crate) fn fields_read(&self) -> u64 {
        let when = |filters: bool, mask: u64| if filters { mask } else { 0 };
        when(!self.from.is_empty(), bit(EvmTxField::From))
            | when(!self.to.is_empty(), bit(EvmTxField::To))
            | when(self.status.is_some(), bit(EvmTxField::Status))
    }

    /// The part a transaction's own fields decide, before its receipt is read.
    pub(crate) fn matches_call(&self, view: &TransactionView) -> bool {
        any_of(&self.from, view.from) && any_of(&self.to, view.to)
    }

    pub(crate) fn matches_status(&self, status: Option<u64>) -> bool {
        self.status
            .is_none_or(|expected| status == Some(u64::from(expected)))
    }

    pub(crate) fn matches(&self, view: &TransactionView) -> bool {
        self.matches_call(view) && self.matches_status(view.status)
    }
}

fn parse_addresses(values: &Option<Vec<String>>, name: &str) -> Result<Vec<[u8; 20]>> {
    let Some(values) = values else {
        return Ok(Vec::new());
    };
    ensure!(!values.is_empty(), "`{name}` lists no value");
    let mut parsed: Vec<[u8; 20]> = values
        .iter()
        .map(|value| {
            let bytes = crate::hex::decode_prefixed(value, name)?;
            <[u8; 20]>::try_from(bytes.as_slice()).map_err(|_| {
                anyhow::anyhow!(
                    "`{name}` value {value} must be 20 bytes, got {}",
                    bytes.len()
                )
            })
        })
        .collect::<Result<_>>()?;
    parsed.sort_unstable();
    parsed.dedup();
    Ok(parsed)
}

pub(crate) struct OnTransactionRegistration {
    pub(crate) index: u32,
    pub(crate) filter: TransactionFilter,
    pub(crate) transaction_mask: u64,
    pub(crate) block_mask: u64,
}

impl OnTransactionRegistration {
    fn compile(input: &OnTransactionRegistrationInput) -> Result<Self> {
        let status = input
            .status
            .map(|status| {
                ensure!(
                    status == 0 || status == 1,
                    "`status` must be 0 or 1, got {status}"
                );
                Ok(status as u8)
            })
            .transpose()?;
        Ok(OnTransactionRegistration {
            index: u32::try_from(input.index).context("a negative registration index")?,
            filter: TransactionFilter {
                from: parse_addresses(&input.from, "from")?,
                to: parse_addresses(&input.to, "to")?,
                status,
            },
            transaction_mask: input.transaction_field_mask as u64,
            block_mask: input.block_field_mask as u64,
        })
    }
}

/// A chain's transaction registrations, in registration order: a
/// registration's index is its position.
#[derive(Default)]
pub(crate) struct TransactionMatcher {
    registrations: Vec<OnTransactionRegistration>,
}

impl TransactionMatcher {
    pub(crate) fn new(inputs: &[OnTransactionRegistrationInput]) -> Result<Self> {
        let mut registrations = inputs
            .iter()
            .map(|input| {
                OnTransactionRegistration::compile(input)
                    .with_context(|| format!("transaction registration {}", input.index))
            })
            .collect::<Result<Vec<_>>>()?;
        registrations.sort_unstable_by_key(|registration| registration.index);
        ensure!(
            registrations
                .iter()
                .enumerate()
                .all(|(position, registration)| registration.index as usize == position),
            "transaction registration indexes must count up from 0"
        );
        Ok(TransactionMatcher { registrations })
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.registrations.is_empty()
    }

    pub(crate) fn registration(&self, index: u32) -> Option<&OnTransactionRegistration> {
        self.registrations.get(index as usize)
    }

    /// A query selecting any transaction handler fetches for all of them, as
    /// they share one partition.
    pub(crate) fn registrations(&self) -> Vec<&OnTransactionRegistration> {
        self.registrations.iter().collect()
    }

    /// Calls `f` with every registration the transaction belongs to, in
    /// index order.
    pub(crate) fn for_each_match(
        &self,
        view: &TransactionView,
        mut f: impl FnMut(&OnTransactionRegistration),
    ) {
        for registration in &self.registrations {
            if registration.filter.matches(view) {
                f(registration);
            }
        }
    }

    pub(crate) fn matches_any(&self, view: &TransactionView) -> bool {
        self.registrations
            .iter()
            .any(|registration| registration.filter.matches(view))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "0x00000000000000000000000000000000000000aa";
    const B: &str = "0x00000000000000000000000000000000000000bb";

    fn input(index: i64) -> OnTransactionRegistrationInput {
        OnTransactionRegistrationInput {
            index,
            from: None,
            to: None,
            status: None,
            transaction_field_mask: 0.0,
            block_field_mask: 0.0,
        }
    }

    fn view<'a>(
        from: Option<&'a [u8]>,
        to: Option<&'a [u8]>,
        status: Option<u64>,
    ) -> TransactionView<'a> {
        TransactionView { from, to, status }
    }

    fn matched(matcher: &TransactionMatcher, view: &TransactionView) -> Vec<u32> {
        let mut indexes = Vec::new();
        matcher.for_each_match(view, |registration| indexes.push(registration.index));
        indexes
    }

    #[test]
    fn fields_are_anded_values_ored_and_a_missing_field_never_matches() {
        let a = [0u8; 19].into_iter().chain([0xaa]).collect::<Vec<_>>();
        let b = [0u8; 19].into_iter().chain([0xbb]).collect::<Vec<_>>();
        let matcher = TransactionMatcher::new(&[
            OnTransactionRegistrationInput {
                to: Some(vec![A.to_string(), B.to_string()]),
                ..input(0)
            },
            OnTransactionRegistrationInput {
                from: Some(vec![A.to_string()]),
                status: Some(1),
                ..input(1)
            },
            input(2),
        ])
        .unwrap();
        assert_eq!(
            (
                matched(&matcher, &view(Some(&a), Some(&b), Some(1))),
                matched(&matcher, &view(Some(&a), None, Some(0))),
                matched(&matcher, &view(None, Some(&b), None)),
            ),
            (vec![0, 1, 2], vec![2], vec![0, 2])
        );
    }

    #[test]
    fn a_value_that_cannot_match_is_rejected() {
        let errors: Vec<String> = [
            OnTransactionRegistrationInput {
                from: Some(vec!["0x1234".to_string()]),
                ..input(0)
            },
            OnTransactionRegistrationInput {
                to: Some(vec![]),
                ..input(0)
            },
            OnTransactionRegistrationInput {
                status: Some(2),
                ..input(0)
            },
        ]
        .into_iter()
        .map(|input| format!("{:#}", TransactionMatcher::new(&[input]).err().unwrap()))
        .collect();
        assert_eq!(
            errors,
            vec![
                "transaction registration 0: `from` value 0x1234 must be 20 bytes, got 2",
                "transaction registration 0: `to` lists no value",
                "transaction registration 0: `status` must be 0 or 1, got 2",
            ]
        );
    }
}
