//! The data-source clients: HyperSync for EVM, Fuel and SVM, and EVM JSON-RPC.
//! May import chain_buffer, address_store, the ecosystem modules (evm, fuel,
//! svm), clock and logger; none of those may import sources.

pub(crate) mod block_hash_pagination;
pub(crate) mod evm_hypersync;
pub(crate) mod evm_rpc;
pub(crate) mod failure;
pub(crate) mod fuel_hypersync;
pub(crate) mod request_stats;
pub(crate) mod source;
pub(crate) mod svm_hypersync;
pub(crate) mod testing;
