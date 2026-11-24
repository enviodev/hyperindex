//! A query's transaction registrations as HyperSync transaction selections,
//! which the server filters on.

use napi::bindgen_prelude::Either;

use super::push_unique;
use super::query::{BlockField, TransactionField, TransactionFilter, TransactionSelection};
use crate::chain_buffer::matching_transactions::OnTransactionRegistration;
use crate::evm_rpc_source::fields::tx_fields_in;

#[derive(Debug, PartialEq)]
pub(crate) struct BuiltTransactionSelection {
    /// One per distinct filter.
    pub filters: Vec<TransactionFilter>,
    /// What the handlers read, and what matching the returned rows reads.
    pub transaction_fields: Vec<TransactionField>,
    pub block_fields: Vec<BlockField>,
}

impl BuiltTransactionSelection {
    pub(crate) fn selections(&self) -> Vec<Either<TransactionSelection, TransactionFilter>> {
        self.filters.iter().cloned().map(Either::B).collect()
    }
}

fn hex_list(values: &[[u8; 20]]) -> Option<Vec<String>> {
    (!values.is_empty()).then(|| {
        values
            .iter()
            .map(|value| crate::hex::to_hex(value))
            .collect()
    })
}

pub(crate) fn build(registrations: &[&OnTransactionRegistration]) -> BuiltTransactionSelection {
    let mut filters: Vec<TransactionFilter> = Vec::new();
    let (mut transaction_mask, mut block_mask) = (0, 0);
    for registration in registrations {
        let filter = &registration.filter;
        transaction_mask |= registration.transaction_mask | filter.fields_read();
        block_mask |= registration.block_mask;
        let built = TransactionFilter {
            from: hex_list(&filter.from),
            to: hex_list(&filter.to),
            status: filter.status.map(i64::from),
            ..Default::default()
        };
        push_unique(&mut filters, built);
    }
    BuiltTransactionSelection {
        filters,
        transaction_fields: tx_fields_in(transaction_mask),
        block_fields: BlockField::in_store_mask(block_mask),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chain_buffer::evm::EvmTxField;
    use crate::chain_buffer::matching_transactions::{
        OnTransactionRegistrationInput, TransactionMatcher,
    };

    const A: &str = "0x00000000000000000000000000000000000000aa";

    fn input(index: i64) -> OnTransactionRegistrationInput {
        OnTransactionRegistrationInput {
            index,
            from: None,
            to: None,
            status: None,
            transaction_field_mask: ((1 << EvmTxField::Hash as u64)
                | (1 << EvmTxField::From as u64)) as f64,
            block_field_mask: 0.0,
        }
    }

    // An indexer with no transaction handler asks for no transaction field.
    #[test]
    fn no_registration_selects_nothing() {
        assert_eq!(
            build(&[]),
            BuiltTransactionSelection {
                filters: vec![],
                transaction_fields: vec![],
                block_fields: vec![],
            }
        );
    }

    #[test]
    fn identical_filters_collapse_and_filtered_fields_are_read() {
        let matcher = TransactionMatcher::new(&[
            OnTransactionRegistrationInput {
                from: Some(vec![A.to_string()]),
                status: Some(1),
                ..input(0)
            },
            OnTransactionRegistrationInput {
                from: Some(vec![A.to_string()]),
                status: Some(1),
                ..input(1)
            },
            OnTransactionRegistrationInput {
                to: Some(vec![A.to_string()]),
                ..input(2)
            },
        ])
        .unwrap();
        let built = build(&matcher.selected(true));
        assert_eq!(
            built,
            BuiltTransactionSelection {
                filters: vec![
                    TransactionFilter {
                        from: Some(vec![A.to_string()]),
                        status: Some(1),
                        ..Default::default()
                    },
                    TransactionFilter {
                        to: Some(vec![A.to_string()]),
                        ..Default::default()
                    },
                ],
                transaction_fields: vec![
                    TransactionField::From,
                    TransactionField::Hash,
                    TransactionField::To,
                    TransactionField::Status,
                ],
                block_fields: vec![],
            }
        );
    }
}
