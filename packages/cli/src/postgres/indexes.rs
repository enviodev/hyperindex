//! Postgres stays authoritative: nothing counts as present until it has been
//! read back from pg_catalog. Builds are serialised per table, so two never
//! fight over the same one, and concurrent requests for one index share its
//! build.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use anyhow::{anyhow, bail, Result};
use napi_derive::napi;
use tokio::sync::watch;
use tokio_postgres::Row;

use super::client::PgClient;
use super::error::{message_of, sql_state};
use super::index_definition::{drop_query, Direction, IndexColumn, IndexDefinition};
use super::param::Param;

/// How much of an existing index has to line up before it counts as coverage.
///
/// A schema-declared `@index` is a promise about the physical schema, so it is
/// matched `Exact`: whether some composite index happens to exist must not
/// change what a fresh database ends up with, or two indexers on the same
/// schema would hold different tables.
///
/// An automatic getWhere index is an optimization nobody declared, so
/// `LeadingColumns` is enough — an existing composite that already starts with
/// the column serves the query, and building a second one would only cost write
/// amplification.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Coverage {
    Exact,
    LeadingColumns,
}

/// What a build is for, which decides how much an existing index has to match.
#[napi(string_enum)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Purpose {
    /// Serves a getWhere filter.
    Query,
    /// Promised by the schema, on an indexer that is already ready.
    Schema,
}

impl Purpose {
    fn coverage(self) -> Coverage {
        match self {
            Purpose::Query => Coverage::LeadingColumns,
            Purpose::Schema => Coverage::Exact,
        }
    }
}

/// What the indexes are doing, for the logs. A build blocks writes to its
/// table for as long as it runs, so a stalled-looking indexer has to be
/// explainable from these alone.
#[napi(discriminant = "kind")]
#[derive(Clone, PartialEq, Debug)]
pub enum IndexEvent {
    /// Indexes PostgreSQL reports as unusable, found on a reload.
    Invalid { names: Vec<String> },
    /// What a backfill's finalization owes before the indexer is ready.
    Planned {
        declared: u32,
        missing: Vec<String>,
        rebuilt: Vec<String>,
    },
    Building {
        purpose: Purpose,
        name: String,
        table_name: String,
        is_rebuild: bool,
    },
    Built {
        purpose: Purpose,
        name: String,
        seconds: f64,
    },
    /// The build failed, and whatever it was for runs unindexed meanwhile.
    Failed {
        purpose: Purpose,
        name: String,
        table_name: String,
        columns: Vec<String>,
        error: String,
        /// The SQLSTATE, when the server refused it.
        code: Option<String>,
    },
    ResyncFailed {
        name: String,
        error: String,
        code: Option<String>,
    },
    /// A finalization's builds and the ready timestamp are committed.
    Committed { count: u32, seconds: f64 },
}

pub type Report = Arc<dyn Fn(IndexEvent) + Send + Sync>;

#[derive(Clone, PartialEq, Debug)]
pub struct Entry {
    pub name: String,
    pub table_name: String,
    pub method: String,
    pub columns: Vec<IndexColumn>,
    pub is_valid: bool,
    pub is_unique: bool,
    /// An index with a WHERE clause only covers rows inside its predicate, so
    /// it can't stand in for the unrestricted index a filter needs.
    pub is_partial: bool,
    pub is_expression: bool,
    pub predicate: Option<String>,
}

fn columns_text(columns: &[IndexColumn]) -> String {
    columns
        .iter()
        .map(IndexDefinition::column_key)
        .collect::<Vec<_>>()
        .join(", ")
}

impl Entry {
    /// A btree's key columns are ordered, so an index leading with the
    /// requested columns can serve them. The reverse isn't true, which is why
    /// order matters.
    fn leads_with(&self, definition: &IndexDefinition) -> bool {
        definition.columns.len() <= self.columns.len()
            && definition
                .columns
                .iter()
                .zip(&self.columns)
                .all(|(wanted, actual)| wanted == actual)
    }

    /// Why the index can't serve a request, in the order the checks are worth
    /// reporting.
    pub fn reject_reason(
        &self,
        definition: &IndexDefinition,
        coverage: Coverage,
    ) -> Option<String> {
        if self.table_name != definition.table_name {
            Some(format!("it is on table \"{}\"", self.table_name))
        } else if !self.is_valid {
            Some("PostgreSQL reports it as invalid or not ready".to_string())
        } else if self.is_partial {
            Some(format!(
                "it is partial (WHERE {}), so it only covers part of the table",
                self.predicate.as_deref().unwrap_or("...")
            ))
        } else if self.is_expression {
            Some("it indexes an expression rather than plain columns".to_string())
        } else if self.method != definition.method {
            Some(format!(
                "it uses the {} access method, not {}",
                self.method, definition.method
            ))
        } else if !self.leads_with(definition) {
            Some(format!(
                "it covers ({}) instead of leading with the requested columns",
                columns_text(&self.columns)
            ))
        } else if coverage == Coverage::Exact && self.columns.len() != definition.columns.len() {
            Some(format!(
                "it covers ({}) rather than exactly the declared columns",
                columns_text(&self.columns)
            ))
        } else {
            None
        }
    }

