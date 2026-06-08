//! Borsh instruction decoder bridge.
//!
//! `register_program_schema` deserialises a JSON descriptor produced by
//! `public_config.rs` into an upstream `ProgramSchema` and stashes it in a
//! process-global table keyed by a stable `u32` index. The Solana client's
//! `get` then passes those indices back on the query; `decode_with_schema`
//! resolves each one via `schema_for_handle` and decodes the matching
//! instructions inline, so the `DecodedInstruction` shape rides back on the
//! query response instead of crossing the napi boundary one call at a time.
//!
//! Lifecycle: schemas are registered once per program at indexer startup
//! and never freed. The process-global `Vec<Arc<ProgramSchema>>` is fine
//! because the registry is fixed for the life of the indexer; no churn, no
//! lifetime puzzle.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock};

use anyhow::{Context, Result};
use serde::Deserialize;

use hypersync_client_solana::decode::{
    decode_instruction as upstream_decode, DecodedInstruction as UpstreamDecoded,
    EnumVariant as UpstreamEnumVariant, FieldType as SvmFieldType,
    InstructionSchema as UpstreamIxSchema, NamedAccount as UpstreamAccount,
    NamedField as UpstreamNamedField, ProgramSchema as UpstreamSchema,
};
use hypersync_client_solana::simple_types::Instruction as UpstreamInstruction;

use crate::config_parsing::human_config::svm::{ArgComposite, ArgDef, ArgPrimitive, ArgType};

use super::mod_helpers::hex_to_bytes;

/// Wire-format descriptor sent from the ReScript runtime at startup. Mirrors
/// the JSON shape emitted by `public_config::SvmAbiJson` plus the per-program
/// instruction list (which the runtime reconstructs from each event's
/// `svm.discriminator`/`svm.accounts`/`svm.args`).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgramSchemaJson {
    pub program_id: String,
    #[serde(default)]
    pub defined_types: BTreeMap<String, ArgType>,
    pub instructions: Vec<InstructionSchemaJson>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstructionSchemaJson {
    pub name: String,
    /// Hex (`0x`-prefixed or bare) — the bytes the dispatcher matches against
    /// the head of `instruction.data`.
    pub discriminator: String,
    #[serde(default)]
    pub accounts: Vec<String>,
    #[serde(default)]
    pub args: Vec<ArgDef>,
}

static REGISTRY: OnceLock<Mutex<Vec<Arc<UpstreamSchema>>>> = OnceLock::new();

fn registry() -> &'static Mutex<Vec<Arc<UpstreamSchema>>> {
    REGISTRY.get_or_init(|| Mutex::new(Vec::new()))
}

/// Register a program's Borsh schema. Returns a stable index the runtime
/// hands back to `decode_instruction`. Indices are append-only; the registry
/// is not cleared between indexer restarts within the same node process.
#[napi_derive::napi]
#[allow(dead_code)]
pub fn register_program_schema(descriptor_json: String) -> napi::Result<u32> {
    let descriptor: ProgramSchemaJson = serde_json::from_str(&descriptor_json)
        .context("parse program schema descriptor")
        .map_err(super::map_err)?;

    let schema = build_program_schema(descriptor)
        .context("build program schema")
        .map_err(super::map_err)?;

    let mut guard = registry()
        .lock()
        .expect("schema registry mutex poisoned (decoder panicked while holding it)");
    let idx = guard.len() as u32;
    guard.push(Arc::new(schema));
    Ok(idx)
}

/// Look up a registered schema by its handle. `None` when the handle was never
/// registered (defensive — the runtime always registers before querying).
pub(crate) fn schema_for_handle(schema_handle: u32) -> Option<Arc<UpstreamSchema>> {
    registry()
        .lock()
        .expect("schema registry mutex poisoned (decoder panicked while holding it)")
        .get(schema_handle as usize)
        .map(Arc::clone)
}

/// Decode a raw instruction against a resolved schema. Called inline by the
/// Solana client's `get`, so decoded instructions ride back on the query
/// response instead of crossing the napi boundary one instruction at a time.
///
/// POC policy: any decode failure (unknown discriminator, account-count
/// mismatch, trailing bytes, unresolved type) yields `None` so the indexer
/// keeps running. Real on-chain calls drift from schemas in small ways
/// (Metaplex `rent` slot was optional in some versions, etc.); a single bad
/// row should not kill the worker.
pub(crate) fn decode_with_schema(
    schema: &UpstreamSchema,
    accounts: Vec<String>,
    data: Vec<u8>,
) -> Option<DecodedInstructionJson> {
    let ix = UpstreamInstruction {
        program_id: schema.program_id.clone(),
        accounts,
        data,
        ..Default::default()
    };
    upstream_decode(schema, &ix).ok().map(Into::into)
}

/// JS-facing shape of `DecodedInstruction`. Args + named accounts are passed
/// as JSON strings to side-step napi-rs's lack of native `serde_json::Value`
/// support; the runtime `JSON.parse`s them once into the per-handler shape.
#[napi_derive::napi(object)]
#[derive(Clone)]
pub struct DecodedInstructionJson {
    pub name: String,
    /// `JSON.stringify`-able args object. Always a JSON object literal even
    /// when the instruction has no args (`{}`).
    pub args_json: String,
    /// `JSON.stringify`-able `Record<string, string>` of named accounts.
    pub accounts_json: String,
    /// Accounts beyond the schema's named list. Empty when counts match.
    pub extra_accounts: Vec<String>,
}

