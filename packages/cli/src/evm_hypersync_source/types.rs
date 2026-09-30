use std::sync::Arc;

use alloy_dyn_abi::{DecodedEvent, DynSolValue};
use alloy_primitives::U256;
use anyhow::{Context, Result};
use hypersync_client::{
    format::{self, FixedSizeData, Hex},
    net_types, simple_types,
};
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;

use crate::js_value::{Emit, Sink};

/// Evm log object
///
/// See ethereum rpc spec for the meaning of fields
#[napi(object)]
#[derive(Default, Clone)]
pub struct Log {
    pub removed: Option<bool>,
    pub log_index: Option<i64>,
    pub transaction_index: Option<i64>,
    pub transaction_hash: Option<String>,
    pub block_hash: Option<String>,
    pub block_number: Option<i64>,
    pub address: Option<String>,
    pub data: Option<String>,
    pub topics: Vec<Option<String>>,
}

/// Evm withdrawal object
///
/// See ethereum rpc spec for the meaning of fields
#[napi(object)]
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Withdrawal {
    pub index: Option<String>,
    pub validator_index: Option<String>,
    pub address: Option<String>,
    pub amount: Option<String>,
}

impl From<&format::Withdrawal> for Withdrawal {
    fn from(w: &format::Withdrawal) -> Self {
        Self {
            index: map_hex_string(&w.index),
            validator_index: map_hex_string(&w.validator_index),
            address: map_hex_string(&w.address),
            amount: map_hex_string(&w.amount),
        }
    }
}

/// Evm access list object
///
/// See ethereum rpc spec for the meaning of fields
#[napi(object)]
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct AccessList {
    pub address: Option<String>,
    pub storage_keys: Option<Vec<String>>,
}

impl From<&format::AccessList> for AccessList {
    fn from(a: &format::AccessList) -> Self {
        Self {
            address: map_hex_string(&a.address),
            storage_keys: a
                .storage_keys
                .as_ref()
                .map(|arr| arr.iter().map(|x| x.encode_hex()).collect()),
        }
    }
}

/// Evm authorization object
///
/// See ethereum rpc spec for the meaning of fields
#[napi(object)]
#[derive(Debug, Clone)]
pub struct Authorization {
    /// uint256
    pub chain_id: BigInt,
    /// 20-byte hex
    pub address: String,
    /// uint64
    pub nonce: i64,
    /// 0 | 1
    pub y_parity: i64,
    /// 32-byte hex
    pub r: String,
    /// 32-byte hex
    pub s: String,
}

impl TryFrom<&format::Authorization> for Authorization {
    type Error = anyhow::Error;

    fn try_from(a: &format::Authorization) -> Result<Self> {
        Ok(Self {
            chain_id: convert_bigint_unsigned(
                ruint::aliases::U256::try_from_be_slice(&a.chain_id)
                    .context("convert authorization chain_id bytes to U256")?,
            ),
            address: a.address.encode_hex(),
            nonce: alloy_primitives::I64::try_from_be_slice(&a.nonce)
                .context("convert authorization nonce bytes to I64")?
                .as_i64(),
            y_parity: alloy_primitives::I64::try_from_be_slice(&a.y_parity)
                .context("convert authorization y_parity bytes to I64")?
                .as_i64(),
            r: a.r.encode_hex(),
            s: a.s.encode_hex(),
        })
    }
}

/// Evm block header object
///
/// See ethereum rpc spec for the meaning of fields
#[napi(object)]
#[derive(Default, Clone)]
pub struct Block {
    pub number: Option<i64>,
    pub hash: Option<String>,
    pub parent_hash: Option<String>,
    pub nonce: Option<BigInt>,
    pub sha3_uncles: Option<String>,
    pub logs_bloom: Option<String>,
    pub transactions_root: Option<String>,
    pub state_root: Option<String>,
    pub receipts_root: Option<String>,
    pub miner: Option<String>,
    pub difficulty: Option<BigInt>,
    pub total_difficulty: Option<BigInt>,
    pub extra_data: Option<String>,
    pub size: Option<BigInt>,
    pub gas_limit: Option<BigInt>,
    pub gas_used: Option<BigInt>,
    pub timestamp: Option<i64>,
    pub uncles: Option<Vec<String>>,
    pub base_fee_per_gas: Option<BigInt>,
    pub blob_gas_used: Option<BigInt>,
    pub excess_blob_gas: Option<BigInt>,
    pub parent_beacon_block_root: Option<String>,
    pub withdrawals_root: Option<String>,
    pub withdrawals: Option<Vec<Withdrawal>>,
    pub l1_block_number: Option<i64>,
    pub send_count: Option<String>,
    pub send_root: Option<String>,
    pub mix_hash: Option<String>,
}

