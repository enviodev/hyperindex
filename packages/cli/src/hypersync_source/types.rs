use alloy_dyn_abi::DynSolValue;
use alloy_primitives::{Signed, U256};
use anyhow::{Context, Result};
use hypersync_client::{
    format::{self, FixedSizeData, Hex},
    net_types, simple_types,
};
use napi::bindgen_prelude::{BigInt, Either4};
use napi_derive::napi;

/// Data relating to a single event (log)
#[napi(object)]
#[derive(Default, Clone)]
pub struct Event {
    /// Transaction that triggered this event
    pub transaction: Option<Transaction>,
    /// Block that this event happened in
    pub block: Option<Block>,
    /// Evm log data
    pub log: Log,
}

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

/// Evm transaction object
///
/// See ethereum rpc spec for the meaning of fields
#[napi(object)]
#[derive(Default, Clone)]
pub struct Transaction {
    pub block_hash: Option<String>,
    pub block_number: Option<i64>,
    pub from: Option<String>,
    pub gas: Option<BigInt>,
    pub gas_price: Option<BigInt>,
    pub hash: Option<String>,
    pub input: Option<String>,
    pub nonce: Option<BigInt>,
    pub to: Option<String>,
    pub transaction_index: Option<i64>,
    pub value: Option<BigInt>,
    pub v: Option<String>,
    pub r: Option<String>,
    pub s: Option<String>,
    pub y_parity: Option<String>,
    pub max_priority_fee_per_gas: Option<BigInt>,
    pub max_fee_per_gas: Option<BigInt>,
    pub chain_id: Option<i64>,
    pub access_list: Option<Vec<AccessList>>,
    pub authorization_list: Option<Vec<Authorization>>,
    pub max_fee_per_blob_gas: Option<BigInt>,
    pub blob_versioned_hashes: Option<Vec<String>>,
    pub cumulative_gas_used: Option<BigInt>,
    pub effective_gas_price: Option<BigInt>,
    pub gas_used: Option<BigInt>,
    pub contract_address: Option<String>,
    pub logs_bloom: Option<String>,
    #[napi(js_name = "type")]
    pub type_: Option<i64>,
    pub root: Option<String>,
    pub status: Option<i64>,
    pub l1_fee: Option<BigInt>,
    pub l1_gas_price: Option<BigInt>,
    pub l1_gas_used: Option<BigInt>,
    pub l1_fee_scalar: Option<f64>,
    pub gas_used_for_l1: Option<BigInt>,
    pub blob_gas_price: Option<BigInt>,
    pub blob_gas_used: Option<BigInt>,
    pub deposit_nonce: Option<BigInt>,
    pub deposit_receipt_version: Option<BigInt>,
    pub l1_base_fee_scalar: Option<BigInt>,
    pub l1_blob_base_fee: Option<BigInt>,
    pub l1_blob_base_fee_scalar: Option<BigInt>,
    pub l1_block_number: Option<i64>,
    pub mint: Option<BigInt>,
    pub sighash: Option<String>,
    pub source_hash: Option<String>,
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

/// Decoded EVM log
#[napi(object)]
#[derive(Default)]
pub struct DecodedEvent {
    pub indexed: Vec<DecodedSolValue>,
    pub body: Vec<DecodedSolValue>,
}

#[napi(object)]
#[derive(Clone)]
pub struct DecodedSolValue {
    pub val: Either4<bool, BigInt, String, Vec<DecodedSolValue>>,
}

impl DecodedSolValue {
    pub fn new(val: DynSolValue, checksummed_addresses: bool) -> Self {
        let val = match val {
            DynSolValue::Bool(b) => Either4::A(b),
            DynSolValue::Int(v, _) => Either4::B(convert_bigint_signed(v)),
            DynSolValue::Uint(v, _) => Either4::B(convert_bigint_unsigned(v)),
            DynSolValue::FixedBytes(bytes, _) => Either4::C(encode_prefix_hex(bytes.as_slice())),
            DynSolValue::Address(addr) => {
                if !checksummed_addresses {
                    Either4::C(encode_prefix_hex(addr.as_slice()))
                } else {
                    Either4::C(addr.to_checksum(None))
                }
            }
            DynSolValue::Function(bytes) => Either4::C(encode_prefix_hex(bytes.as_slice())),
            DynSolValue::Bytes(bytes) => Either4::C(encode_prefix_hex(bytes.as_slice())),
            DynSolValue::String(s) => Either4::C(s),
            DynSolValue::Array(vals) => Either4::D(
                vals.into_iter()
                    .map(|v| DecodedSolValue::new(v, checksummed_addresses))
                    .collect(),
            ),
            DynSolValue::FixedArray(vals) => Either4::D(
                vals.into_iter()
                    .map(|v| DecodedSolValue::new(v, checksummed_addresses))
                    .collect(),
            ),
            DynSolValue::Tuple(vals) => Either4::D(
                vals.into_iter()
                    .map(|v| DecodedSolValue::new(v, checksummed_addresses))
                    .collect(),
            ),
        };

        Self { val }
    }
}

fn encode_prefix_hex(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return "0x".into();
    }

    format!("0x{}", faster_hex::hex_string(bytes))
}

fn map_address_string(v: &Option<FixedSizeData<20>>, should_checksum: bool) -> Option<String> {
    v.as_ref().map(|v| {
        if should_checksum {
            alloy_primitives::Address(alloy_primitives::FixedBytes(***v)).to_checksum(None)
        } else {
            v.encode_hex()
        }
    })
}

