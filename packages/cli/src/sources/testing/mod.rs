//! Test doubles for the data sources: the mock source JS drives, a local
//! HyperSync server, and the HTTP framing the crate's mock servers share.
//! Must not be imported by chain_buffer, address_store, evm, fuel or svm.

pub(crate) mod mock_http;
pub(crate) mod mock_hypersync_server;
pub(crate) mod mock_source;