    /// Byte-for-byte what `definition` asks for, valid or not. Decides
    /// ownership, where even an exact-coverage match would be too loose: a
    /// unique index covering the same columns still isn't one the indexer
    /// created.
    fn is_exactly(&self, definition: &IndexDefinition) -> bool {
        self.table_name == definition.table_name
            && self.method == definition.method
            && !self.is_unique
            && !self.is_partial
            && !self.is_expression
            && self.columns == definition.columns
    }
}

/// A build the catalog doesn't already cover. `is_rebuild` means an unusable
/// index holds the generated name with exactly this identity, so it can only
/// be one of ours — dropped and built again rather than left to block the name.
#[derive(Debug, PartialEq)]
pub struct Prepared {
    pub definition: IndexDefinition,
    pub name: String,
    pub is_rebuild: bool,
    pub queries: Vec<String>,
}

#[derive(Default)]
pub struct Catalog {
    by_name: HashMap<String, Entry>,
    /// Coverage is asked per filtered column on every batched getWhere load,
    /// and scanning the whole schema there would make the hot path grow with
    /// it. Answers are memoized and thrown away whenever the catalog moves.
    covering: HashMap<(Coverage, String), Option<String>>,
}

impl Catalog {
    pub fn new(entries: Vec<Entry>) -> Self {
        Self {
            by_name: entries
                .into_iter()
                .map(|entry| (entry.name.clone(), entry))
                .collect(),
            covering: HashMap::new(),
        }
    }

    fn set(&mut self, entry: Entry) {
        self.by_name.insert(entry.name.clone(), entry);
        self.covering.clear();
    }

    /// Puts one index back in step with the database.
    fn resync(&mut self, name: &str, entries: Vec<Entry>) {
        match entries.into_iter().find(|entry| entry.name == name) {
            Some(entry) => self.set(entry),
            None => {
                self.by_name.remove(name);
                self.covering.clear();
            }
        }
    }

    pub fn covers(&mut self, definition: &IndexDefinition, coverage: Coverage) -> bool {
        let key = (coverage, definition.key());
        if let Some(found) = self.covering.get(&key) {
            return found.is_some();
        }
        let found = self
            .by_name
            .values()
            .find(|entry| entry.reject_reason(definition, coverage).is_none())
            .map(|entry| entry.name.clone());
        let covered = found.is_some();
        self.covering.insert(key, found);
        covered
    }

    pub fn invalid_names(&self) -> Vec<String> {
        let mut names = self
            .by_name
            .values()
            .filter(|entry| !entry.is_valid)
            .map(|entry| entry.name.clone())
            .collect::<Vec<_>>();
        names.sort();
        names
    }

    /// `None` when the catalog already covers the definition. Resolving this
    /// before any DDL runs means a name held by an unrelated index fails while
    /// nothing is half-built.
    pub fn prepare(
        &mut self,
        definition: &IndexDefinition,
        coverage: Coverage,
        pg_schema: &str,
    ) -> Result<Option<Prepared>> {
        if self.covers(definition, coverage) {
            return Ok(None);
        }
        let name = definition.name();
        let create = definition.create_query(pg_schema);
        let (is_rebuild, queries) = match self.by_name.get(&name) {
            None => (false, vec![create]),
            Some(entry) if entry.is_exactly(definition) => {
                (true, vec![drop_query(pg_schema, &name), create])
            }
            // The name is derived from a hash of the full identity, so an index
            // holding it was generated for this exact identity. Anything else
            // under that name is someone else's, and guessing which is worse
            // than stopping.
            Some(entry) => bail!(
                "Cannot create the index \"{name}\" in schema \"{pg_schema}\" for {}. A \
                 different index already holds that name and the indexer can't safely replace \
                 it: {}. Drop that index by hand, then restart the indexer.",
                definition.describe(),
                entry
                    .reject_reason(definition, Coverage::Exact)
                    .unwrap_or_else(|| "it is unique".to_string())
            ),
        };
        Ok(Some(Prepared {
            definition: definition.clone(),
            name,
            is_rebuild,
            queries,
        }))
    }
}

