// Tests may sleep and time out on the real clock; the code they test may not.
#![cfg_attr(test, allow(clippy::disallowed_methods))]

mod address_store;
mod chain_buffer;
mod cli_args;
mod clock;
mod ecosystems;
mod entity_filter;
mod env;
pub(crate) use cli_args::clap_definitions;
pub(crate) use cli_args::init_config;
mod codegen;
mod commands;
mod config_parsing;
mod constants;
mod docker_env;
mod executor;
mod hex;
mod indexer_env;
mod js_value;
#[cfg(test)]
mod layers;
mod logger;
#[cfg_attr(test, allow(dead_code))]
mod napi;
mod project_paths;
mod registration_start_block;
mod scripts;
mod service_health;
mod sources;
mod storage;
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
