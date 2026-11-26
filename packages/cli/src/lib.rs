// Tests may sleep and time out on the real clock; the code they test may not.
#![cfg_attr(test, allow(clippy::disallowed_methods))]

mod address_store;
mod chain_buffer;
mod cli_args;
mod clickhouse;
mod clock;
mod columnar;
mod entity_filter;
mod env;
pub use cli_args::clap_definitions;
pub use cli_args::init_config;
mod commands;
pub mod config_parsing;
pub mod constants;
pub mod docker_env;
mod evm;
pub mod executor;
mod fuel;
mod hbs_templating;
mod hex;
mod indexer_env;
mod js_value;
#[cfg(test)]
mod layers;
mod logger;
#[cfg_attr(test, allow(dead_code))]
mod napi;
mod postgres;
mod project_paths;
mod registration_start_block;
pub mod scripts;
mod service_health;
mod sources;
mod storage;
mod svm;
mod template_dirs;
#[cfg(test)]
mod test_servers;
mod text_position;
mod ts_loader;
mod tui;
mod type_schema;
mod utils;
