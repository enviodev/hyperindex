//! The Postgres storage backend.
//!
//! The statements an indexer runs against Postgres are built here rather than in
//! ReScript. What crosses the addon boundary is the shape of a table — its
//! columns, their types, what the primary key is — and what comes back is the
//! SQL. The storage interface itself stays in ReScript.

pub mod client;
pub mod ddl;
pub mod index_definition;
#[cfg(test)]
mod live_tests;
// Rendering a value into a bound parameter is reached from the tests that check
// it against a server; the statements that bind arrays and bytes are the write
// path's, and go live with it.
#[allow(dead_code)]
pub mod param;
pub mod pg_type;
pub mod rows;
#[allow(dead_code)]
pub mod write;

// The addon registers these; a test build has no registration and would see
// every export as dead.
#[cfg_attr(test, allow(dead_code))]
mod js;
