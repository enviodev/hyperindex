use alloy_dyn_abi::{DecodedEvent, DynSolValue};
use napi_derive::napi;

use std::sync::Arc;

use crate::hex::to_hex;
use crate::js_value::JsTape;
use crate::storage::rows::ReadKind;

#[napi(object)]
#[derive(Clone)]
pub struct ParamMeta {
    pub name: String,
    pub abi_type: String,
    pub indexed: bool,
    pub components: Option<Vec<ParamMeta>>,
}

/// The full per-(event, chain) registration crossing the boundary once at
/// client construction: decode metadata (`sighash`/`topic_count`/`params`),
/// matching identity (`id`/`contract_name`/`is_wildcard`), and the fetch state
/// queries are built from (`topic_filters`, field selections).
#[napi(object)]
pub struct OnEventRegistrationInput {
    /// Chain-scoped sequential registration index; returned on every matched
    /// item so JS resolves the registration by array index.
    pub index: i64,
    /// The event's topic0; absent for an anonymous event, whose topic0 is its
    /// first indexed param.
    pub sighash: Option<String>,
    pub topic_count: i32,
    pub event_name: String,
    pub contract_name: String,
    pub is_wildcard: bool,
    /// Whether the query for this event must be scoped to (or derived from)
    /// the contract's registered addresses.
    pub depends_on_addresses: bool,
    /// Earliest block this registration accepts; absent is unrestricted. See
    /// `crate::registration_start_block`.
    pub start_block: Option<i64>,
    pub params: Vec<ParamMeta>,
    /// The registration's resolved `where` in disjunctive normal form (outer
    /// array is OR), topic0 included. Empty means the event is never fetched.
    pub topic_filters: Vec<crate::ecosystems::evm::topic_filter::TopicFilterInput>,
    /// Block fields this event's handler reads (HyperSync field selection).
    pub block_fields: Vec<crate::ecosystems::evm::fields::BlockField>,
    /// Transaction fields this event's handler reads (HyperSync field
    /// selection).
    pub transaction_fields: Vec<crate::ecosystems::evm::fields::TransactionField>,
}

/// How one registration's params reach JS: their names and ABI shapes, and
/// the column each becomes in a batch.
pub(crate) struct ParamSchema {
    pub(crate) params: Vec<ParamMeta>,
    pub(crate) kinds: Vec<ReadKind>,
    pub(crate) checksummed_addresses: bool,
}

impl ParamSchema {
    pub(crate) fn new(params: Vec<ParamMeta>, checksummed_addresses: bool) -> Self {
        let kinds = params.iter().map(param_read_kind).collect();
        ParamSchema {
            params,
            kinds,
            checksummed_addresses,
        }
    }
}

/// A flat param is a column of its own; an array or a tuple travels as a tape.
fn param_read_kind(param: &ParamMeta) -> ReadKind {
    let abi_type = param.abi_type.as_str();
    if abi_type.ends_with(']') || abi_type.starts_with('(') || abi_type.starts_with("tuple") {
        ReadKind::Tape
    } else if abi_type == "bool" {
        ReadKind::Bool
    } else if abi_type.starts_with("uint") || abi_type.starts_with("int") {
        ReadKind::BigInt
    } else {
        ReadKind::Text
    }
}

/// One param as the cell its column holds, formatted when the log is decoded,
/// off the JS thread, so laying a batch out only copies bytes.
#[derive(Clone)]
pub(crate) enum ParamCell {
    Bool(bool),
    /// A string, or a decimal integer where the column reads a bigint.
    Text(Box<str>),
    /// An array or a tuple.
    Tape(JsTape),
}

/// A decoded event's params in declaration order, whether each came from a
/// topic or the body.
#[derive(Clone)]
pub(crate) struct EvmParams {
    pub(crate) cells: Vec<ParamCell>,
    pub(crate) schema: Arc<ParamSchema>,
}

impl EvmParams {
    /// `None` when the decoded values don't line up with the schema's params.
    pub(crate) fn from_decoded(decoded: DecodedEvent, schema: &Arc<ParamSchema>) -> Option<Self> {
        let mut indexed = decoded.indexed.into_iter();
        let mut body = decoded.body.into_iter();
        let cells = schema
            .params
            .iter()
            .zip(&schema.kinds)
            .map(|(param, kind)| {
                let value = if param.indexed {
                    indexed.next()
                } else {
                    body.next()
                }?;
                param_cell(&value, param, *kind, schema.checksummed_addresses)
            })
            .collect::<Option<Vec<_>>>()?;
        Some(EvmParams {
            cells,
            schema: schema.clone(),
        })
    }

