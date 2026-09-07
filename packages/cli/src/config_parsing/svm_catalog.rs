use std::collections::{HashMap, HashSet};

use anyhow::{anyhow, bail, Context, Result};
use hypersync_client_solana::decode::NamedField as SvmNamedField;

use super::human_config::{self, svm::AccountSlot};
use super::svm_idl::{IxIdl, ProgramIdl, Unusable};
use super::system_config::yaml_arg_to_named_field;
use super::validation::validate_svm_args;

/// What one configured instruction dispatches on and decodes into.
pub struct ResolvedInstruction {
    /// `None` matches every instruction of the program.
    pub discriminator: Option<Vec<u8>>,
    pub accounts: Vec<AccountSlot>,
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
                        AccountSlot::Optional(a.name.clone())
                    } else {
                        AccountSlot::Required(a.name.clone())
                    }
                })
                .collect(),
            args: ix.args.clone(),
        }
    }
}

fn validate_account_slots(slots: &[AccountSlot]) -> Result<()> {
    if slots.last() == Some(&AccountSlot::Unnamed) {
        bail!("the account list ends with '_', a position nothing follows. Drop it.");
    }
    let mut seen = HashSet::new();
    for name in slots.iter().filter_map(AccountSlot::name) {
        if !seen.insert(name) {
            bail!("account '{name}' is declared more than once.");
        }
    }
    Ok(())
}

fn resolve_yaml_instruction(instr: &human_config::svm::Instruction) -> Result<ResolvedInstruction> {
    let discriminator = instr
        .discriminator
        .as_deref()
        .map(|d| crate::hex::decode_optionally_prefixed(d, "discriminator"))
        .transpose()?;
    let accounts = instr.accounts.clone().unwrap_or_default();
    validate_account_slots(&accounts)?;
    let args = match &instr.args {
        Some(args) => {
            validate_svm_args(args)?;
            args.iter()
                .map(yaml_arg_to_named_field)
                .collect::<Result<Vec<_>>>()?
        }
        None => Vec::new(),
    };
    Ok(ResolvedInstruction {
        discriminator,
        accounts,
        args,
    })
}

/// What a row on a name the IDL declares still has to spell out, as the error
/// the caller reports. `None` when the row is not an overwrite, or is complete.
/// `discriminator` is not among them: absent, it means what it means anywhere
/// else, a match on every instruction of the program.
fn overwrite_missing_fields(
    instr: &human_config::svm::Instruction,
    idl: &ProgramIdl,
) -> Option<anyhow::Error> {
    let set_aside = idl.unusable.get(&instr.name);
    if set_aside.is_none() && !idl.instructions.contains_key(&instr.name) {
        return None;
    }
    let missing = match (instr.accounts.is_none(), instr.args.is_none()) {
        (false, false) => return None,
        (true, false) => "'accounts'",
        (false, true) => "'args'",
        (true, true) => "'accounts' and 'args'",
    };
    let declared = match set_aside {
        Some(reason) => format!(
            "the IDL declares this instruction too, but it cannot be indexed as declared: {reason}"
        ),
        None => "the IDL declares this instruction too, so this row replaces it rather than \
                 adding to the catalog"
            .to_string(),
    };
    Some(anyhow!(
        "{declared}. Spell out {missing}: an overwrite takes nothing from the IDL, so a field \
         left out here is absent, not inherited."
    ))
}

pub fn instruction_catalog(
    program: &human_config::svm::Program,
    idl: &ProgramIdl,
) -> Result<Vec<(String, ResolvedInstruction)>> {
    let mut catalog: Vec<(String, ResolvedInstruction)> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();

    for (name, ix) in &idl.instructions {
        index.insert(name.clone(), catalog.len());
        catalog.push((name.clone(), ResolvedInstruction::from_idl(ix)));
    }
    for instr in &program.instructions {
        let at_instruction = || format!("Program '{}', instruction '{}'", program.name, instr.name);
        // A row on a name the IDL declares replaces that instruction whole, so
        // the fields it leaves out would read as absent rather than as the
        // IDL's. A name the IDL was seen to declare but this runtime set aside
        // counts the same: the row is answering that reason, not adding a
        // program-wide catch-all under a name that looks like it selects one
        // instruction.
        if let Some(missing) = overwrite_missing_fields(instr, idl) {
            return Err(missing).with_context(at_instruction);
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
