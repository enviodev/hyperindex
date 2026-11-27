// Tests may sleep and time out on the real clock; the code they test may not.
#![cfg_attr(test, allow(clippy::disallowed_methods))]

mod address_columns;
mod address_store;
mod block_hash_pagination;
mod block_selection;
mod chain_buffer;
mod cli_args;
mod clickhouse;
mod client_filtered_contracts;
mod clock;
mod columnar;
mod entity_filter;
pub(crate) use cli_args::clap_definitions;
pub(crate) use cli_args::init_config;
mod commands;
mod config_parsing;
mod constants;
mod docker_env;
mod evm;
mod evm_hypersync_source;
mod evm_rpc_source;
mod executor;
mod fuel;
mod fuel_hypersync_source;
mod hbs_templating;
mod hex;
mod js_value;
mod logger;
mod mock_http;
mod mock_hypersync_server;
mod mock_source;
#[cfg_attr(test, allow(dead_code))]
mod napi;
mod postgres;
mod project_paths;
mod registration_start_block;
mod request_stats;
mod scripts;
mod service_health;
mod storage;
mod svm;
mod svm_hypersync_source;
mod template_dirs;
#[cfg(test)]
mod test_servers;
mod text_position;
mod ts_loader;
mod tui;
mod type_schema;
mod utils;

// The crate's whole Rust API: what `examples/script.rs` and
// `tests/hypersync_health.rs` link against. Everything else reaches its
// callers through `#[napi]`. `dead_code` cannot check an exported item or the
// methods of an exported type, so nothing joins this list without a caller
// outside the crate.
pub use config_parsing::chain_helpers::HypersyncChain;
pub use config_parsing::hypersync_endpoints::network_to_hypersync_url;
pub use executor::run_script_from_process_args;
pub use scripts::print_missing_networks::{format_extra_chain, Diff};
