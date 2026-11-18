//! A chain's Fuel registrations compiled once, and which of them a receipt
//! belongs to. Like EVM matching, it reads the address store and nothing else.

use std::sync::{Arc, RwLock, RwLockReadGuard};

use anyhow::Result;

use super::fuel::ReceiptView;
use super::matching::RowMatch;
use crate::address_store::{AddressStore, StoreInner};
use crate::fuel_hypersync_source::selection::{
    parse_registrations, FuelOnEventRegistrationInput, Registration,
};

pub(crate) struct FuelRegistration {
    pub(crate) registration: Registration,
    pub(crate) has_contract_register: bool,
}

impl FuelRegistration {
    pub(crate) fn index(&self) -> u32 {
        self.registration.index as u32
    }
}

pub(crate) struct FuelMatcher {
    /// In registration index order.
    registrations: Vec<FuelRegistration>,
    store: Arc<RwLock<StoreInner>>,
}

impl FuelMatcher {
    pub(crate) fn new(
        inputs: &[FuelOnEventRegistrationInput],
        contract_register_indexes: &[i64],
        address_store: &AddressStore,
    ) -> Result<Self> {
        let store = address_store.handle();
        let mut registrations: Vec<FuelRegistration> = {
            let inner = store.read().unwrap();
            parse_registrations(inputs, &inner)?
        }
        .into_iter()
        .map(|registration| FuelRegistration {
            has_contract_register: contract_register_indexes.contains(&registration.index),
            registration,
        })
        .collect();
        anyhow::ensure!(
            registrations
                .iter()
                .all(|registration| registration.registration.index >= 0),
            "registration index is negative"
        );
        registrations.sort_unstable_by_key(|registration| registration.registration.index);
        Ok(FuelMatcher {
            registrations,
            store,
        })
    }

    pub(crate) fn read_store(&self) -> RwLockReadGuard<'_, StoreInner> {
        self.store.read().unwrap()
    }

    /// Calls `f` with every registration the receipt belongs to, in index
    /// order.
    pub(crate) fn for_each_match(
        &self,
        receipt: &ReceiptView,
        store: &StoreInner,
        mut f: impl FnMut(&FuelRegistration),
    ) {
        for registration in &self.registrations {
            if registration.registration.matches(
                receipt.receipt_type,
                receipt.rb,
                receipt.root_contract_id,
                receipt.block_height as i64,
                store,
            ) {
                f(registration);
            }
        }
    }

    /// Whether any registration keeps the receipt, and whether one of those
    /// registers contracts.
    pub(crate) fn classify(&self, receipt: &ReceiptView, store: &StoreInner) -> RowMatch {
        let mut found = RowMatch::default();
        self.for_each_match(receipt, store, |registration| {
            found.kept = true;
            found.registers |= registration.has_contract_register;
        });
        found
    }
}
