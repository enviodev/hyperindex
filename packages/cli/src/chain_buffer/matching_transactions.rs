//! A chain's transaction registrations compiled once, and which of them a
//! transaction belongs to. A filter is source-agnostic: each source maps it to
//! its own protocol, and every copy of a row matches the same registrations
//! whichever source fetched it.

use anyhow::{ensure, Context, Result};
use napi_derive::napi;

use hypersync_client::simple_types::Transaction;

use super::evm::EvmTxField;
use super::table::RowRef;

/// One `indexer.onTransaction` registration, as JS resolved it for a chain.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct OnTransactionRegistrationInput {
    pub index: i64,
    /// Absent matches any value of the field; a listed field matches any of
    /// its values.
    pub from: Option<Vec<String>>,
    pub to: Option<Vec<String>>,
    pub sighash: Option<Vec<String>>,
    pub status: Option<i64>,
    /// The transaction fields the handler reads, as the transactions table's
    /// bitmask, the always-carried ones included.
    pub transaction_field_mask: f64,
    /// The block fields the handler reads, as the blocks table's bitmask.
    pub block_field_mask: f64,
}

/// What a filter compares: fields ANDed, the values of one field ORed, an
/// empty list matching any value.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct TransactionFilter {
    pub(crate) from: Vec<[u8; 20]>,
    pub(crate) to: Vec<[u8; 20]>,
    pub(crate) sighash: Vec<[u8; 4]>,
    pub(crate) status: Option<u8>,
}

/// A field of a transaction as matching reads it: `Unheld` when the row was
/// not fetched with it, `Absent` when it was and the transaction has none (a
/// contract creation's `to`, calldata shorter than a selector, a receipt
/// predating `status`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Held<T> {
    Unheld,
    Absent,
    Value(T),
}

impl<T> Held<T> {
    pub(crate) fn new(held: bool, value: Option<T>) -> Self {
        match (held, value) {
            (false, _) => Held::Unheld,
            (true, None) => Held::Absent,
            (true, Some(value)) => Held::Value(value),
        }
    }
}

/// A transaction's fields as matching reads them.
#[derive(Clone, Copy, Debug)]
pub(crate) struct TransactionView<'a> {
    pub(crate) from: Held<&'a [u8]>,
    pub(crate) to: Held<&'a [u8]>,
    pub(crate) sighash: Held<&'a [u8]>,
    pub(crate) status: Held<u64>,
}

const fn bit(field: EvmTxField) -> u64 {
    1 << field as u32
}

impl<'a> TransactionView<'a> {
    pub(crate) fn of_row(row: &RowRef<'a>) -> Self {
        let row = *row;
        let fetched = row.fetched();
        let held =
            |field: EvmTxField| Held::new(fetched & bit(field) != 0, row.bytes_at(field as usize));
        TransactionView {
            from: held(EvmTxField::From),
            to: held(EvmTxField::To),
            sighash: held(EvmTxField::Sighash),
            status: Held::new(
                fetched & bit(EvmTxField::Status) != 0,
                row.u64_at(EvmTxField::Status as usize),
            ),
        }
    }

    /// A source's transaction, read for the fields of `fetched`.
    pub(crate) fn of_transaction(transaction: &'a Transaction, fetched: u64) -> Self {
        let held = |field: EvmTxField, value: Option<&'a [u8]>| {
            Held::new(fetched & bit(field) != 0, value)
        };
        TransactionView {
            from: held(
                EvmTxField::From,
                transaction.from.as_deref().map(|from| from.as_slice()),
            ),
            to: held(
                EvmTxField::To,
                transaction.to.as_deref().map(|to| to.as_slice()),
            ),
            sighash: held(
                EvmTxField::Sighash,
                transaction
                    .sighash
                    .as_deref()
                    .map(|sighash| sighash.as_ref()),
            ),
            status: Held::new(
                fetched & bit(EvmTxField::Status) != 0,
                transaction.status.map(|status| status.to_u8() as u64),
            ),
        }
    }
}

fn any_of<const N: usize>(values: &[[u8; N]], actual: Held<&[u8]>) -> bool {
    values.is_empty()
        || matches!(actual, Held::Value(actual) if values.iter().any(|value| value.as_slice() == actual))
}

