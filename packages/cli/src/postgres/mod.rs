//! The Postgres storage backend.
//!
//! The statements an indexer runs against Postgres are built here rather than in
//! ReScript. What crosses the addon boundary is the shape of a table — its
//! columns, their types, what the primary key is — and what comes back is the
//! SQL. The storage interface itself stays in ReScript.

pub mod client;
pub mod ddl;
pub mod index_definition;
pub mod insert;
#[cfg(test)]
mod live_tests;
pub mod param;
pub mod pg_type;
pub mod rollback;
pub mod rows;
// Reached from the checks that put it through a server. It goes live with the
// storage layer that binds these parameters, in the change that retires the
// driver still doing so.
#[allow(dead_code)]
pub mod write;

// The addon registers these; a test build has no registration and would see
// every export as dead.
#[cfg_attr(test, allow(dead_code))]
mod js;
