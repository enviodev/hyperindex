use std::collections::{HashMap, HashSet};

use anyhow::{anyhow, Context, Result};
use hypersync_client_solana::decode::NamedField as SvmNamedField;

use super::human_config;
use super::svm_idl::{IxIdl, ProgramIdl, Unusable};
use super::system_config::yaml_arg_to_named_field;

/// What one configured instruction dispatches on and decodes into.
pub struct ResolvedInstruction {
    /// `None` matches every instruction of the program.
    pub discriminator: Option<Vec<u8>>,
    pub accounts: Vec<String>,
    pub args: Vec<SvmNamedField>,
}

impl ResolvedInstruction {
    fn from_idl(ix: &IxIdl) -> Self {
        Self {
            discriminator: Some(ix.discriminator.clone()),
            accounts: ix.accounts.iter().map(|a| a.name.clone()).collect(),
            args: ix.args.clone(),
        }
    }
}

fn resolve_yaml_instruction(instr: &human_config::svm::Instruction) -> Result<ResolvedInstruction> {
    let discriminator = instr
        .discriminator
        .as_deref()
        .map(|d| crate::hex::decode_optionally_prefixed(d, "discriminator"))
        .transpose()?;
    let accounts = instr.accounts.clone().unwrap_or_default();
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
