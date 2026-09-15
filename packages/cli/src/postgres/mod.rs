//! The Postgres storage backend.
//!
//! The statements an indexer runs against Postgres are built here rather than in
//! ReScript. What crosses the addon boundary is the shape of a table — its
//! columns, their types, what the primary key is — and what comes back is the
//! SQL. The storage interface itself stays in ReScript.

// Not yet reached from ReScript: the driver it replaces owns the connection
// pool, and a second pool alongside it would double what
// `ENVIO_PG_MAX_CONNECTIONS` allows. Both go live in the same change that
// retires it.
#[allow(dead_code)]
pub mod client;
pub mod ddl;
pub mod index_definition;
#[allow(dead_code)]
pub mod param;
pub mod pg_type;

// The addon registers these; a test build has no registration and would see
// every export as dead.
#[cfg_attr(test, allow(dead_code))]
mod js;
