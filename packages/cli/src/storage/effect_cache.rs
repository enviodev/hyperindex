//! An effect's cache: one table per effect and scope, and the file it is
//! dumped to between runs, under a cache directory that keeps a chain's caches
//! in a directory named by its id.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{bail, Context, Result};
use serde_json::json;
use tokio::io::AsyncWriteExt;

use crate::logger::{BoundLogger, Level};

/// The largest chain id a JavaScript number holds exactly.
const MAX_CHAIN_ID: u64 = 9_007_199_254_740_991;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Scope {
    CrossChain,
    Chain(u64),
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct EffectCache {
    pub effect_name: String,
    pub scope: Scope,
}

/// Only a canonical decimal: `007` and `1foo` would name the same chain as a
/// table the cache already has, or none.
fn parse_chain_id(text: &str) -> Option<u64> {
    if text.is_empty()
        || !text.bytes().all(|byte| byte.is_ascii_digit())
        || (text.len() > 1 && text.starts_with('0'))
    {
        return None;
    }
    text.parse().ok().filter(|id| *id <= MAX_CHAIN_ID)
}

impl EffectCache {
    pub fn table_name(&self) -> String {
        match self.scope {
            Scope::CrossChain => format!("envio_effect_{}", self.effect_name),
            Scope::Chain(chain_id) => format!("envio_{chain_id}_effect_{}", self.effect_name),
        }
    }

    /// The cache a table holds, if it holds one. A chain's is tried first:
    /// `_effect_` after the id keeps an effect whose name starts with digits
    /// apart from it.
    pub fn from_table_name(table_name: &str) -> Option<Self> {
        let rest = table_name.strip_prefix("envio_")?;
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        if digits > 0 {
            if let Some(effect_name) = rest[digits..].strip_prefix("_effect_") {
                if effect_name.is_empty() {
                    return None;
                }
                return Some(Self {
                    effect_name: effect_name.to_string(),
                    scope: Scope::Chain(parse_chain_id(&rest[..digits])?),
                });
            }
        }
        match rest.strip_prefix("effect_") {
            Some(effect_name) if !effect_name.is_empty() => Some(Self {
                effect_name: effect_name.to_string(),
                scope: Scope::CrossChain,
            }),
            _ => None,
        }
    }

    pub fn file(&self, cache_dir: &Path) -> PathBuf {
        let file_name = format!("{}.tsv", self.effect_name);
        match self.scope {
            Scope::CrossChain => cache_dir.join(file_name),
            Scope::Chain(chain_id) => cache_dir.join(chain_id.to_string()).join(file_name),
        }
    }
}

fn effect_name_of(file_name: &str) -> Option<&str> {
    file_name.strip_suffix(".tsv")
}

async fn entries(directory: &Path) -> Result<Vec<(String, PathBuf, bool)>> {
    let mut read = tokio::fs::read_dir(directory)
        .await
        .with_context(|| format!("Failed reading {}", directory.display()))?;
    let mut entries = Vec::new();
    while let Some(entry) = read.next_entry().await? {
        let is_dir = entry.file_type().await?.is_dir();
        entries.push((
            entry.file_name().to_string_lossy().into_owned(),
            entry.path(),
            is_dir,
        ));
    }
    entries.sort();
    Ok(entries)
}

/// The caches saved under `cache_dir`, each with its file: a `<name>.tsv` at
/// the top is a cross-chain cache, and one in a directory named by a chain id
/// is that chain's. A directory of files named by anything else is refused
/// rather than skipped, since its caches would silently go unused. No
/// directory is no cache.
pub async fn saved(cache_dir: &Path) -> Result<Vec<(EffectCache, PathBuf)>> {
    if !tokio::fs::try_exists(cache_dir).await.unwrap_or(false) {
        return Ok(Vec::new());
    }
    let mut saved = Vec::new();
    for (name, path, is_dir) in entries(cache_dir).await? {
        if !is_dir {
            if let Some(effect_name) = effect_name_of(&name) {
                saved.push((
                    EffectCache {
                        effect_name: effect_name.to_string(),
                        scope: Scope::CrossChain,
                    },
                    path,
                ));
            }
            continue;
        }
        let files = entries(&path)
            .await?
            .into_iter()
            .filter(|(file_name, _, _)| effect_name_of(file_name).is_some())
            .collect::<Vec<_>>();
        match parse_chain_id(&name) {
            Some(chain_id) => saved.extend(files.into_iter().map(|(file_name, path, _)| {
                (
                    EffectCache {
                        effect_name: effect_name_of(&file_name).unwrap_or_default().to_string(),
                        scope: Scope::Chain(chain_id),
                    },
                    path,
                )
            })),
            None if files.is_empty() => {}
            None => bail!(
                "Invalid effect cache directory \".envio/cache/{name}\". Chain cache directories \
                 must be named by a numeric chain id (e.g. \"1\"). Found cache files: {}.",
                files
                    .iter()
                    .map(|(file_name, _, _)| file_name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }
    }
    Ok(saved)
}

/// A cache the store holds, and how many outputs it has.
#[derive(Debug, PartialEq, Eq)]
pub struct StoredCache {
    pub cache: EffectCache,
    pub rows: i32,
}

/// What restoring or dumping the caches did, which the run reports.
#[derive(Debug)]
pub enum CacheEvent {
    NothingSaved,
    Uploaded,
    /// The run goes on without the saved caches, recomputing their outputs.
    UploadFailed(anyhow::Error),
    Dumping(Vec<StoredCache>),
    Dumped,
    DumpFailed(anyhow::Error),
}

impl CacheEvent {
    pub fn log(&self, logger: &BoundLogger, cache_dir: &Path) {
        let (level, msg, params) = match self {
            CacheEvent::NothingSaved => (
                Level::INFO,
                "No saved effect cache to load from .envio/cache.".to_string(),
                json!({}),
            ),
            CacheEvent::Uploaded => (
                Level::INFO,
                "Successfully uploaded cache.".to_string(),
                json!({}),
            ),
            CacheEvent::UploadFailed(error) => (
                Level::ERROR,
                "Failed to upload cache, continuing without it.".to_string(),
                json!({"err": format!("{error:#}")}),
            ),
            CacheEvent::Dumping(caches) => (
                Level::INFO,
                format!(
                    "Dumping cache: {}",
                    caches
                        .iter()
                        .map(|stored| format!(
                            "{} ({} rows)",
                            stored.cache.table_name(),
                            stored.rows
                        ))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
                json!({}),
            ),
            CacheEvent::Dumped => (
                Level::INFO,
                format!("Successfully dumped cache to {}", cache_dir.display()),
                json!({}),
            ),
            CacheEvent::DumpFailed(error) => (
                Level::ERROR,
                "Failed to dump cache.".to_string(),
                json!({"err": format!("{error:#}")}),
            ),
        };
        logger.log(level, &msg, &params);
    }
}

pub struct CacheFile {
    pub table: String,
    pub path: String,
}

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
        if let Some(directory) = Path::new(path).parent() {
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

    fn cache(effect_name: &str, scope: Scope) -> EffectCache {
        EffectCache {
            effect_name: effect_name.to_string(),
            scope,
        }
    }

    #[test]
    fn a_cache_is_named_by_its_scope_and_read_back_from_that_name() {
        let caches = [
            cache("foo", Scope::CrossChain),
            cache("foo", Scope::Chain(1)),
            cache("1_effect_x", Scope::CrossChain),
            cache("123abc", Scope::Chain(137)),
            cache("token.metadata", Scope::Chain(2494104990)),
        ];
        let names = caches
            .iter()
            .map(EffectCache::table_name)
            .collect::<Vec<_>>();
        assert_eq!(
            (
                names.clone(),
                names
                    .iter()
                    .map(|name| EffectCache::from_table_name(name))
                    .collect::<Vec<_>>(),
            ),
            (
                vec![
                    "envio_effect_foo".to_string(),
                    "envio_1_effect_foo".to_string(),
                    "envio_effect_1_effect_x".to_string(),
                    "envio_137_effect_123abc".to_string(),
                    "envio_2494104990_effect_token.metadata".to_string(),
                ],
                caches.into_iter().map(Some).collect(),
            )
        );
    }

    #[test]
    fn a_table_that_holds_no_cache_names_none() {
        assert_eq!(
            [
                "envio_chains",
                "envio_checkpoints",
                "User",
                "envio_effect_",
                "envio_1_effect_",
                "envio_007_effect_foo",
                "envio_99999999999999999_effect_foo",
            ]
            .map(EffectCache::from_table_name),
            [None, None, None, None, None, None, None]
        );
    }

    #[test]
    fn a_chain_id_is_only_its_canonical_decimal() {
        assert_eq!(
            [
                "1",
                "137",
                "0",
                "007",
                "1foo",
                "",
                "-1",
                "1.5",
                "9007199254740992"
            ]
            .map(parse_chain_id),
            [
                Some(1),
                Some(137),
                Some(0),
                None,
                None,
                None,
                None,
                None,
                None
            ]
        );
    }

    #[test]
    fn a_chains_cache_is_filed_in_its_chains_directory() {
        let dir = Path::new("/cache");
        assert_eq!(
            (
                cache("foo", Scope::CrossChain).file(dir),
                cache("foo", Scope::Chain(137)).file(dir),
            ),
            (
                PathBuf::from("/cache/foo.tsv"),
                PathBuf::from("/cache/137/foo.tsv")
            )
        );
    }

    #[tokio::test]
    async fn the_saved_caches_are_the_tsv_files_at_the_top_and_in_chain_directories() {
        let directory = tempdir::TempDir::new("envio-cache").unwrap();
        let root = directory.path();
        std::fs::create_dir_all(root.join("137")).unwrap();
        std::fs::create_dir_all(root.join("notes")).unwrap();
        for file in ["price.tsv", "readme.md", "137/owner.tsv", "notes/todo.txt"] {
            std::fs::write(root.join(file), "id\toutput\n").unwrap();
        }

        assert_eq!(
            (
                saved(root).await.unwrap(),
                saved(&root.join("missing")).await.unwrap(),
            ),
            (
                vec![
                    (
                        cache("owner", Scope::Chain(137)),
                        root.join("137/owner.tsv")
                    ),
                    (cache("price", Scope::CrossChain), root.join("price.tsv")),
                ],
                vec![],
            )
        );
    }

    #[tokio::test]
    async fn a_directory_of_caches_not_named_by_a_chain_id_is_refused() {
        let directory = tempdir::TempDir::new("envio-cache").unwrap();
        let root = directory.path();
        std::fs::create_dir_all(root.join("mainnet")).unwrap();
        std::fs::write(root.join("mainnet/price.tsv"), "id\toutput\n").unwrap();

        assert_eq!(
            saved(root).await.map_err(|error| error.to_string()),
            Err(
                "Invalid effect cache directory \".envio/cache/mainnet\". Chain cache \
                 directories must be named by a numeric chain id (e.g. \"1\"). Found cache \
                 files: price.tsv."
                    .to_string()
            )
        );
    }

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
