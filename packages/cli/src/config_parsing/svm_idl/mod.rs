//! Program IDL parsing. Owns the Anchor and Codama dialects; the Borsh
//! runtime (`FieldType`, `decode_instruction`) stays upstream.

use std::collections::BTreeMap;

use anyhow::Result;
use hypersync_client_solana::decode::{FieldType, NamedField};

/// One account slot of an instruction, in declared order.
#[derive(Debug, Clone, PartialEq)]
pub struct IdlAccount {
    pub name: String,
    pub optional: bool,
    pub writable: bool,
    pub signer: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct IxIdl {
    pub discriminator: Vec<u8>,
    pub accounts: Vec<IdlAccount>,
    pub args: Vec<NamedField>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EventIdl {
    pub discriminator: Vec<u8>,
    pub fields: Vec<NamedField>,
}

/// A parsed program IDL, keyed by name rather than by discriminator: the
/// config addresses instructions by name, and the discriminator is a field.
#[derive(Debug, Clone, PartialEq)]
pub struct ProgramIdl {
    /// The IDL's own program address, when it declares one.
    pub address: Option<String>,
    pub instructions: BTreeMap<String, IxIdl>,
    pub events: BTreeMap<String, EventIdl>,
    pub defined_types: BTreeMap<String, FieldType>,
}

pub fn parse_idl(_json: &str, _program_name: &str) -> Result<ProgramIdl> {
    todo!()
}

/// PascalCase on `_`/`-`/`.` boundaries: `pump_fun` → `PumpFun`,
/// `pumpfun` → `Pumpfun`.
pub fn program_name_from_filename(_file_stem: &str) -> String {
    todo!()
}