/// The DDL succeeding is not proof the index exists in a form the planner will
/// use: a build can leave an index INVALID, and a name assumed free would have
/// made it a no-op. Verified against `Exact` whatever the request asked for:
/// the index was just created from the definition, so anything short of a
/// byte-for-byte match means Postgres built something else.
fn verify(prepared: &Prepared, entry: Option<Entry>, pg_schema: &str) -> Result<Entry> {
    let reason = match &entry {
        None => Some("PostgreSQL has no such index".to_string()),
        Some(entry) => entry.reject_reason(&prepared.definition, Coverage::Exact),
    };
    match (reason, entry) {
        (None, Some(entry)) => Ok(entry),
        (reason, _) => Err(anyhow!(
            "The index \"{}\" in schema \"{pg_schema}\" is not usable after its DDL ran: {}. It \
             was meant to cover {}. Drop it by hand, then restart the indexer.",
            prepared.name,
            reason.unwrap_or_default(),
            prepared.definition.describe()
        )),
    }
}

/// Another process in the same schema builds the same indexes, and when two
/// creates meet only one of them wins. Both of these say the index is there,
/// which is what was wanted: a unique violation on the catalog's own index when
/// the creates overlapped, "already exists" when one merely followed the other.
fn built_by_another(error: &anyhow::Error) -> bool {
    match sql_state(error) {
        Some("42P07") => true,
        Some("23505") => message_of(error).contains("pg_class_relname_nsp_index"),
        _ => false,
    }
}

pub trait Db: Send + Sync {
    fn run(&self, sql: &str) -> impl Future<Output = Result<()>> + Send;
    /// The schema's indexes, or the one named.
    fn read(
        &self,
        pg_schema: &str,
        name: Option<&str>,
    ) -> impl Future<Output = Result<Vec<Entry>>> + Send;
}

/// One row per index, its key columns in ordinal order. INCLUDE columns are
/// left out (they don't affect what the index can serve), and an expression
/// column comes back as its printed definition, so an expression index can
/// never be mistaken for a plain-column one.
fn catalog_query(by_name: bool) -> String {
    format!(
        "SELECT
  t.relname::text,
  i.relname::text,
  am.amname::text,
  ix.indisvalid AND ix.indisready,
  ix.indisunique,
  ix.indpred IS NOT NULL,
  ix.indexprs IS NOT NULL,
  pg_get_expr(ix.indpred, ix.indrelid, true),
  array_agg(
    CASE WHEN k.attnum = 0
      THEN pg_get_indexdef(ix.indexrelid, k.ord::int, true)
      ELSE a.attname::text
    END ORDER BY k.ord
  ),
  array_agg((ix.indoption[k.ord - 1] & 1) = 1 ORDER BY k.ord)
FROM pg_index ix
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN pg_am am ON am.oid = i.relam
JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ON k.ord <= ix.indnkeyatts
LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
WHERE n.nspname = $1{}
GROUP BY t.relname, i.relname, am.amname, ix.indisvalid, ix.indisready,
         ix.indisunique, ix.indpred, ix.indrelid, ix.indexrelid, (ix.indexprs IS NOT NULL);",
        if by_name { " AND i.relname = $2" } else { "" }
    )
}

fn entry_from_row(row: &Row) -> Result<Entry> {
    let names: Vec<String> = row.try_get(8)?;
    let descending: Vec<bool> = row.try_get(9)?;
    Ok(Entry {
        table_name: row.try_get(0)?,
        name: row.try_get(1)?,
        method: row.try_get(2)?,
        is_valid: row.try_get(3)?,
        is_unique: row.try_get(4)?,
        is_partial: row.try_get(5)?,
        is_expression: row.try_get(6)?,
        predicate: row.try_get(7)?,
        columns: names
            .into_iter()
            .zip(descending)
            .map(|(name, descending)| IndexColumn {
                name,
                direction: if descending {
                    Direction::Desc
                } else {
                    Direction::Asc
                },
            })
            .collect(),
    })
}

impl Db for PgClient {
    async fn run(&self, sql: &str) -> Result<()> {
        self.batch(sql).await
    }

    async fn read(&self, pg_schema: &str, name: Option<&str>) -> Result<Vec<Entry>> {
        let mut params = vec![Param::Text(pg_schema.to_string())];
        params.extend(name.map(|name| Param::Text(name.to_string())));
        let (rows, _) = self.query(&catalog_query(name.is_some()), &params).await?;
        rows.iter().map(entry_from_row).collect()
    }
}

pub struct Indexes<D> {
    db: D,
    pg_schema: String,
    report: Report,
    catalog: Mutex<Catalog>,
    /// Keyed by coverage as well as identity: an `Exact` request joining an
    /// in-flight `LeadingColumns` one would resolve as soon as that build
    /// decided a leading composite already served it, and the declared index
    /// would never be created.
    inflight: Mutex<HashMap<(Coverage, String), watch::Receiver<()>>>,
    tables: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

/// An in-flight build. Requests that joined it wake when it is dropped, built
/// or not: the build reports its own outcome, and a failed one is retried by
/// the next request rather than by every one that waited on it.
struct Flight<'a, D> {
    indexes: &'a Indexes<D>,
    key: (Coverage, String),
    _done: watch::Sender<()>,
}

