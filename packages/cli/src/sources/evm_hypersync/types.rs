use anyhow::{Context, Result};
use hypersync_client::{format::Hex, net_types};
use napi_derive::napi;

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