impl From<UpstreamDecoded> for DecodedInstructionJson {
    fn from(d: UpstreamDecoded) -> Self {
        let args_json = serde_json::to_string(&d.args).unwrap_or_else(|_| "{}".to_string());
        let accounts_json =
            serde_json::to_string(&d.named_accounts).unwrap_or_else(|_| "{}".to_string());
        DecodedInstructionJson {
            name: d.name,
            args_json,
            accounts_json,
            extra_accounts: d.extra_accounts,
        }
    }
}

fn build_program_schema(d: ProgramSchemaJson) -> Result<UpstreamSchema> {
    let defined_types: BTreeMap<String, SvmFieldType> = d
        .defined_types
        .iter()
        .map(|(name, ty)| {
            arg_type_to_field_type(ty)
                .map(|ft| (name.clone(), ft))
                .with_context(|| format!("translating defined type '{name}'"))
        })
        .collect::<Result<_>>()?;

    let mut instructions: BTreeMap<Vec<u8>, UpstreamIxSchema> = BTreeMap::new();
    for ix in d.instructions {
        let discriminator = hex_to_bytes(&ix.discriminator)
            .with_context(|| format!("instruction '{}' discriminator", ix.name))?;
        let accounts = ix
            .accounts
            .into_iter()
            .map(|name| UpstreamAccount {
                name,
                writable: false,
                signer: false,
                // The wire format drops per-account writable/signer/optional
                // flags. Marking every account as `optional` lets the upstream
                // `required_account_count` rule accept *any* trailing tail,
                // matching real-world callers that omit sysvar slots.
                // Real-world surplus accounts still go to `extra_accounts`.
                optional: true,
            })
            .collect();
        let args = ix
            .args
            .into_iter()
            .map(|a| {
                Ok(UpstreamNamedField {
                    name: a.name.clone(),
                    ty: arg_type_to_field_type(&a.ty)
                        .with_context(|| format!("translating arg '{}'", a.name))?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        instructions.insert(
            discriminator.clone(),
            UpstreamIxSchema {
                name: ix.name,
                discriminator,
                accounts,
                args,
            },
        );
    }

    Ok(UpstreamSchema::build(
        d.program_id,
        instructions,
        defined_types,
    ))
}

fn arg_type_to_field_type(ty: &ArgType) -> Result<SvmFieldType> {
    Ok(match ty {
        ArgType::Primitive(p) => match p {
            ArgPrimitive::Bool => SvmFieldType::Bool,
            ArgPrimitive::U8 => SvmFieldType::U8,
            ArgPrimitive::U16 => SvmFieldType::U16,
            ArgPrimitive::U32 => SvmFieldType::U32,
            ArgPrimitive::U64 => SvmFieldType::U64,
            ArgPrimitive::U128 => SvmFieldType::U128,
            ArgPrimitive::I8 => SvmFieldType::I8,
            ArgPrimitive::I16 => SvmFieldType::I16,
            ArgPrimitive::I32 => SvmFieldType::I32,
            ArgPrimitive::I64 => SvmFieldType::I64,
            ArgPrimitive::I128 => SvmFieldType::I128,
            ArgPrimitive::F32 => SvmFieldType::F32,
            ArgPrimitive::F64 => SvmFieldType::F64,
            ArgPrimitive::String => SvmFieldType::String,
            ArgPrimitive::Bytes => SvmFieldType::Bytes,
            ArgPrimitive::Pubkey | ArgPrimitive::PublicKey => SvmFieldType::Pubkey,
        },
        ArgType::Composite(c) => match c {
            ArgComposite::Option(inner) => {
                SvmFieldType::Option(Box::new(arg_type_to_field_type(inner)?))
            }
            ArgComposite::Vec(inner) => SvmFieldType::Vec(Box::new(arg_type_to_field_type(inner)?)),
            ArgComposite::Array(inner, len) => SvmFieldType::Array {
                ty: Box::new(arg_type_to_field_type(inner)?),
                len: *len,
            },
            ArgComposite::Defined(name) => SvmFieldType::Defined(name.clone()),
            ArgComposite::Struct(fields) => SvmFieldType::Struct(
                fields
                    .iter()
                    .map(|f| {
                        Ok(UpstreamNamedField {
                            name: f.name.clone(),
                            ty: arg_type_to_field_type(&f.ty)
                                .with_context(|| format!("struct field '{}'", f.name))?,
                        })
                    })
                    .collect::<Result<_>>()?,
            ),
            ArgComposite::Enum(variants) => SvmFieldType::Enum(
                variants
                    .iter()
                    .map(|v| {
                        let fields = v
                            .fields
                            .as_ref()
                            .map(|fs| {
                                fs.iter()
                                    .map(|f| {
                                        Ok(UpstreamNamedField {
                                            name: f.name.clone(),
                                            ty: arg_type_to_field_type(&f.ty).with_context(
                                                || format!("enum field '{}'", f.name),
                                            )?,
                                        })
                                    })
                                    .collect::<Result<_>>()
                            })
                            .transpose()?;
                        Ok(UpstreamEnumVariant {
                            name: v.name.clone(),
                            fields,
                        })
                    })
                    .collect::<Result<_>>()?,
            ),
        },
    })
}