impl<D> Drop for Flight<'_, D> {
    fn drop(&mut self) {
        self.indexes.inflight.lock().unwrap().remove(&self.key);
    }
}

impl<D: Db> Indexes<D> {
    pub fn new(db: D, pg_schema: String, report: Report) -> Self {
        Self {
            db,
            pg_schema,
            report,
            catalog: Mutex::new(Catalog::default()),
            inflight: Mutex::new(HashMap::new()),
            tables: Mutex::new(HashMap::new()),
        }
    }

    /// Replaces the catalog with the database's, so a restart plans against
    /// what is there rather than what an earlier run built.
    pub async fn reload(&self) -> Result<()> {
        let catalog = Catalog::new(self.db.read(&self.pg_schema, None).await?);
        let invalid = catalog.invalid_names();
        *self.catalog.lock().unwrap() = catalog;
        if !invalid.is_empty() {
            (self.report)(IndexEvent::Invalid { names: invalid });
        }
        Ok(())
    }

    pub fn covers_all(&self, definitions: &[IndexDefinition], coverage: Coverage) -> bool {
        let mut catalog = self.catalog.lock().unwrap();
        definitions
            .iter()
            .all(|definition| catalog.covers(definition, coverage))
    }

    /// Builds whatever the catalog doesn't cover. Never fails: a failed build
    /// is reported and recorded nowhere, so what it was for runs unindexed and
    /// the next request retries.
    pub async fn ensure(&self, definitions: Vec<IndexDefinition>, purpose: Purpose) {
        futures_util::future::join_all(
            definitions
                .iter()
                .map(|definition| self.ensure_one(definition, purpose)),
        )
        .await;
    }

    async fn ensure_one(&self, definition: &IndexDefinition, purpose: Purpose) {
        let coverage = purpose.coverage();
        let key = (coverage, definition.key());
        let joined = {
            let mut inflight = self.inflight.lock().unwrap();
            if self.catalog.lock().unwrap().covers(definition, coverage) {
                return;
            }
            match inflight.get(&key) {
                Some(done) => Err(done.clone()),
                None => {
                    let (sender, receiver) = watch::channel(());
                    inflight.insert(key.clone(), receiver);
                    Ok(sender)
                }
            }
        };
        let _flight = match joined {
            Ok(sender) => Flight {
                indexes: self,
                key,
                _done: sender,
            },
            Err(mut done) => {
                let _ = done.changed().await;
                return;
            }
        };
        let table = self
            .tables
            .lock()
            .unwrap()
            .entry(definition.table_name.clone())
            .or_default()
            .clone();
        let _turn = table.lock().await;

        // Planned only now: a build queued behind another on the same table may
        // have been covered meanwhile.
        let planned = self
            .catalog
            .lock()
            .unwrap()
            .prepare(definition, coverage, &self.pg_schema);
        let outcome = match planned {
            Ok(None) => return,
            Ok(Some(prepared)) => {
                (self.report)(IndexEvent::Building {
                    purpose,
                    name: prepared.name.clone(),
                    table_name: definition.table_name.clone(),
                    is_rebuild: prepared.is_rebuild,
                });
                let start = Instant::now();
                self.build(&prepared).await.map(|()| {
                    (self.report)(IndexEvent::Built {
                        purpose,
                        name: prepared.name,
                        seconds: start.elapsed().as_secs_f64(),
                    })
                })
            }
            Err(error) => Err(error),
        };
        if let Err(error) = outcome {
            let name = definition.name();
            if !built_by_another(&error) {
                (self.report)(IndexEvent::Failed {
                    purpose,
                    name: name.clone(),
                    table_name: definition.table_name.clone(),
                    columns: definition
                        .columns
                        .iter()
                        .map(|column| column.name.clone())
                        .collect(),
                    error: message_of(&error),
                    code: sql_state(&error).map(str::to_string),
                });
            }
            self.resync(&name).await;
        }
    }

    /// Builds every declared index the catalog doesn't hold exactly, one
    /// committed index at a time: whatever is built before a failure stays
    /// built and recorded, so the retry owes only the rest. Returns how many it
    /// built.
    ///
    /// Not serialised with `ensure`: it runs with processing paused, so no
    /// getWhere can be building alongside it. A sibling process driving other
    /// chains of the same schema can, though — it builds the same indexes at
    /// the same moment, which is why a lost create is re-read rather than taken
    /// as a failure.
    pub async fn finalize(&self, definitions: Vec<IndexDefinition>) -> Result<usize> {
        // `Exact`, so the set built here is decided by the schema alone.
        let missing = {
            let mut catalog = self.catalog.lock().unwrap();
            definitions
                .iter()
                .filter_map(|definition| {
                    catalog
                        .prepare(definition, Coverage::Exact, &self.pg_schema)
                        .transpose()
                })
                .collect::<Result<Vec<_>>>()?
        };
        if !definitions.is_empty() {
            (self.report)(IndexEvent::Planned {
                declared: definitions.len() as u32,
                missing: missing
                    .iter()
                    .map(|prepared| prepared.name.clone())
                    .collect(),
                rebuilt: missing
                    .iter()
                    .filter(|prepared| prepared.is_rebuild)
                    .map(|prepared| prepared.name.clone())
                    .collect(),
            });
        }
        for prepared in &missing {
            if let Err(error) = self.build(prepared).await {
                self.resync(&prepared.name).await;
                // Whether the re-read left anything to do is what says if this
                // is a failure at all: a sibling building the same index leaves
                // none, and stopping the backfill over it would stop an indexer
                // for having been beaten to its own work.
                if self
                    .catalog
                    .lock()
                    .unwrap()
                    .prepare(&prepared.definition, Coverage::Exact, &self.pg_schema)?
                    .is_some()
                {
                    return Err(error);
                }
            }
        }
        Ok(missing.len())
    }

