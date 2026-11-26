//! A query's transaction registrations as HyperSync transaction selections,
//! which the server filters on.

use hypersync_client::{format::Address, net_types};

use super::push_unique;
use crate::chain_buffer::matching::transactions::OnTransactionRegistration;
use crate::evm::fields::{BlockField, TransactionField};
use crate::evm::rpc_fields::tx_fields_in;

#[derive(Debug, PartialEq)]
pub(crate) struct BuiltTransactionSelection {
    /// One per distinct filter.
    pub filters: Vec<net_types::TransactionFilter>,
    /// What the handlers read, and what matching the returned rows reads.
    pub transaction_fields: Vec<TransactionField>,
    pub block_fields: Vec<BlockField>,
}

impl BuiltTransactionSelection {
    pub(crate) fn selections(&self) -> Vec<net_types::TransactionSelection> {
        self.filters
            .iter()
            .cloned()
            .map(net_types::TransactionSelection::new)
            .collect()
    }
}

fn addresses(values: &[[u8; 20]]) -> Vec<Address> {
    values.iter().copied().map(Address::from).collect()
}

pub(crate) fn build(registrations: &[&OnTransactionRegistration]) -> BuiltTransactionSelection {
    let mut filters: Vec<net_types::TransactionFilter> = Vec::new();
    let (mut transaction_mask, mut block_mask) = (0, 0);
    for registration in registrations {
        let filter = &registration.filter;
        transaction_mask |= registration.transaction_mask | filter.fields_read();
        block_mask |= registration.block_mask;
        let built = net_types::TransactionFilter {
            from: addresses(&filter.from),
            to: addresses(&filter.to),
            status: filter.status,
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
    use crate::chain_buffer::matching::transactions::{
        OnTransactionRegistrationInput, TransactionMatcher,
    };
    use crate::evm::fields::EvmTxField;

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
        let built = build(&matcher.registrations());
        assert_eq!(
            built,
            BuiltTransactionSelection {
                filters: vec![
                    net_types::TransactionFilter {
                        from: vec![Address::try_from(A).unwrap()],
                        status: Some(1),
                        ..Default::default()
                    },
                    net_types::TransactionFilter {
                        to: vec![Address::try_from(A).unwrap()],
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
