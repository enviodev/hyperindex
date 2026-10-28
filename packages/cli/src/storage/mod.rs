//! The indexer's storage, in three layers:
//!
//! - the domain: the [`schema`] of what is stored, the [`changes`] a batch
//!   makes to it and the [`batch`] that carries them, none of it knowing a
//!   database;
//! - the [`service`], which keeps every configured store in step: Postgres as
//!   the store of record, ClickHouse beside it;
//! - the stores themselves, in `crate::postgres` and `crate::clickhouse`, each
//!   reading what it keeps off the same domain values.
//!
//! JavaScript reaches all of it through [`js`], which only converts.

pub mod batch;
pub mod changes;
pub mod handoff;
pub mod rows;
pub mod schema;
pub mod service;
pub mod types;

// The addon registers these; a test build has no registration and would see
// every export as dead.
#[cfg_attr(test, allow(dead_code))]
mod js;
#[cfg(test)]
mod live_tests;

use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result};
use tokio::io::AsyncWriteExt;

pub use batch::{Batch, RollbackWrite};
pub use handoff::{Failure, Handoff, WriteError};
pub use service::Storage;

use rows::ResultSet;
use types::{Addresses, ChainConfig, ResumedChain};

#[napi_derive::napi(string_enum)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Store {
    Postgres,
    ClickHouse,
}

/// What the stores hold before anything is initialized or resumed.
#[napi_derive::napi(string_enum)]
#[derive(Debug, PartialEq, Eq)]
pub enum Holding {
    Nothing,
    Initialized,
    /// ClickHouse holds indexed data Postgres has none of.
    Stranded,
    /// Postgres holds indexed data the ClickHouse beside it doesn't.
    Diverged,
    /// Postgres was built by an older envio, which kept no instance to pair
    /// it with the ClickHouse beside it.
    Outdated,
}

/// What a new storage starts out with besides the schema's tables.
pub struct Initialize {
    pub chains: Vec<ChainConfig>,
    pub envio_info: String,
    pub contract_names: Vec<String>,
    pub addresses: Addresses,
}

pub struct AddChain {
    pub chain: ChainConfig,
    pub addresses: Addresses,
}

/// What ClickHouse resumes to: what Postgres committed for the chains this run
/// drives. Only their rows are trimmed: a sibling process driving another
/// chain may be mid-write above its frontier.
pub struct Resume {
    pub committed: Vec<ResumedChain>,
}

pub struct Resumed {
    pub chains: Vec<ResumedChain>,
    pub addresses: ResultSet,
    pub reorg_checkpoints: Vec<types::ReorgCheckpoint>,
}

pub struct StoredConfigRead {
    pub config: types::StoredConfig,
    /// The addresses the config declared, as the stored rows hold them.
    pub config_addresses: ResultSet,
}

pub struct CacheFile {
    pub table: String,
    pub path: String,
}

#[napi_derive::napi(object)]
pub struct CacheDump {
    pub table_name: String,
    pub path: String,
}

impl CacheDump {
    /// Writes the dump through a file of its own beside its path, which
    /// replaces it only once `write` has finished: a dump the server gives up on
    /// part way would otherwise leave a file holding its first rows, and the
    /// next start would load that as the cache. The name is unique per call, so
    /// two dumps of the same table cannot write into each other's.
    pub async fn replace_with(
        &self,
        write: impl AsyncFnOnce(&mut tokio::fs::File) -> Result<()>,
    ) -> Result<()> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = &self.path;
        if let Some(directory) = std::path::Path::new(path).parent() {
            tokio::fs::create_dir_all(directory)
                .await
                .with_context(|| format!("Failed creating {}", directory.display()))?;
        }
        let partial = format!(
            "{path}.{}.{}.partial",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let outcome = async {
            let mut file = tokio::fs::File::create(&partial)
                .await
                .with_context(|| format!("Failed creating {partial}"))?;
            write(&mut file).await?;
            file.flush().await?;
            // On disk before the rename makes it the dump: a crash right after
            // would otherwise leave the name pointing at a file still empty.
            file.sync_all().await?;
            tokio::fs::rename(&partial, path)
                .await
                .with_context(|| format!("Failed replacing {path}"))
        }
        .await;
        if outcome.is_err() {
            let _ = tokio::fs::remove_file(&partial).await;
        }
        outcome
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::anyhow;
    use pretty_assertions::assert_eq;

    #[tokio::test]
    async fn a_dump_that_fails_part_way_leaves_the_file_it_would_replace() {
        let directory = tempdir::TempDir::new("envio-dump").unwrap();
        let path = directory.path().join("price.tsv");
        std::fs::write(&path, "id\toutput\nk1\t1\n").unwrap();
        let dump = CacheDump {
            table_name: "envio_effect_price".to_string(),
            path: path.to_string_lossy().into_owned(),
        };

        let outcome = dump
            .replace_with(async |file| {
                file.write_all(b"id\toutput\n").await?;
                Err(anyhow!("the answer broke off"))
            })
            .await;

        assert_eq!(
            (
                outcome.map_err(|error| error.to_string()),
                std::fs::read_to_string(&path).unwrap(),
                std::fs::read_dir(directory.path()).unwrap().count(),
            ),
            (
                Err("the answer broke off".to_string()),
                "id\toutput\nk1\t1\n".to_string(),
                1
            )
        );
    }
}