pub(crate) fn map_address_string(
    v: &Option<FixedSizeData<20>>,
    should_checksum: bool,
) -> Option<String> {
    v.as_ref().map(|v| encode_address(v, should_checksum))
}

pub(crate) fn encode_address(addr: &FixedSizeData<20>, should_checksum: bool) -> String {
    if should_checksum {
        alloy_primitives::Address(alloy_primitives::FixedBytes(***addr)).to_checksum(None)
    } else {
        addr.encode_hex()
    }
}

pub(crate) fn map_hex_string<T: Hex>(v: &Option<T>) -> Option<String> {
    v.as_ref().map(|v| v.encode_hex())
}

pub(crate) fn map_i64<T: AsRef<[u8]>>(opt: &Option<T>) -> Result<Option<i64>> {
    opt.as_ref()
        .map(|v| {
            i64::try_from(ruint::aliases::U256::from_be_slice(v.as_ref()))
                .context("converting U256 to i64")
        })
        .transpose()
}

pub(crate) fn map_bigint<T: AsRef<[u8]>>(opt: &Option<T>) -> Option<BigInt> {
    opt.as_ref()
        .map(|v| convert_bigint_unsigned(ruint::aliases::U256::from_be_slice(v.as_ref())))
}

impl Block {
    pub fn from_simple(b: &simple_types::Block, should_checksum: bool) -> Result<Self> {
        Ok(Self {
            number: b
                .number
                .map(i64::try_from)
                .transpose()
                .context("mapping block.number")?,
            hash: map_hex_string(&b.hash),
            parent_hash: map_hex_string(&b.parent_hash),
            nonce: map_bigint(&b.nonce),
            sha3_uncles: map_hex_string(&b.sha3_uncles),
            logs_bloom: map_hex_string(&b.logs_bloom),
            transactions_root: map_hex_string(&b.transactions_root),
            state_root: map_hex_string(&b.state_root),
            receipts_root: map_hex_string(&b.receipts_root),
            miner: map_address_string(&b.miner, should_checksum),
            difficulty: map_bigint(&b.difficulty),
            total_difficulty: map_bigint(&b.total_difficulty),
            extra_data: map_hex_string(&b.extra_data),
            size: map_bigint(&b.size),
            gas_limit: map_bigint(&b.gas_limit),
            gas_used: map_bigint(&b.gas_used),
            timestamp: map_i64(&b.timestamp).context("mapping block.timestamp")?,
            uncles: b
                .uncles
                .as_ref()
                .map(|arr| arr.iter().map(|u| u.encode_hex()).collect()),
            base_fee_per_gas: map_bigint(&b.base_fee_per_gas),
            blob_gas_used: map_bigint(&b.blob_gas_used),
            excess_blob_gas: map_bigint(&b.excess_blob_gas),
            parent_beacon_block_root: map_hex_string(&b.parent_beacon_block_root),
            withdrawals_root: map_hex_string(&b.withdrawals_root),
            withdrawals: b
                .withdrawals
                .as_ref()
                .map(|w| w.iter().map(Withdrawal::from).collect()),
            l1_block_number: b
                .l1_block_number
                .map(|n| u64::from(n).try_into())
                .transpose()
                .context("mapping l1_block_number")?,
            send_count: map_hex_string(&b.send_count),
            send_root: map_hex_string(&b.send_root),
            mix_hash: map_hex_string(&b.mix_hash),
        })
    }
}

#[napi(object)]
pub struct RollbackGuard {
    /// Block number of the last scanned block
    pub block_number: i64,
    /// Block timestamp of the last scanned block
    pub timestamp: i64,
    /// Block hash of the last scanned block
    pub hash: String,
    /// Block number of the first scanned block in memory.
    ///
    /// This might not be the first scanned block. It only includes blocks that are in memory (possible to be rolled back).
    pub first_block_number: i64,
    /// Parent hash of the first scanned block in memory.
    ///
    /// This might not be the first scanned block. It only includes blocks that are in memory (possible to be rolled back).
    pub first_parent_hash: String,
}

impl TryFrom<net_types::RollbackGuard> for RollbackGuard {
    type Error = anyhow::Error;

    fn try_from(arg: net_types::RollbackGuard) -> Result<Self> {
        Ok(Self {
            block_number: arg
                .block_number
                .try_into()
                .context("convert block_number")?,
            timestamp: arg.timestamp,
            hash: arg.hash.encode_hex(),
            first_block_number: arg
                .first_block_number
                .try_into()
                .context("convert first_block_number")?,
            first_parent_hash: arg.first_parent_hash.encode_hex(),
        })
    }
}

