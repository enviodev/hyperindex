//! The Postgres storage backend.
//!
//! Everything between the storage interface and the server lives here: the
//! connection pool, the statements an indexer runs, the parameters they bind,
//! and the rows they return. What crosses the addon boundary is the shape of a
//! table and the values of a batch; the storage interface itself stays in
//! ReScript, and a batch's values reach this side through the columnar arena
//! rather than as text it built.

pub mod client;
pub mod ddl;
pub mod error;
pub mod index_definition;
pub mod insert;
pub mod internal;
#[cfg(test)]
mod live_tests;
pub mod param;
pub mod pg_type;
pub mod rollback;
pub mod rows;
pub mod write;

// The addon registers these; a test build has no registration and would see
// every export as dead.
#[cfg_attr(test, allow(dead_code))]
mod js;
