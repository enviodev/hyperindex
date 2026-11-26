//! The buffer's sorted tables and, per ecosystem, their schemas, how a
//! source's rows fill them and how their cells read back. Must not import
//! sources.

pub(crate) mod evm;
pub(crate) mod fuel;
pub(crate) mod svm;
pub(crate) mod table;