// ============== New decoder types ==============

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
/// routing identity (`id`/`contract_name`/`is_wildcard`), and the fetch state
/// queries are built from (`topic_selections`, field selections).
#[napi(object)]
pub struct OnEventRegistrationInput {
    /// Chain-scoped sequential registration index; returned on every routed
    /// item so JS resolves the registration by array index.
    pub index: i64,
    pub sighash: String,
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
    /// array is OR). Empty means the event is never fetched.
    pub topic_selections: Vec<crate::evm_hypersync_source::selection::TopicSelectionInput>,
    /// Block fields this event's handler reads (HyperSync field selection).
    pub block_fields: Vec<crate::evm_hypersync_source::query::BlockField>,
    /// Transaction fields this event's handler reads (HyperSync field
    /// selection).
    pub transaction_fields: Vec<crate::evm_hypersync_source::query::TransactionField>,
}

/// A decoded event's params, emitted as one object keyed by param name in
/// declaration order, whether each came from a topic or the body.
pub struct EventParams {
    pub params: Arc<[ParamMeta]>,
    pub decoded: DecodedEvent,
    pub checksummed_addresses: bool,
}

impl Emit for EventParams {
    fn emit<S: Sink>(&self, sink: &mut S) -> Option<S::Value> {
        let mut indexed = self.decoded.indexed.iter();
        let mut body = self.decoded.body.iter();
        let mut obj = sink.obj()?;
        for param in self.params.iter() {
            let value = if param.indexed {
                indexed.next()
            } else {
                body.next()
            }?;
            let value = emit_sol_value(
                value,
                param.components.as_deref(),
                self.checksummed_addresses,
                sink,
            )?;
            sink.set(&mut obj, &param.name, value)?;
        }
        Some(sink.end_obj(obj))
    }
}

/// A tuple with `components` becomes an object keyed by component name; an
/// array passes them on to its elements. Without them a tuple is an array.
fn emit_sol_value<S: Sink>(
    value: &DynSolValue,
    components: Option<&[ParamMeta]>,
    checksummed_addresses: bool,
    sink: &mut S,
) -> Option<S::Value> {
    let seq = |values: &[DynSolValue], components, sink: &mut S| {
        let mut arr = sink.arr(values.len())?;
        for value in values {
            let value = emit_sol_value(value, components, checksummed_addresses, sink)?;
            sink.push(&mut arr, value)?;
        }
        Some(sink.end_arr(arr))
    };
    match value {
        DynSolValue::Tuple(values) => match components {
            Some(components) => {
                let mut obj = sink.obj()?;
                for (value, component) in values.iter().zip(components) {
                    let value = emit_sol_value(
                        value,
                        component.components.as_deref(),
                        checksummed_addresses,
                        sink,
                    )?;
                    sink.set(&mut obj, &component.name, value)?;
                }
                Some(sink.end_obj(obj))
            }
            None => seq(values, None, sink),
        },
        DynSolValue::Array(values) | DynSolValue::FixedArray(values) => {
            seq(values, components, sink)
        }
        DynSolValue::Bool(value) => sink.bool(*value),
        DynSolValue::Int(value, _) => {
            let (sign, magnitude) = value.into_sign_and_abs();
            sink.bigint(sign.is_negative(), magnitude.as_limbs())
        }
        DynSolValue::Uint(value, _) => sink.bigint(false, value.as_limbs()),
        DynSolValue::Address(address) if checksummed_addresses => emit_checksummed(address, sink),
        DynSolValue::Address(address) => sink.hex(address.as_slice()),
        DynSolValue::FixedBytes(word, _) => sink.hex(word.as_slice()),
        DynSolValue::Function(function) => sink.hex(function.as_slice()),
        DynSolValue::Bytes(bytes) => sink.hex(bytes),
        DynSolValue::String(value) => sink.str(value),
    }
}

// Kept out of `emit_sol_value` so the checksum buffer doesn't grow the frame
// of every recursive step.
#[inline(never)]
fn emit_checksummed<S: Sink>(
    address: &alloy_primitives::Address,
    sink: &mut S,
) -> Option<S::Value> {
    sink.str(address.to_checksum_buffer(None).as_str())
}

fn convert_bigint_unsigned(v: U256) -> BigInt {
    BigInt {
        sign_bit: false,
        words: v.into_limbs().to_vec(),
    }
}
