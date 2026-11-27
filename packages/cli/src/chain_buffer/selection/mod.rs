//! Per ecosystem, a chain's registrations compiled into what a query selects
//! and how far each registration's scope reaches. Reads the address store;
//! must not import sources.

pub(crate) mod evm;
pub(crate) mod fuel;
pub(crate) mod svm;
pub(crate) mod svm_fields;
