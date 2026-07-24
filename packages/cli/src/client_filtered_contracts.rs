//! Contracts a single query fetches address-free even though their
//! registrations depend on addresses. When a contract's registered address
//! count grows past the server-side threshold, the fetch state switches it to
//! client-side (wildcard) filtering: its log/receipt selections are built
//! without a server-side address filter and routing accepts any emitter, while
//! the JS `clientAddressFilter` still drops items whose emitter isn't a
//! registered address at/before the log's block. Shared by every source's
//! selection builder and router so the "is this registration client-filtered"
//! decision lives in one place.

use std::collections::HashSet;

#[derive(Default)]
pub struct ClientFilteredContracts(HashSet<String>);

impl ClientFilteredContracts {
    pub fn from_vec(contract_names: Vec<String>) -> Self {
        Self(contract_names.into_iter().collect())
    }

    /// Whether this registration should be fetched address-free and routed as a
    /// wildcard. Only address-dependent registrations are affected; a genuinely
    /// wildcard registration is already address-free.
    pub fn applies(&self, contract_name: &str) -> bool {
        self.0.contains(contract_name)
    }
}
