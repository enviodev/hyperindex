use std::collections::{HashMap, HashSet};

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::NamedField as SvmNamedField;

use super::human_config;
use super::svm_idl::{IxIdl, ProgramIdl, Unusable};
use super::system_config::yaml_arg_to_named_field;

/// One positional account slot of a configured instruction.
#[derive(Debug, Clone, PartialEq)]
pub enum SvmAccountSlot {
    /// Holds a position without naming it: never surfaced to a handler, never
    /// filterable. The slots after it keep their positions.
    Unnamed,
    Required(String),
    /// Absent when the call carries no such slot, or fills it with the id of
    /// the program being invoked — the convention Anchor and Codama both use.
    Optional(String),
}

impl SvmAccountSlot {
    pub fn name(&self) -> Option<&str> {
        match self {
            Self::Unnamed => None,
            Self::Required(name) | Self::Optional(name) => Some(name),
        }
    }

    pub fn is_optional(&self) -> bool {
        matches!(self, Self::Optional(_))
    }
}

/// The canonical YAML token for a slot — the inverse of `parse_account_slots`.
impl std::fmt::Display for SvmAccountSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::Unnamed => f.write_str("_"),
            Self::Required(name) => f.write_str(name),
            Self::Optional(name) => write!(f, "?{name}"),
        }
    }
}

/// What one configured instruction dispatches on and decodes into.
pub struct ResolvedInstruction {
    /// `None` matches every instruction of the program.
    pub discriminator: Option<Vec<u8>>,
    pub accounts: Vec<SvmAccountSlot>,
    pub args: Vec<SvmNamedField>,
}

impl ResolvedInstruction {
    fn from_idl(ix: &IxIdl) -> Self {
        Self {
            discriminator: if ix.discriminator.is_empty() {
                None
            } else {
                Some(ix.discriminator.clone())
            },
            accounts: ix
                .accounts
                .iter()
                .map(|a| {
                    if a.optional {
                        SvmAccountSlot::Optional(a.name.clone())
                    } else {
                        SvmAccountSlot::Required(a.name.clone())
                    }
                })
                .collect(),
            args: ix.args.clone(),
        }
    }
}

/// The YAML slot grammar: `payer`, `?authority`, `_`.
fn parse_account_slots(tokens: &[human_config::svm::AccountSlot]) -> Result<Vec<SvmAccountSlot>> {
    let mut slots = Vec::with_capacity(tokens.len());
    for token in tokens {
        let text = token.0.as_str();
        slots.push(if text == "_" {
            SvmAccountSlot::Unnamed
        } else if let Some(name) = text.strip_prefix('?') {
            if name == "_" {
                bail!(
                    "account slot '?_' marks an unnamed slot optional, which nothing can \
                     observe. Write '_' to hold the position, or name the slot."
                );
            }
            SvmAccountSlot::Optional(account_name(name, text)?)
        } else {
            SvmAccountSlot::Required(account_name(text, text)?)
        });
    }
    if slots.last() == Some(&SvmAccountSlot::Unnamed) {
        bail!("the account list ends with '_', a position nothing follows. Drop it.");
    }
    let mut seen = HashSet::new();
    for name in slots.iter().filter_map(SvmAccountSlot::name) {
        if !seen.insert(name) {
            bail!("account '{name}' is declared more than once.");
        }
    }
    Ok(slots)
}

fn account_name(name: &str, token: &str) -> Result<String> {
    let readable = name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && name.chars().any(|c| c.is_ascii_alphabetic());
    if !readable {
        bail!(
            "account slot '{token}' is not a name: expected letters, digits and underscores, at \
             least one of them a letter. Prefix a name with '?' to mark the slot optional, or \
             write '_' to hold a position without naming it."
        );
    }
    Ok(name.to_string())
}

fn resolve_yaml_instruction(instr: &human_config::svm::Instruction) -> Result<ResolvedInstruction> {
    let discriminator = instr
        .discriminator
        .as_deref()
        .map(|d| crate::hex::decode_optionally_prefixed(d, "discriminator"))
        .transpose()?;
    let accounts = match &instr.accounts {
        Some(tokens) => parse_account_slots(tokens)?,
        None => Vec::new(),
    };
    let args = match &instr.args {
        Some(args) => args
            .iter()
            .map(yaml_arg_to_named_field)
            .collect::<Result<Vec<_>>>()?,
        None => Vec::new(),
    };
    Ok(ResolvedInstruction {
        discriminator,
        accounts,
        args,
    })
}

pub fn instruction_catalog(
    program: &human_config::svm::Program,
    idl: &ProgramIdl,
) -> Result<Vec<(String, ResolvedInstruction)>> {
    let mut catalog: Vec<(String, ResolvedInstruction)> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    let has_idl = program.idl.is_some();

    if has_idl {
        for (name, ix) in &idl.instructions {
            index.insert(name.clone(), catalog.len());
            catalog.push((name.clone(), ResolvedInstruction::from_idl(ix)));
        }
    }
    for instr in &program.instructions {
        let at_instruction = || format!("Program '{}', instruction '{}'", program.name, instr.name);
        if has_idl && instr.discriminator.is_none() {
            return Err(anyhow!(
                "a YAML row next to 'idl' must set 'discriminator' to overwrite the IDL \
                 definition, or omit this row."
            ))
            .with_context(at_instruction);
        }
        if has_idl && (instr.accounts.is_none() || instr.args.is_none()) {
            return Err(anyhow!(
                "set both 'accounts' and 'args' to overwrite the IDL layout."
            ))
            .with_context(at_instruction);
        }
        if !has_idl && instr.accounts.is_some() != instr.args.is_some() {
            return Err(anyhow!("set both 'accounts' and 'args', or omit both."))
                .with_context(at_instruction);
        }
        let resolved = resolve_yaml_instruction(instr).with_context(at_instruction)?;
        if let Some(&i) = index.get(&instr.name) {
            catalog[i] = (instr.name.clone(), resolved);
        } else {
            index.insert(instr.name.clone(), catalog.len());
            catalog.push((instr.name.clone(), resolved));
        }
    }

    Ok(catalog)
}

pub fn warn_about_unindexable(program: &human_config::svm::Program, unusable: &Unusable) {
    let yaml_names: HashSet<&str> = program
        .instructions
        .iter()
        .map(|i| i.name.as_str())
        .collect();
    for (name, reason) in unusable {
        if yaml_names.contains(name.as_str()) {
            continue;
        }
        eprintln!(
            "Warning: program '{}' will not index '{name}' from the IDL: {reason}",
            program.name
        );
    }
}