    /// Runs the DDL and reads the index back before it counts as existing.
    /// Statements go one at a time: a rebuild's DROP has to land before its
    /// CREATE.
    async fn build(&self, prepared: &Prepared) -> Result<()> {
        for query in &prepared.queries {
            self.db.run(query).await?;
        }
        let entry = self
            .db
            .read(&self.pg_schema, Some(&prepared.name))
            .await?
            .into_iter()
            .find(|entry| entry.name == prepared.name);
        let entry = verify(prepared, entry, &self.pg_schema)?;
        self.catalog.lock().unwrap().set(entry);
        Ok(())
    }

    /// The DDL runs outside a transaction, so a create can commit and its
    /// read-back still fail. Re-reading the index puts the catalog back in
    /// step, so the next attempt plans against the database instead of
    /// retrying a create that can only raise "already exists". If this read
    /// fails too, the next attempt wastes a create before landing here again.
    async fn resync(&self, name: &str) {
        match self.db.read(&self.pg_schema, Some(name)).await {
            Ok(entries) => self.catalog.lock().unwrap().resync(name, entries),
            Err(error) => (self.report)(IndexEvent::ResyncFailed {
                name: name.to_string(),
                error: message_of(&error),
                code: sql_state(&error).map(str::to_string),
            }),
        }
    }

    pub fn report(&self, event: IndexEvent) {
        (self.report)(event)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use futures_util::future::join;

    use super::*;
    use crate::postgres::index_definition::BTREE;

    const SCHEMA: &str = "test_schema";

    fn column(name: &str) -> IndexColumn {
        IndexColumn {
            name: name.to_string(),
            direction: Direction::Asc,
        }
    }

    fn single(table_name: &str, name: &str) -> IndexDefinition {
        IndexDefinition {
            table_name: table_name.to_string(),
            columns: vec![column(name)],
            method: BTREE.to_string(),
        }
    }

    fn composite(table_name: &str, names: &[&str]) -> IndexDefinition {
        IndexDefinition {
            table_name: table_name.to_string(),
            columns: names.iter().map(|name| column(name)).collect(),
            method: BTREE.to_string(),
        }
    }

    /// An index as the indexer itself would have built it.
    fn built(definition: &IndexDefinition, name: &str) -> Entry {
        Entry {
            name: name.to_string(),
            table_name: definition.table_name.clone(),
            method: definition.method.clone(),
            columns: definition.columns.clone(),
            is_valid: true,
            is_unique: false,
            is_partial: false,
            is_expression: false,
            predicate: None,
        }
    }

    fn owner() -> IndexDefinition {
        single("Token", "owner_id")
    }

    fn minted() -> IndexDefinition {
        single("Token", "minted_at")
    }

    /// A database that builds exactly what each statement asks for, and can be
    /// told to fail one.
    #[derive(Default)]
    struct Fake {
        entries: Mutex<Vec<Entry>>,
        statements: Mutex<Vec<String>>,
        /// Index names whose CREATE fails.
        refused: Mutex<HashSet<String>>,
        /// How many of the next reads of a single index fail.
        failing_reads: AtomicUsize,
        running: AtomicUsize,
        most_running: AtomicUsize,
        known: Vec<IndexDefinition>,
    }

    impl Fake {
        fn knowing(known: Vec<IndexDefinition>, entries: Vec<Entry>) -> Self {
            Self {
                known,
                entries: Mutex::new(entries),
                ..Default::default()
            }
        }

        fn creates(&self) -> usize {
            self.statements
                .lock()
                .unwrap()
                .iter()
                .filter(|statement| statement.starts_with("CREATE"))
                .count()
        }
    }

    impl Db for Fake {
        async fn run(&self, sql: &str) -> Result<()> {
            self.statements.lock().unwrap().push(sql.to_string());
            let running = self.running.fetch_add(1, Ordering::SeqCst) + 1;
            self.most_running.fetch_max(running, Ordering::SeqCst);
            // Leaves room for anything that could run alongside to start.
            for _ in 0..8 {
                tokio::task::yield_now().await;
            }
            self.running.fetch_sub(1, Ordering::SeqCst);
            let mut entries = self.entries.lock().unwrap();
            if let Some(definition) = self
                .known
                .iter()
                .find(|definition| definition.create_query(SCHEMA) == sql)
            {
                let name = definition.name();
                if self.refused.lock().unwrap().contains(&name) {
                    bail!("permission denied for table {}", definition.table_name);
                }
                entries.push(built(definition, &name));
            } else {
                entries.retain(|entry| drop_query(SCHEMA, &entry.name) != sql);
            }
            Ok(())
        }

        async fn read(&self, _pg_schema: &str, name: Option<&str>) -> Result<Vec<Entry>> {
            if name.is_some()
                && self
                    .failing_reads
                    .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
                    .is_ok()
            {
                bail!("connection terminated unexpectedly");
            }
            Ok(self
                .entries
                .lock()
                .unwrap()
                .iter()
                .filter(|entry| name.is_none_or(|name| entry.name == name))
                .cloned()
                .collect())
        }
    }

    type Events = Arc<Mutex<Vec<IndexEvent>>>;

    async fn indexes(fake: Fake) -> (Indexes<Fake>, Events) {
        let events: Events = Default::default();
        let sink = events.clone();
        let indexes = Indexes::new(
            fake,
            SCHEMA.to_string(),
            Arc::new(move |event| sink.lock().unwrap().push(event)),
        );
        indexes.reload().await.unwrap();
        (indexes, events)
    }

    fn names(indexes: &Indexes<impl Db>) -> Vec<String> {
        let mut names = indexes
            .catalog
            .lock()
            .unwrap()
            .by_name
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        names.sort();
        names
    }

    fn kinds(events: &Events) -> Vec<&'static str> {
        events
            .lock()
            .unwrap()
            .iter()
            .map(|event| match event {
                IndexEvent::Invalid { .. } => "invalid",
                IndexEvent::Planned { .. } => "planned",
                IndexEvent::Building { .. } => "building",
                IndexEvent::Built { .. } => "built",
                IndexEvent::Failed { .. } => "failed",
                IndexEvent::ResyncFailed { .. } => "resync failed",
                IndexEvent::Committed { .. } => "committed",
            })
            .collect()
    }

