pub mod client;
pub mod ddl;
pub mod error;
pub mod history;
pub mod index_definition;
pub mod indexes;
pub mod insert;
pub mod internal;
#[cfg(test)]
mod live_tests;
pub mod param;
pub mod pg_type;
pub mod rows;
pub mod select;
pub mod storage;
pub mod write;

// The addon registers these; a test build has no registration and would see
// every export as dead.
#[cfg_attr(test, allow(dead_code))]
mod js;