fn map_hex_string<T: Hex>(v: &Option<T>) -> Option<String> {
    v.as_ref().map(|v| v.encode_hex())
}

fn map_i64<T: AsRef<[u8]>>(opt: &Option<T>) -> Result<Option<i64>> {
    opt.as_ref()
        .map(|v| {
            i64::try_from(ruint::aliases::U256::from_be_slice(v.as_ref()))
                .context("converting U256 to i64")
        })
        .transpose()
}

fn map_bigint<T: AsRef<[u8]>>(opt: &Option<T>) -> Option<BigInt> {
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

impl Transaction {
    pub fn from_simple(t: &simple_types::Transaction, should_checksum: bool) -> Result<Self> {
        Ok(Self {
            block_hash: map_hex_string(&t.block_hash),
            block_number: t
                .block_number
                .map(|n| u64::from(n).try_into())
                .transpose()
                .context("mapping transaction.block_number")?,
            from: map_address_string(&t.from, should_checksum),
            gas: map_bigint(&t.gas),
            gas_price: map_bigint(&t.gas_price),
            hash: map_hex_string(&t.hash),
            input: map_hex_string(&t.input),
            nonce: map_bigint(&t.nonce),
            to: map_address_string(&t.to, should_checksum),
            transaction_index: t
                .transaction_index
                .map(|n| u64::from(n).try_into())
                .transpose()
                .context("mapping transaction.transaction_index")?,
            value: map_bigint(&t.value),
            v: map_hex_string(&t.v),
            r: map_hex_string(&t.r),
            s: map_hex_string(&t.s),
            y_parity: map_hex_string(&t.y_parity),
            max_priority_fee_per_gas: map_bigint(&t.max_priority_fee_per_gas),
            max_fee_per_gas: map_bigint(&t.max_fee_per_gas),
            chain_id: t
                .chain_id
                .as_ref()
                .map(|n| ruint::aliases::U256::from_be_slice(n).try_into())
                .transpose()
                .context("mapping transaction.chain_id")?,
            access_list: t
                .access_list
                .as_ref()
                .map(|arr| arr.iter().map(AccessList::from).collect()),
            authorization_list: t
                .authorization_list
                .as_ref()
                .map(|al| {
                    al.iter()
                        .map(Authorization::try_from)
                        .collect::<Result<_>>()
                })
                .transpose()
                .context("mapping transaction.authorization_list")?,
            max_fee_per_blob_gas: map_bigint(&t.max_fee_per_blob_gas),
            blob_versioned_hashes: t
                .blob_versioned_hashes
                .as_ref()
                .map(|arr| arr.iter().map(|h| h.encode_hex()).collect()),
            cumulative_gas_used: map_bigint(&t.cumulative_gas_used),
            effective_gas_price: map_bigint(&t.effective_gas_price),
            gas_used: map_bigint(&t.gas_used),
            contract_address: map_address_string(&t.contract_address, should_checksum),
            logs_bloom: map_hex_string(&t.logs_bloom),
            type_: t.type_.map(|v| u8::from(v).into()),
            root: map_hex_string(&t.root),
            status: t.status.map(|v| v.to_u8().into()),
            l1_fee: map_bigint(&t.l1_fee),
            l1_gas_price: map_bigint(&t.l1_gas_price),
            l1_gas_used: map_bigint(&t.l1_gas_used),
            l1_fee_scalar: t.l1_fee_scalar,
            gas_used_for_l1: map_bigint(&t.gas_used_for_l1),
            blob_gas_price: map_bigint(&t.blob_gas_price),
            blob_gas_used: map_bigint(&t.blob_gas_used),
            deposit_nonce: map_bigint(&t.deposit_nonce),
            deposit_receipt_version: map_bigint(&t.deposit_receipt_version),
            l1_base_fee_scalar: map_bigint(&t.l1_base_fee_scalar),
            l1_blob_base_fee: map_bigint(&t.l1_blob_base_fee),
            l1_blob_base_fee_scalar: map_bigint(&t.l1_blob_base_fee_scalar),
            l1_block_number: map_i64(&t.l1_block_number)
                .context("mapping transaction.l1_block_number")?,
            mint: map_bigint(&t.mint),
            sighash: map_hex_string(&t.sighash),
            source_hash: map_hex_string(&t.source_hash),
        })
    }
}

impl Log {
    pub fn from_simple(l: &simple_types::Log, should_checksum: bool) -> Result<Self> {
        Ok(Self {
            removed: l.removed,
            log_index: l
                .log_index
                .map(|n| u64::from(n).try_into())
                .transpose()
                .context("mapping log.log_index")?,
            transaction_index: l
                .transaction_index
                .map(|n| u64::from(n).try_into())
                .transpose()
                .context("mapping log.transaction_index")?,
            transaction_hash: map_hex_string(&l.transaction_hash),
            block_hash: map_hex_string(&l.block_hash),
            block_number: l
                .block_number
                .map(|n| u64::from(n).try_into())
                .transpose()
                .context("mapping log.block_number")?,
            address: map_address_string(&l.address, should_checksum),
            data: map_hex_string(&l.data),
            topics: l
                .topics
                .iter()
                .map(|t| t.as_ref().map(|v| v.encode_hex()))
                .collect(),
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
