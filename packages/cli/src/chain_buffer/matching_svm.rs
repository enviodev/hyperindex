//! A chain's SVM instruction registrations compiled once, and which of them a
//! fetched instruction belongs to. Like EVM matching it reads the address
//! store and nothing else.

use std::sync::{Arc, RwLock, RwLockReadGuard};

use anyhow::Result;

use super::matching::{ContractRegisters, RowMatch};
use super::svm::InstructionView;
use crate::address_store::{AddressStore, StoreInner};
use crate::svm_hypersync_source::selection::{
    Instruction, Registration, SelectedInstruction, SelectionBuilder,
};

pub(crate) struct SvmMatcher {
    /// Every config instruction with all of its registrations.
    instructions: Vec<SelectedInstruction>,
    pub(crate) contract_registers: ContractRegisters,
    store: Arc<RwLock<StoreInner>>,
}

impl SvmMatcher {
    pub(crate) fn new(
        selection: &SelectionBuilder,
        contract_registers: ContractRegisters,
        address_store: &AddressStore,
    ) -> Result<Self> {
        Ok(SvmMatcher {
            instructions: selection
                .build(&selection.registration_indexes())?
                .instructions,
            contract_registers,
            store: address_store.handle(),
        })
    }

    pub(crate) fn read_store(&self) -> RwLockReadGuard<'_, StoreInner> {
        self.store.read().unwrap()
    }

    /// Every (instruction, registration) the call belongs to, in registration
    /// index order whatever instruction each registration hangs off: a
    /// program-wide instruction alongside a keyed one, or a 1-byte family
    /// alongside its 2-byte member, all receive the call.
    pub(crate) fn matches<'a>(
        &'a self,
        call: &InstructionView,
        store: &StoreInner,
    ) -> Vec<(&'a Arc<Instruction>, &'a Arc<Registration>)> {
        let mut matched: Vec<(&Arc<Instruction>, &Arc<Registration>)> = self
            .instructions
            .iter()
            .filter(|selected| selected.instruction.matches(call))
            .flat_map(|selected| {
                selected
                    .registrations
                    .iter()
                    .filter(|registration| {
                        registration.matches_scope(&selected.instruction, call, store)
                    })
                    .map(move |registration| (&selected.instruction, registration))
            })
            .collect();
        matched.sort_by_key(|(_, registration)| registration.index);
        matched
    }

    pub(crate) fn classify(&self, call: &InstructionView, store: &StoreInner) -> RowMatch {
        let mut found = RowMatch::default();
        for (_, registration) in self.matches(call, store) {
            found.kept = true;
            found.registers |= self.contract_registers.has(registration.index as u32);
        }
        found
    }
}
