use std::ffi::CString;

use alloy_dyn_abi::DynSolValue;
use alloy_primitives::{Signed, U256};
use anyhow::{Context, Result};
use hypersync_client::{
    format::{self, FixedSizeData, Hex},
    net_types, simple_types,
};
use napi::bindgen_prelude::{BigInt, FromNapiValue, ToNapiValue};
use napi_derive::napi;

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

fn encode_prefix_hex(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return "0x".into();
    }

    format!("0x{}", faster_hex::hex_string(bytes))
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

#[napi(object)]
pub struct EventParamsInput {
    /// Chain-scoped sequential registration id; returned on every routed item
    /// so JS resolves the registration by array index.
    pub id: i64,
    pub sighash: String,
    pub topic_count: i32,
    pub event_name: String,
    pub contract_name: String,
    pub is_wildcard: bool,
    pub params: Vec<ParamMeta>,
}

pub enum ParamValue {
    Bool(bool),
    BigInt(BigInt),
    Str(String),
    Arr(Vec<ParamValue>),
    Obj(Vec<(String, ParamValue)>),
}

impl FromNapiValue for ParamValue {
    unsafe fn from_napi_value(
        _env: napi::sys::napi_env,
        _val: napi::sys::napi_value,
    ) -> napi::Result<Self> {
        Err(napi::Error::from_reason(
            "ParamValue is decode-only; it cannot be constructed from JS",
        ))
    }
}

impl ToNapiValue for ParamValue {
    unsafe fn to_napi_value(
        raw_env: napi::sys::napi_env,
        val: Self,
    ) -> napi::Result<napi::sys::napi_value> {
        match val {
            ParamValue::Bool(v) => bool::to_napi_value(raw_env, v),
            ParamValue::BigInt(v) => BigInt::to_napi_value(raw_env, v),
            ParamValue::Str(v) => String::to_napi_value(raw_env, v),
            ParamValue::Arr(items) => Vec::<ParamValue>::to_napi_value(raw_env, items),
            ParamValue::Obj(entries) => {
                let mut obj = std::ptr::null_mut();
                assert_eq!(
                    napi::sys::napi_create_object(raw_env, &mut obj),
                    napi::sys::Status::napi_ok
                );
                for (key, val) in entries {
                    let js_val = ParamValue::to_napi_value(raw_env, val)?;
                    let c_key = CString::new(key)
                        .map_err(|_| napi::Error::from_reason("invalid param name"))?;
                    assert_eq!(
                        napi::sys::napi_set_named_property(raw_env, obj, c_key.as_ptr(), js_val),
                        napi::sys::Status::napi_ok,
                    );
                }
                Ok(obj)
            }
        }
    }
}

pub fn sol_value_to_param(
    val: DynSolValue,
    components: Option<&[ParamMeta]>,
    checksummed: bool,
) -> ParamValue {
    match (val, components) {
        (DynSolValue::Tuple(vals), Some(comps)) => {
            let fields = vals
                .into_iter()
                .zip(comps.iter())
                .map(|(v, c)| {
                    let value = sol_value_to_param(v, c.components.as_deref(), checksummed);
                    (c.name.clone(), value)
                })
                .collect();
            ParamValue::Obj(fields)
        }
        (DynSolValue::Array(vals), Some(comps)) => ParamValue::Arr(
            vals.into_iter()
                .map(|v| sol_value_to_param(v, Some(comps), checksummed))
                .collect(),
        ),
        (DynSolValue::FixedArray(vals), Some(comps)) => ParamValue::Arr(
            vals.into_iter()
                .map(|v| sol_value_to_param(v, Some(comps), checksummed))
                .collect(),
        ),
        (val, _) => sol_value_to_leaf(val, checksummed),
    }
}

fn sol_value_to_leaf(val: DynSolValue, checksummed: bool) -> ParamValue {
    match val {
        DynSolValue::Bool(b) => ParamValue::Bool(b),
        DynSolValue::Int(v, _) => ParamValue::BigInt(convert_bigint_signed(v)),
        DynSolValue::Uint(v, _) => ParamValue::BigInt(convert_bigint_unsigned(v)),
        DynSolValue::FixedBytes(bytes, _) => ParamValue::Str(encode_prefix_hex(bytes.as_slice())),
        DynSolValue::Address(addr) => {
            if checksummed {
                ParamValue::Str(addr.to_checksum(None))
            } else {
                ParamValue::Str(encode_prefix_hex(addr.as_slice()))
            }
        }
        DynSolValue::Function(bytes) => ParamValue::Str(encode_prefix_hex(bytes.as_slice())),
        DynSolValue::Bytes(bytes) => ParamValue::Str(encode_prefix_hex(bytes.as_slice())),
        DynSolValue::String(s) => ParamValue::Str(s),
        DynSolValue::Array(vals) => ParamValue::Arr(
            vals.into_iter()
                .map(|v| sol_value_to_leaf(v, checksummed))
                .collect(),
        ),
        DynSolValue::FixedArray(vals) => ParamValue::Arr(
            vals.into_iter()
                .map(|v| sol_value_to_leaf(v, checksummed))
                .collect(),
        ),
        DynSolValue::Tuple(vals) => ParamValue::Arr(
            vals.into_iter()
                .map(|v| sol_value_to_leaf(v, checksummed))
                .collect(),
        ),
    }
}

fn convert_bigint_signed(v: Signed<256, 4>) -> BigInt {
    let (sign, abs) = v.into_sign_and_abs();
    BigInt {
        sign_bit: sign.is_negative(),
        words: abs.into_limbs().to_vec(),
    }
}

fn convert_bigint_unsigned(v: U256) -> BigInt {
    BigInt {
        sign_bit: false,
        words: v.into_limbs().to_vec(),
    }
}
