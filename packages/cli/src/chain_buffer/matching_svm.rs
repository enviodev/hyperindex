//! A chain's SVM instruction registrations compiled once, and which of them a
//! fetched instruction belongs to. Like EVM matching it reads the address
//! store and nothing else.

use std::sync::{Arc, RwLock, RwLockReadGuard};

use anyhow::Result;

use super::matching::RowMatch;
use super::svm::InstructionView;
use crate::address_store::{AddressStore, StoreInner};
use crate::svm_hypersync_source::selection::{
    Instruction, Registration, SelectedInstruction, SelectionBuilder, SvmProgramInput,
};

pub(crate) struct SvmMatcher {
    /// Every config instruction with all of its registrations.
    instructions: Vec<SelectedInstruction>,
    contract_register_indexes: Vec<i64>,
    store: Arc<RwLock<StoreInner>>,
}

impl SvmMatcher {
    pub(crate) fn new(
        programs: &[SvmProgramInput],
        contract_register_indexes: &[i64],
        address_store: &AddressStore,
    ) -> Result<Self> {
        let store = address_store.handle();
        let instructions = {
            let inner = store.read().unwrap();
            let builder = SelectionBuilder::from_programs(programs, &inner)?;
            builder.build(&builder.registration_indexes())?.instructions
        };
        Ok(SvmMatcher {
            instructions,
            contract_register_indexes: contract_register_indexes.to_vec(),
            store,
        })
    }

    pub(crate) fn read_store(&self) -> RwLockReadGuard<'_, StoreInner> {
        self.store.read().unwrap()
    }

    pub(crate) fn has_contract_register(&self, registration: &Registration) -> bool {
        self.contract_register_indexes.contains(&registration.index)
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
            found.registers |= self.has_contract_register(registration);
        }
        found
    }
}