impl TransactionFilter {
    /// The fields matching compares, as the transactions table's bitmask: what
    /// a source fetches for a row to be matched.
    pub(crate) fn fields_read(&self) -> u64 {
        let when = |filters: bool, mask: u64| if filters { mask } else { 0 };
        when(!self.from.is_empty(), bit(EvmTxField::From))
            | when(!self.to.is_empty(), bit(EvmTxField::To))
            | when(!self.sighash.is_empty(), bit(EvmTxField::Sighash))
            | when(self.status.is_some(), bit(EvmTxField::Status))
    }

    /// The part a transaction's own fields decide, before its receipt is read.
    pub(crate) fn matches_call(&self, view: &TransactionView) -> bool {
        any_of(&self.from, view.from)
            && any_of(&self.to, view.to)
            && any_of(&self.sighash, view.sighash)
    }

    pub(crate) fn matches_status(&self, status: Held<u64>) -> bool {
        match self.status {
            None => true,
            Some(expected) => status == Held::Value(expected as u64),
        }
    }

    pub(crate) fn matches(&self, view: &TransactionView) -> bool {
        self.matches_call(view) && self.matches_status(view.status)
    }
}

fn parse_values<const N: usize>(values: &Option<Vec<String>>, name: &str) -> Result<Vec<[u8; N]>> {
    let Some(values) = values else {
        return Ok(Vec::new());
    };
    ensure!(!values.is_empty(), "`{name}` lists no value");
    let mut parsed: Vec<[u8; N]> = values
        .iter()
        .map(|value| {
            let bytes = crate::hex::decode_prefixed(value, name)?;
            <[u8; N]>::try_from(bytes.as_slice()).map_err(|_| {
                anyhow::anyhow!(
                    "`{name}` value {value} must be {N} bytes, got {}",
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
                from: parse_values(&input.from, "from")?,
                to: parse_values(&input.to, "to")?,
                sighash: parse_values(&input.sighash, "sighash")?,
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

    /// The registrations `indexes` names, in index order.
    pub(crate) fn select(&self, indexes: &[i64]) -> Result<Vec<&OnTransactionRegistration>> {
        let mut selected = indexes
            .iter()
            .map(|index| {
                u32::try_from(*index)
                    .ok()
                    .and_then(|index| self.registration(index))
                    .with_context(|| {
                        format!("Unknown transaction registration index {index} in query selection")
                    })
            })
            .collect::<Result<Vec<_>>>()?;
        selected.sort_unstable_by_key(|registration| registration.index);
        selected.dedup_by_key(|registration| registration.index);
        Ok(selected)
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
            sighash: None,
            status: None,
            transaction_field_mask: 0.0,
            block_field_mask: 0.0,
        }
    }

    fn view<'a>(
        from: Held<&'a [u8]>,
        to: Held<&'a [u8]>,
        sighash: Held<&'a [u8]>,
        status: Held<u64>,
    ) -> TransactionView<'a> {
        TransactionView {
            from,
            to,
            sighash,
            status,
        }
    }

    fn matched(matcher: &TransactionMatcher, view: &TransactionView) -> Vec<u32> {
        let mut indexes = Vec::new();
        matcher.for_each_match(view, |registration| indexes.push(registration.index));
        indexes
    }

    #[test]
    fn fields_are_anded_values_ored_and_an_unheld_field_never_matches() {
        let a = [0u8; 19].into_iter().chain([0xaa]).collect::<Vec<_>>();
        let b = [0u8; 19].into_iter().chain([0xbb]).collect::<Vec<_>>();
        let selector = [0xa9, 0x05, 0x9c, 0xbb];
        let matcher = TransactionMatcher::new(&[
            OnTransactionRegistrationInput {
                to: Some(vec![A.to_string(), B.to_string()]),
                sighash: Some(vec!["0xa9059cbb".to_string()]),
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
                matched(
                    &matcher,
                    &view(
                        Held::Value(&a),
                        Held::Value(&b),
                        Held::Value(&selector),
                        Held::Value(1)
                    )
                ),
                matched(
                    &matcher,
                    &view(
                        Held::Value(&a),
                        Held::Absent,
                        Held::Value(&selector),
                        Held::Value(0)
                    )
                ),
                matched(
                    &matcher,
                    &view(Held::Value(&a), Held::Value(&b), Held::Unheld, Held::Unheld)
                ),
            ),
            (vec![0, 1, 2], vec![2], vec![2])
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
                sighash: Some(vec!["0xa9059cbb00".to_string()]),
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
                "transaction registration 0: `sighash` value 0xa9059cbb00 must be 4 bytes, got 5",
                "transaction registration 0: `to` lists no value",
                "transaction registration 0: `status` must be 0 or 1, got 2",
            ]
        );
    }
}