    fn reasons(entry: &Entry, definitions: &[IndexDefinition]) -> Vec<Option<String>> {
        definitions
            .iter()
            .map(|definition| entry.reject_reason(definition, Coverage::LeadingColumns))
            .collect()
    }

    #[test]
    fn an_index_serves_a_request_only_when_it_is_usable_for_it() {
        let legacy = built(&owner(), "Token_owner_id");
        let cases = [
            legacy.clone(),
            Entry {
                is_valid: false,
                ..legacy.clone()
            },
            Entry {
                is_partial: true,
                predicate: Some("(owner_id IS NOT NULL)".to_string()),
                ..legacy.clone()
            },
            Entry {
                is_expression: true,
                columns: vec![column("lower(owner_id)")],
                ..legacy.clone()
            },
            Entry {
                method: "hash".to_string(),
                ..legacy.clone()
            },
            Entry {
                table_name: "Transfer".to_string(),
                ..legacy
            },
        ];
        assert_eq!(
            cases
                .iter()
                .map(|entry| entry.reject_reason(&owner(), Coverage::LeadingColumns))
                .collect::<Vec<_>>(),
            vec![
                None,
                Some("PostgreSQL reports it as invalid or not ready".to_string()),
                Some(
                    "it is partial (WHERE (owner_id IS NOT NULL)), so it only covers part of the \
                     table"
                        .to_string()
                ),
                Some("it indexes an expression rather than plain columns".to_string()),
                Some("it uses the hash access method, not btree".to_string()),
                Some("it is on table \"Transfer\"".to_string()),
            ]
        );
    }

    /// A btree on (a, b) is sorted by `a` first, so it serves everything a
    /// btree on (a) does — for a getWhere. Nothing in it is ordered by `b`
    /// alone, and a declared index is held to exactly what it declares.
    #[test]
    fn a_composite_stands_in_for_its_leading_column_only() {
        let entry = built(&composite("Token", &["a", "b"]), "Token_a_b");
        assert_eq!(
            (
                reasons(&entry, &[single("Token", "a"), single("Token", "b")]),
                entry.reject_reason(&single("Token", "a"), Coverage::Exact),
            ),
            (
                vec![
                    None,
                    Some(
                        "it covers (a, b) instead of leading with the requested columns"
                            .to_string()
                    )
                ],
                Some("it covers (a, b) rather than exactly the declared columns".to_string()),
            )
        );
    }

