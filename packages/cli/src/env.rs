//! The one module that reads the process environment. The indexer reads it
//! where it starts and hands values on as config; the layer test keeps the
//! runtime's logic (sources, chain buffer, address store) from importing this.
#![allow(clippy::disallowed_methods)]

use std::ffi::OsString;

/// The variable's value, when it is set and valid Unicode.
pub(crate) fn var(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

pub(crate) fn var_os(name: &str) -> Option<OsString> {
    std::env::var_os(name)
}

pub(crate) fn is_set(name: &str) -> bool {
    std::env::var_os(name).is_some()
}
