use alloy_primitives::U256;
use anyhow::{Context, Result};
use hypersync_client::format::{self, FixedSizeData, Hex};
use napi::bindgen_prelude::BigInt;
use napi_derive::napi;

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

fn convert_bigint_unsigned(v: U256) -> BigInt {
    BigInt {
        sign_bit: false,
        words: v.into_limbs().to_vec(),
    }
}