    #[test]
    fn coverage_is_looked_up_across_the_schema_and_never_answered_stale() {
        let mut catalog = Catalog::new(vec![
            built(&composite("Token", &["a", "b"]), "Token_a_b"),
            built(&single("Transfer", "b"), "Transfer_b"),
        ]);
        let before = catalog.covers(&single("Token", "b"), Coverage::LeadingColumns);
        catalog.set(built(&single("Token", "b"), "Token_b"));
        let after_build = catalog.covers(&single("Token", "b"), Coverage::LeadingColumns);
        catalog.resync("Token_b", vec![]);
        let after_drop = catalog.covers(&single("Token", "b"), Coverage::LeadingColumns);
        assert_eq!((before, after_build, after_drop), (false, true, false));
    }

    #[test]
    fn a_build_is_planned_only_for_what_is_missing() {
        let name = owner().name();
        let plan = |entries: Vec<Entry>| {
            Catalog::new(entries)
                .prepare(&owner(), Coverage::LeadingColumns, SCHEMA)
                .map(|prepared| prepared.map(|prepared| (prepared.is_rebuild, prepared.queries)))
                .map_err(|error| error.to_string())
        };
        let create = owner().create_query(SCHEMA);
        assert_eq!(
            [
                plan(vec![built(&owner(), "Token_owner_id")]),
                plan(vec![]),
                plan(vec![Entry {
                    is_valid: false,
                    ..built(&owner(), &name)
                }]),
                plan(vec![Entry {
                    is_valid: false,
                    is_unique: true,
                    ..built(&owner(), &name)
                }]),
            ],
            [
                Ok(None),
                Ok(Some((false, vec![create.clone()]))),
                // An invalid index holding the generated name with exactly this
                // identity can only be one the indexer built.
                Ok(Some((true, vec![drop_query(SCHEMA, &name), create]))),
                Err(format!(
                    "Cannot create the index \"{name}\" in schema \"{SCHEMA}\" for \
                     Token(owner_id) using btree. A different index already holds that name and \
                     the indexer can't safely replace it: PostgreSQL reports it as invalid or \
                     not ready. Drop that index by hand, then restart the indexer."
                )),
            ]
        );
    }

    /// The composite leads with `a`, so matching declared indexes on leading
    /// columns would skip the single-column one on a database that already has
    /// the composite, while a fresh database built both.
    #[test]
    fn a_declared_schema_reaches_the_same_indexes_on_any_database() {
        let declared = [single("Token", "a"), composite("Token", &["a", "b"])];
        let reconciled = |entries: Vec<Entry>| {
            let mut catalog = Catalog::new(entries.clone());
            let mut names = entries
                .into_iter()
                .map(|entry| entry.name)
                .chain(declared.iter().filter_map(|definition| {
                    catalog
                        .prepare(definition, Coverage::Exact, SCHEMA)
                        .unwrap()
                        .map(|prepared| prepared.name)
                }))
                .collect::<Vec<_>>();
            names.sort();
            names
        };
        let upgraded = vec![built(&declared[1], &declared[1].name())];
        assert_eq!(reconciled(vec![]), reconciled(upgraded));
    }

    #[test]
    fn a_build_counts_only_once_postgres_reports_it_back_usable() {
        let prepared = Catalog::default()
            .prepare(&owner(), Coverage::LeadingColumns, SCHEMA)
            .unwrap()
            .unwrap();
        let reason = |entry| {
            verify(&prepared, entry, SCHEMA)
                .map(|entry| entry.name)
                .map_err(|error| error.to_string())
        };
        assert_eq!(
            [
                reason(Some(built(&owner(), &prepared.name))),
                reason(None),
                reason(Some(Entry {
                    is_valid: false,
                    ..built(&owner(), &prepared.name)
                })),
            ],
            [
                Ok(prepared.name.clone()),
                Err(format!(
                    "The index \"{}\" in schema \"{SCHEMA}\" is not usable after its DDL ran: \
                     PostgreSQL has no such index. It was meant to cover Token(owner_id) using \
                     btree. Drop it by hand, then restart the indexer.",
                    prepared.name
                )),
                Err(format!(
                    "The index \"{}\" in schema \"{SCHEMA}\" is not usable after its DDL ran: \
                     PostgreSQL reports it as invalid or not ready. It was meant to cover \
                     Token(owner_id) using btree. Drop it by hand, then restart the indexer.",
                    prepared.name
                )),
            ]
        );
    }

    #[tokio::test]
    async fn concurrent_requests_for_one_index_share_its_build() {
        let fake = Fake::knowing(vec![owner()], vec![]);
        fake.refused.lock().unwrap().insert(owner().name());
        let (indexes, events) = indexes(fake).await;
        join(
            indexes.ensure(vec![owner()], Purpose::Query),
            indexes.ensure(vec![owner()], Purpose::Query),
        )
        .await;
        assert_eq!(
            (indexes.db.creates(), kinds(&events)),
            (1, vec!["building", "failed"])
        );
    }