    /// The params as one object keyed by param name.
    #[cfg(test)]
    pub(crate) fn to_tape(&self) -> JsTape {
        use alloy_primitives::{I256, U256};
        let mut tape = JsTape::new();
        tape.obj(self.cells.len());
        for ((cell, param), kind) in self
            .cells
            .iter()
            .zip(&self.schema.params)
            .zip(&self.schema.kinds)
        {
            tape.key(&param.name);
            match cell {
                ParamCell::Bool(value) => tape.bool(*value),
                ParamCell::Text(value) if *kind != ReadKind::BigInt => tape.str(value),
                ParamCell::Text(value) => {
                    let (sign, magnitude) = I256::from_dec_str(value)
                        .map(|value| value.into_sign_and_abs())
                        .unwrap_or_else(|_| {
                            (
                                alloy_primitives::Sign::Positive,
                                U256::from_str_radix(value, 10).unwrap(),
                            )
                        });
                    tape.bigint(sign.is_negative(), magnitude.as_limbs());
                }
                ParamCell::Tape(nested) => tape.embed(nested),
            }
        }
        tape
    }
}

/// `None` when a value doesn't have the shape its ABI type gave the column,
/// which the decoder, built from the same types, doesn't produce.
fn param_cell(
    value: &DynSolValue,
    param: &ParamMeta,
    kind: ReadKind,
    checksummed_addresses: bool,
) -> Option<ParamCell> {
    let text = |text: String| Some(ParamCell::Text(text.into()));
    match (kind, value) {
        (ReadKind::Tape, value) => {
            let mut tape = JsTape::new();
            write_sol_value(
                &mut tape,
                value,
                param.components.as_deref(),
                checksummed_addresses,
            );
            Some(ParamCell::Tape(tape))
        }
        (ReadKind::Bool, DynSolValue::Bool(value)) => Some(ParamCell::Bool(*value)),
        (ReadKind::BigInt, DynSolValue::Uint(value, _)) => text(value.to_string()),
        (ReadKind::BigInt, DynSolValue::Int(value, _)) => text(value.to_string()),
        (ReadKind::Text, DynSolValue::Address(address)) if checksummed_addresses => {
            text(address.to_checksum_buffer(None).as_str().to_owned())
        }
        (ReadKind::Text, DynSolValue::Address(address)) => text(to_hex(address.as_slice())),
        (ReadKind::Text, DynSolValue::FixedBytes(word, size)) => text(to_hex(&word[..*size])),
        (ReadKind::Text, DynSolValue::Function(function)) => text(to_hex(function.as_slice())),
        (ReadKind::Text, DynSolValue::Bytes(bytes)) => text(to_hex(bytes)),
        (ReadKind::Text, DynSolValue::String(value)) => text(value.clone()),
        _ => None,
    }
}

/// A tuple with `components` becomes an object keyed by component name; an
/// array passes them on to its elements. Without them a tuple is an array.
fn write_sol_value(
    tape: &mut JsTape,
    value: &DynSolValue,
    components: Option<&[ParamMeta]>,
    checksummed_addresses: bool,
) {
    match value {
        DynSolValue::Tuple(values) => match components {
            Some(components) => {
                tape.obj(values.len().min(components.len()));
                for (value, component) in values.iter().zip(components) {
                    tape.key(&component.name);
                    write_sol_value(
                        tape,
                        value,
                        component.components.as_deref(),
                        checksummed_addresses,
                    );
                }
            }
            None => {
                tape.arr(values.len());
                for value in values {
                    write_sol_value(tape, value, None, checksummed_addresses);
                }
            }
        },
        DynSolValue::Array(values) | DynSolValue::FixedArray(values) => {
            tape.arr(values.len());
            for value in values {
                write_sol_value(tape, value, components, checksummed_addresses);
            }
        }
        DynSolValue::Bool(value) => tape.bool(*value),
        DynSolValue::Int(value, _) => {
            let (sign, magnitude) = value.into_sign_and_abs();
            tape.bigint(sign.is_negative(), magnitude.as_limbs());
        }
        DynSolValue::Uint(value, _) => tape.bigint(false, value.as_limbs()),
        DynSolValue::Address(address) if checksummed_addresses => {
            tape.str(address.to_checksum_buffer(None).as_str())
        }
        DynSolValue::Address(address) => tape.hex(address.as_slice()),
        DynSolValue::FixedBytes(word, size) => tape.hex(&word[..*size]),
        DynSolValue::Function(function) => tape.hex(function.as_slice()),
        DynSolValue::Bytes(bytes) => tape.hex(bytes),
        DynSolValue::String(value) => tape.str(value),
    }
}