    #[tokio::test]
    async fn builds_on_one_table_run_one_at_a_time() {
        let transfer = single("Transfer", "owner_id");
        let most_running = |definitions: Vec<IndexDefinition>| async {
            let (indexes, _) = indexes(Fake::knowing(definitions.clone(), vec![])).await;
            indexes.ensure(definitions, Purpose::Query).await;
            indexes.db.most_running.load(Ordering::SeqCst)
        };
        assert_eq!(
            (
                most_running(vec![owner(), minted()]).await,
                most_running(vec![owner(), transfer]).await,
            ),
            (1, 2)
        );
    }

    #[tokio::test]
    async fn a_leading_composite_serves_a_query_but_not_a_declared_index() {
        let wide = composite("Token", &["owner_id", "minted_at"]);
        let (indexes, _) = indexes(Fake::knowing(
            vec![owner()],
            vec![built(&wide, "Token_owner_id_minted_at")],
        ))
        .await;
        join(
            indexes.ensure(vec![owner()], Purpose::Query),
            indexes.ensure(vec![owner()], Purpose::Schema),
        )
        .await;
        assert_eq!(
            (indexes.db.creates(), names(&indexes)),
            (
                1,
                vec![owner().name(), "Token_owner_id_minted_at".to_string()]
            )
        );
    }

    /// Both wait behind the composite's build on the same table. The query is
    /// then served by the composite; had the declared request joined its
    /// flight, it would have resolved with it and never been built.
    #[tokio::test]
    async fn a_declared_index_never_joins_a_query_for_the_same_column() {
        let wide = composite("Token", &["owner_id", "minted_at"]);
        let (indexes, _) = indexes(Fake::knowing(vec![owner(), wide.clone()], vec![])).await;
        futures_util::join!(
            indexes.ensure(vec![wide.clone()], Purpose::Schema),
            indexes.ensure(vec![owner()], Purpose::Query),
            indexes.ensure(vec![owner()], Purpose::Schema),
        );
        assert_eq!(names(&indexes), {
            let mut names = vec![owner().name(), wide.name()];
            names.sort();
            names
        });
    }

    #[tokio::test]
    async fn a_failed_build_is_reported_and_retried_on_the_next_request() {
        let fake = Fake::knowing(vec![owner()], vec![]);
        fake.refused.lock().unwrap().insert(owner().name());
        let (indexes, events) = indexes(fake).await;
        indexes.ensure(vec![owner()], Purpose::Query).await;
        let after_failure = names(&indexes);
        indexes.db.refused.lock().unwrap().clear();
        indexes.ensure(vec![owner()], Purpose::Query).await;
        assert_eq!(
            (after_failure, names(&indexes), kinds(&events)),
            (
                vec![],
                vec![owner().name()],
                vec!["building", "failed", "building", "built"]
            )
        );
    }

    #[tokio::test]
    async fn an_index_built_before_its_read_back_failed_is_not_built_again() {
        let fake = Fake::knowing(vec![owner()], vec![]);
        fake.failing_reads.store(1, Ordering::SeqCst);
        let (indexes, _) = indexes(fake).await;
        indexes.ensure(vec![owner()], Purpose::Query).await;
        indexes.ensure(vec![owner()], Purpose::Query).await;
        assert_eq!(
            (indexes.db.creates(), names(&indexes)),
            (1, vec![owner().name()])
        );
    }

    #[tokio::test]
    async fn a_finalization_keeps_what_it_built_and_retries_only_the_rest() {
        let declared = vec![owner(), minted(), single("Token", "burnt_at")];
        let fake = Fake::knowing(declared.clone(), vec![]);
        fake.refused.lock().unwrap().insert(minted().name());
        let (indexes, _) = indexes(fake).await;
        let failed = indexes.finalize(declared.clone()).await.is_err();
        let after_failure = names(&indexes);
        indexes.db.refused.lock().unwrap().clear();
        let built = indexes.finalize(declared).await.unwrap();
        assert_eq!(
            (failed, after_failure, built, indexes.db.creates()),
            (true, vec![owner().name()], 2, 4)
        );
    }

    #[tokio::test]
    async fn a_reload_replaces_the_catalog_and_reports_unusable_indexes() {
        let (indexes, events) = indexes(Fake::knowing(vec![owner()], vec![])).await;
        indexes.ensure(vec![owner()], Purpose::Query).await;
        *indexes.db.entries.lock().unwrap() = vec![Entry {
            is_valid: false,
            ..built(&minted(), "Token_minted_at")
        }];
        indexes.reload().await.unwrap();
        assert_eq!(
            (names(&indexes), events.lock().unwrap().last().cloned()),
            (
                vec!["Token_minted_at".to_string()],
                Some(IndexEvent::Invalid {
                    names: vec!["Token_minted_at".to_string()]
                })
            )
        );
    }
}
