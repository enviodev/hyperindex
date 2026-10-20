//! `envio subgraph diff`: prove a migration by comparing this indexer's data
//! with the graph-node endpoint the subgraph ran on before, at one block.
//!
//! Ours keeps no history, so the block is whatever ours has reached, and the
//! reference is pinned to it with `block: {number: N}`. Per entity type it
//! compares the full id sets (every reference id is paged in by cursor) and a
//! deterministic sample of entities field by field, in graph-node's encodings.

pub mod graph;
pub mod model;
pub mod normalize;
pub mod postgres;
pub mod report;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use futures_util::{stream, StreamExt};
use serde_json::Value;
use sha2::{Digest, Sha256};

use graph::{Exposed, GraphClient};
use model::{Entity, Field, FieldKind, Model};
use postgres::{Column, PgConfig, PgSide, Planned, Relation};
use report::{
    DanglingRelation, EntityReport, FieldMismatch, Recheck, Report, Side, Skipped, Status,
    Tolerance,
};

use crate::utils::project_env::ProjectEnv;

const EXAMPLES: usize = 5;
const MISMATCH_EXAMPLES: usize = 10;
/// Ids on one side only re-asked by `id_in` per type and side, and per query.
const RECHECK_CAP: usize = 1000;
const RECHECK_BATCH: usize = 100;
const WAIT_POLL: Duration = Duration::from_secs(2);

#[derive(Debug, Clone)]
pub struct Options {
    pub endpoint: String,
    pub ours: Option<String>,
    pub block: Option<u64>,
    pub sample: usize,
    pub types: Vec<String>,
    pub tolerance_pct: f64,
    pub max_field_mismatches: usize,
    pub concurrency: usize,
    pub max_entities: Option<usize>,
    pub headers: Vec<String>,
    pub allow_indexing_errors: bool,
    pub timeout: Duration,
    pub wait: Duration,
    /// The subgraph manifest `--config` names; `subgraph.yaml` when `None`.
    pub manifest: Option<PathBuf>,
    pub progress: bool,
}

enum Ours {
    Postgres(PgSide),
    Graph {
        client: GraphClient,
        exposed: Exposed,
    },
}

struct Run<'a> {
    options: &'a Options,
    block: u64,
    ours: &'a Ours,
    reference: &'a GraphClient,
    reference_exposed: &'a Exposed,
}

pub async fn run(project_root: &Path, options: &Options) -> Report {
    let started = Instant::now();
    let mut report = Report {
        schema_version: report::SCHEMA_VERSION,
        status: Status::Error,
        exit_code: 2,
        block: None,
        ours: Side {
            kind: if options.ours.is_some() {
                "graph"
            } else {
                "postgres"
            }
            .to_string(),
            source: options.ours.clone().unwrap_or_default(),
            latest_block: None,
            deployment: None,
            has_indexing_errors: None,
            requests: None,
        },
        reference: Side {
            kind: "graph".to_string(),
            source: options.endpoint.clone(),
            latest_block: None,
            deployment: None,
            has_indexing_errors: None,
            requests: None,
        },
        tolerance: Tolerance {
            count_pct: options.tolerance_pct,
            field_mismatches: options.max_field_mismatches,
        },
        sample_per_type: options.sample,
        summary: Default::default(),
        entities: vec![],
        skipped_types: vec![],
        errors: vec![],
        warnings: vec![],
        elapsed_secs: 0.0,
    };
    if let Err(err) = compare(project_root, options, &mut report).await {
        report.errors.push(format!("{err:#}"));
    }
    report.elapsed_secs = (started.elapsed().as_secs_f64() * 10.0).round() / 10.0;
    report.finish();
    report
}

async fn compare(project_root: &Path, options: &Options, report: &mut Report) -> Result<()> {
    let model = load_model(project_root, options.manifest.as_deref())?;
    report.skipped_types = model
        .skipped
        .iter()
        .map(|(name, reason)| Skipped {
            name: name.clone(),
            reason: reason.clone(),
        })
        .collect();
    let entities = select_types(&model, &options.types)?;

    let reference = GraphClient::new(
        &options.endpoint,
        &options.headers,
        options.concurrency,
        options.timeout,
    )?;

    let (ours, ours_block) = match &options.ours {
        Some(url) => {
            let client = GraphClient::new(url, &[], options.concurrency, options.timeout)?;
            let meta = client.meta().await.context("Failed to read ours' _meta")?;
            report.ours.latest_block = Some(meta.block);
            report.ours.deployment = meta.deployment.clone();
            report.ours.has_indexing_errors = Some(meta.has_indexing_errors);
            let exposed = exposed_or_guess(&client, "ours", &mut report.warnings).await;
            (Ours::Graph { client, exposed }, meta.block)
        }
        None => {
            let config = PgConfig::from_env(&ProjectEnv::new(project_root))?;
            report.ours.source = config.describe();
            let side = PgSide::connect(&config).await?;
            let block = side.progress_block().await?;
            report.ours.latest_block = Some(block);
            (Ours::Postgres(side), block)
        }
    };

    let mut meta = reference
        .meta()
        .await
        .context("Failed to read the reference's _meta")?;
    // Ours' block is fixed by its snapshot, so a reference that trails it at
    // the chain head can only be compared once it gets there.
    let waiting = Instant::now();
    while meta.block < ours_block && waiting.elapsed() < options.wait {
        tokio::time::sleep(WAIT_POLL.min(options.wait.saturating_sub(waiting.elapsed()))).await;
        meta = reference
            .meta()
            .await
            .context("Failed to read the reference's _meta")?;
    }
    report.reference.latest_block = Some(meta.block);
    report.reference.deployment = meta.deployment.clone();
    report.reference.has_indexing_errors = Some(meta.has_indexing_errors);

    let block = pin_block(options.block, ours_block, meta.block)?;
    if meta.has_indexing_errors && !options.allow_indexing_errors {
        bail!(
            "The reference reports indexing errors (_meta.hasIndexingErrors), so its data stops \
             at the block that failed. Pass --allow-indexing-errors to compare anyway."
        );
    }
    // A pruned or grafted deployment refuses every query pinned before its
    // first block; graph-node says which block that is.
    if let Err(err) = reference
        .query(&format!(
            "{{ _meta(block: {{number: {block}}}) {{ block {{ number }} }} }}"
        ))
        .await
    {
        let message = format!("{err:#}");
        let first = message
            .split_once("only has data starting at block number ")
            .and_then(|(_, rest)| rest.split_whitespace().next())
            .and_then(|number| number.parse::<u64>().ok());
        if let Some(first) = first {
            bail!(
                "The reference answers only from block {first} on (its history was pruned, or it \
                 was grafted there), and ours is at block {block}. Index past block {first} and \
                 compare again."
            );
        }
    }
    report.block = Some(block);

    let reference_exposed =
        exposed_or_guess(&reference, "the reference", &mut report.warnings).await;
    let context = Run {
        options,
        block,
        ours: &ours,
        reference: &reference,
        reference_exposed: &reference_exposed,
    };

    // Built eagerly: a stream closure borrowing each entity trips the
    // higher-ranked lifetime check on the napi future's `Send` bound.
    let pending: Vec<_> = entities
        .iter()
        .enumerate()
        .map(|(index, entity)| diff_one(&context, index, entity))
        .collect();
    let mut results: Vec<(usize, EntityReport)> = stream::iter(pending)
        .buffer_unordered(options.concurrency.max(1))
        .collect()
        .await;
    results.sort_by_key(|(index, _)| *index);
    report.entities = results.into_iter().map(|(_, entity)| entity).collect();

    if let Ours::Graph { client, .. } = &ours {
        report.ours.requests = Some(client.requests());
        if let Ok(after) = client.meta().await {
            if after.block != ours_block {
                report.warnings.push(format!(
                    "Ours advanced from block {ours_block} to {} while the diff ran, so some \
                     differences may be drift. Stop the indexer, or rerun.",
                    after.block
                ));
            }
        }
    }
    report.reference.requests = Some(reference.requests());
    Ok(())
}

fn load_model(project_root: &Path, manifest: Option<&Path>) -> Result<Model> {
    let manifest_path = manifest
        .map(Path::to_path_buf)
        .unwrap_or_else(|| project_root.join(crate::subgraph::DEFAULT_MANIFEST));
    let manifest = std::fs::read_to_string(&manifest_path).map_err(|_| match manifest {
        Some(_) => anyhow!("No subgraph manifest at {}.", manifest_path.display()),
        None => anyhow!(
            "No subgraph.yaml in {}. Run `envio subgraph diff` inside the subgraph project (or \
             pass -d <dir>, and --config for a manifest of another name).",
            project_root.display()
        ),
    })?;
    let schema_file = serde_yaml::from_str::<serde_yaml::Value>(&manifest)
        .ok()
        .and_then(|value| Some(value.get("schema")?.get("file")?.as_str()?.to_string()))
        .unwrap_or_else(|| "./schema.graphql".to_string());
    // graph-cli resolves the schema path against the manifest's directory.
    let schema_path = manifest_path
        .parent()
        .unwrap_or(project_root)
        .join(&schema_file);
    let schema = std::fs::read_to_string(&schema_path)
        .with_context(|| format!("Failed to read {}", schema_path.display()))?;
    Model::from_schema(&schema)
}

fn select_types<'a>(model: &'a Model, types: &[String]) -> Result<Vec<&'a Entity>> {
    if types.is_empty() {
        return Ok(model.entities.iter().collect());
    }
    // An aggregation's name selects each of its intervals.
    let named = |entity: &Entity, name: &str| entity.name == name || entity.graph_type() == name;
    let unknown: Vec<&str> = types
        .iter()
        .filter(|name| !model.entities.iter().any(|e| named(e, name)))
        .map(String::as_str)
        .collect();
    if !unknown.is_empty() {
        bail!(
            "--type names no entity of this subgraph: {}. Its entities: {}.",
            unknown.join(", "),
            model
                .entities
                .iter()
                .map(|e| e.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    Ok(model
        .entities
        .iter()
        .filter(|entity| types.iter().any(|name| named(entity, name)))
        .collect())
}

/// The one block both sides can answer for: ours has no history, so it's the
/// block ours has reached, and the reference has to have reached it too.
pub fn pin_block(requested: Option<u64>, ours: u64, reference: u64) -> Result<u64> {
    match requested {
        Some(block) if block > ours => bail!(
            "Ours has only reached block {ours}, so it can't answer for block {block}. Wait for \
             it to get there, or omit --block."
        ),
        Some(block) if block < ours => bail!(
            "Ours is at block {ours} and keeps no history, so it can only be compared at that \
             block. Omit --block, or stop the indexer at block {block} and rerun."
        ),
        _ => {}
    }
    if reference < ours {
        bail!(
            "The reference has only indexed up to block {reference}, behind ours at {ours}, and \
             graph-node can't answer for a block it hasn't reached. Rerun once it has (or give \
             it longer with --wait), or compare an indexer stopped at or before block \
             {reference}."
        );
    }
    Ok(ours)
}

async fn exposed_or_guess(client: &GraphClient, who: &str, warnings: &mut Vec<String>) -> Exposed {
    match client.exposed().await {
        Ok(exposed) => exposed,
        Err(err) => {
            warnings.push(format!(
                "Introspection failed on {who} ({err:#}); using the other side's collection \
                 names (or graph-node's naming rule) and selecting every schema field."
            ));
            Exposed::default()
        }
    }
}

/// An aggregation interval's collection carries the interval graph-node
/// requires: `candleStats(interval: hour)`.
fn served_collection(collection: String, entity: &Entity) -> String {
    match &entity.served {
        Some(served) => format!("{collection}({})", served.args),
        None => collection,
    }
}

/// The collection field listing `entity` on a side. One that can't be
/// introspected is a graph-node API for the same schema, so it names
/// collections as the other side does, or by graph-node's rule.
fn collection(exposed: &Exposed, other: &Exposed, entity: &str, who: &str) -> Result<String> {
    if exposed.collections.is_empty() {
        return Ok(other
            .collections
            .get(entity)
            .cloned()
            .unwrap_or_else(|| graph::plural_collection(entity)));
    }
    exposed
        .collections
        .get(entity)
        .cloned()
        .ok_or_else(|| anyhow!("{who} has no collection for {entity} — is it the same subgraph?"))
}

async fn diff_one(context: &Run<'_>, index: usize, entity: &Entity) -> (usize, EntityReport) {
    let mut entity_report = EntityReport {
        name: entity.name.clone(),
        theirs_complete: true,
        ..Default::default()
    };
    if let Err(err) = diff_entity(context, entity, &mut entity_report).await {
        entity_report.error = Some(format!("{err:#}"));
    }
    if context.options.progress {
        eprintln!("{}", progress_line(&entity_report));
    }
    (index, entity_report)
}

/// A field ours stores and the reference serves, with ours' column for it.
struct Compared<'a> {
    field: &'a Field,
    column: Option<Column>,
    /// The table of the entity a leniently resolved relation points at.
    relation: Option<Relation>,
}

async fn diff_entity(context: &Run<'_>, entity: &Entity, out: &mut EntityReport) -> Result<()> {
    let options = context.options;
    let empty = Exposed::default();
    let our_exposed = match context.ours {
        Ours::Graph { exposed, .. } => exposed,
        Ours::Postgres(_) => &empty,
    };
    let their_collection = served_collection(
        collection(
            context.reference_exposed,
            our_exposed,
            entity.graph_type(),
            "The reference",
        )?,
        entity,
    );
    let their_fields = context.reference_exposed.fields.get(entity.graph_type());

    let (our_columns, our_collection, our_fields) = match context.ours {
        Ours::Postgres(pg) => {
            let columns = pg.columns(&entity.name).await?;
            if columns.is_empty() {
                bail!("Ours has no table for {}", entity.name);
            }
            (Some(columns), None, None)
        }
        Ours::Graph { exposed, .. } => (
            None,
            Some(served_collection(
                collection(
                    exposed,
                    context.reference_exposed,
                    entity.graph_type(),
                    "Ours",
                )?,
                entity,
            )),
            exposed.fields.get(entity.graph_type()),
        ),
    };

    let mut compared = Vec::new();
    for field in &entity.fields {
        let skip = |reason: &str| Skipped {
            name: field.name.clone(),
            reason: reason.to_string(),
        };
        if their_fields.is_some_and(|fields| !fields.contains(&field.name)) {
            out.skipped_fields
                .push(skip("not in the reference's schema"));
            continue;
        }
        if our_fields.is_some_and(|fields| !fields.contains(&field.name)) {
            out.skipped_fields.push(skip("not in ours' schema"));
            continue;
        }
        let column = match &our_columns {
            Some(columns) => match columns.get(&postgres::column_for(field)) {
                Some(column) => Some(column.clone()),
                None => {
                    out.skipped_fields.push(skip("not stored by envio"));
                    continue;
                }
            },
            None => None,
        };
        out.fields_compared.push(field.name.clone());
        compared.push(Compared {
            field,
            column,
            relation: None,
        });
    }
    if let Ours::Postgres(pg) = context.ours {
        resolve_relations(pg, &mut compared).await?;
    }
    for derived in &entity.derived {
        out.skipped_fields.push(Skipped {
            name: derived.clone(),
            reason: "derived (@derivedFrom), not stored".to_string(),
        });
    }

    let ours_ids = async {
        match context.ours {
            Ours::Postgres(pg) => pg.ids(&entity.name).await,
            Ours::Graph { client, .. } => Ok(client
                .ids(our_collection.as_deref().unwrap_or_default(), None, None)
                .await?
                .ids),
        }
    };
    let theirs_ids =
        context
            .reference
            .ids(&their_collection, Some(context.block), options.max_entities);
    let (ours_ids, theirs_ids) = tokio::join!(ours_ids, theirs_ids);
    let canonical_ids = |ids: &[Value]| -> BTreeSet<String> {
        ids.iter()
            .filter_map(|id| normalize::id(entity.id, id))
            .collect()
    };
    let mut ours_ids = canonical_ids(&ours_ids.context("Failed to list ours' ids")?);
    let theirs = theirs_ids.context("Failed to list the reference's ids")?;
    let mut theirs_ids = canonical_ids(&theirs.ids);
    if theirs.complete {
        let listings = Listings {
            entity,
            their_collection: &their_collection,
            our_collection: our_collection.as_deref().unwrap_or_default(),
        };
        recheck_listings(
            context,
            &listings,
            &mut ours_ids,
            &mut theirs_ids,
            &mut out.recheck,
        )
        .await;
    }

    out.ours = Some(ours_ids.len() as u64);
    out.theirs = Some(theirs_ids.len() as u64);
    out.theirs_complete = theirs.complete;
    // A capped reference count is a lower bound: it only bounds the gap when
    // ours falls short of it.
    out.delta_pct = (theirs.complete || ours_ids.len() < theirs_ids.len()).then(|| {
        report::pct(
            (ours_ids.len() as i64 - theirs_ids.len() as i64).unsigned_abs(),
            theirs_ids.len() as u64,
        )
    });

    let candidates: Vec<&String> = if theirs.complete {
        let only_ours: Vec<&String> = ours_ids.difference(&theirs_ids).collect();
        let only_theirs: Vec<&String> = theirs_ids.difference(&ours_ids).collect();
        out.only_ours = Some(only_ours.len() as u64);
        out.only_theirs = Some(only_theirs.len() as u64);
        out.only_ours_examples = only_ours
            .iter()
            .take(EXAMPLES)
            .map(|s| s.to_string())
            .collect();
        out.only_theirs_examples = only_theirs
            .iter()
            .take(EXAMPLES)
            .map(|s| s.to_string())
            .collect();
        ours_ids.intersection(&theirs_ids).collect()
    } else {
        ours_ids.iter().collect()
    };
    let sample = sample(candidates, options.sample);
    out.sampled = sample.len();
    if sample.is_empty() || compared.is_empty() && theirs.complete {
        return Ok(());
    }

    let id_udt = our_columns
        .as_ref()
        .and_then(|columns| columns.get("id"))
        .map(|column| column.udt.clone())
        .unwrap_or_else(|| "text".to_string());
    // A nested list multiplies what one query asks graph-node for.
    let batch = if entity
        .fields
        .iter()
        .any(|f| f.list && matches!(f.kind, FieldKind::Entity { .. }))
    {
        20
    } else {
        100
    };
    let mut batches = sample.chunks(batch).map(|chunk| {
        chunk
            .iter()
            .map(|id| Value::String(id.to_string()))
            .collect::<Vec<_>>()
    });
    let first = batches.next().unwrap_or_default();

    // The first batch settles which fields both sides can serve. graph-node
    // fails a whole query over one field it can't resolve — a non-null
    // relation to an entity it doesn't have — so that field is dropped and
    // reported rather than losing the type.
    let first_rows = loop {
        let fields: Vec<&str> = compared.iter().map(|c| c.field.name.as_str()).collect();
        let selection = graph::selection(entity, &fields);
        let plan = plan_of(&compared);
        let fetch = Fetch {
            entity,
            plan: &plan,
            id_udt: &id_udt,
            selection: &selection,
            their_collection: &their_collection,
            our_collection: our_collection.as_deref().unwrap_or_default(),
        };
        match fetch_batch(context, &fetch, first.clone()).await {
            Ok(rows) => break rows,
            Err(BatchError { ours, error }) => {
                let message = format!("{error:#}");
                let Some(at) = compared
                    .iter()
                    .position(|c| message.contains(&format!("`{}`", c.field.name)))
                else {
                    return Err(error);
                };
                let dropped = compared.remove(at).field.name.clone();
                out.fields_compared.retain(|name| *name != dropped);
                let skipped = Skipped {
                    name: dropped,
                    reason: format!("unreadable: {message}"),
                };
                // A field ours can't serve breaks every query that selects it,
                // which fails parity; one the reference can't is its own defect.
                if ours {
                    out.unservable_fields.push(skipped);
                } else {
                    out.skipped_fields.push(skipped);
                }
            }
        }
    };

    let fields: Vec<&str> = compared.iter().map(|c| c.field.name.as_str()).collect();
    let selection = graph::selection(entity, &fields);
    let plan = plan_of(&compared);
    let fetch = Fetch {
        entity,
        plan: &plan,
        id_udt: &id_udt,
        selection: &selection,
        their_collection: &their_collection,
        our_collection: our_collection.as_deref().unwrap_or_default(),
    };
    let pending: Vec<_> = batches
        .map(|ids| fetch_batch(context, &fetch, ids))
        .collect();
    let mut fetched: Vec<Result<RowPair, BatchError>> = stream::iter(pending)
        .buffer_unordered(options.concurrency.max(1))
        .collect()
        .await;
    fetched.push(Ok(first_rows));

    let mut our_rows = BTreeMap::new();
    let mut their_rows = BTreeMap::new();
    let mut dangling: BTreeMap<&str, usize> = BTreeMap::new();
    for result in fetched {
        let (mut ours, theirs) = result.map_err(|failed| failed.error)?;
        for row in &mut ours {
            for compared in compared.iter().filter(|c| c.relation.is_some()) {
                let name = compared.field.name.as_str();
                let count = row
                    .as_object_mut()
                    .and_then(|row| row.remove(&postgres::dangling_key(name)))
                    .and_then(|count| count.as_u64())
                    .unwrap_or(0);
                if count > 0 {
                    *dangling.entry(name).or_default() += count as usize;
                }
            }
        }
        for (rows, into) in [(ours, &mut our_rows), (theirs, &mut their_rows)] {
            for row in rows {
                if let Some(id) = normalize::id(entity.id, &row["id"]) {
                    into.insert(id, row);
                }
            }
        }
    }
    out.dangling_relations = compared
        .iter()
        .filter_map(|c| {
            Some(DanglingRelation {
                field: c.field.name.clone(),
                target: c.field.target.clone()?,
                list: c.field.list,
                count: *dangling.get(c.field.name.as_str())?,
            })
        })
        .collect();

    let compare = |ours: &Value, theirs: &Value| -> Vec<FieldMismatch> {
        let mut mismatches = Vec::new();
        for compared in &compared {
            let field = compared.field;
            let mut our_value = normalize::canonical(&field.kind, field.list, &ours[&field.name]);
            let their_value = normalize::canonical(&field.kind, field.list, &theirs[&field.name]);
            // graph-node serves at most `first` entities of a stored list.
            if let (FieldKind::Entity { .. }, Value::Array(ours), Value::Array(theirs)) =
                (&field.kind, &mut our_value, &their_value)
            {
                if theirs.len() == graph::PAGE_SIZE {
                    ours.truncate(graph::PAGE_SIZE);
                }
            }
            if our_value != their_value {
                mismatches.push(FieldMismatch {
                    id: String::new(),
                    field: field.name.clone(),
                    ours: our_value,
                    theirs: their_value,
                });
            }
        }
        mismatches
    };

    // Sampled ids that differ: `None` when a side didn't return the entity.
    let mut differing: BTreeMap<String, Option<Vec<FieldMismatch>>> = BTreeMap::new();
    for id in &sample {
        let first = match (our_rows.get(*id), their_rows.get(*id)) {
            (Some(ours), Some(theirs)) => {
                let mismatches = compare(ours, theirs);
                if mismatches.is_empty() {
                    continue;
                }
                Some(mismatches)
            }
            _ => None,
        };
        differing.insert(id.to_string(), first);
    }
    // Indexers behind one gateway can answer the same pinned query
    // differently; a difference counts only if the reference repeats it.
    let again: Vec<Value> = differing
        .keys()
        .filter(|id| our_rows.contains_key(*id))
        .map(|id| Value::String(id.clone()))
        .collect();
    if !again.is_empty() {
        out.recheck.asked += again.len();
        match context
            .reference
            .recheck(
                &their_collection,
                &selection,
                &again,
                Some(context.block),
                batch,
            )
            .await
        {
            Ok(rows) => {
                for row in rows {
                    let Some(id) = normalize::id(entity.id, &row["id"]) else {
                        continue;
                    };
                    let (Some(ours), Some(entry)) = (our_rows.get(&id), differing.get_mut(&id))
                    else {
                        continue;
                    };
                    let now = compare(ours, &row);
                    if now.is_empty() {
                        out.recheck.samples_resolved += 1;
                        differing.remove(&id);
                    } else {
                        *entry = Some(now);
                    }
                }
            }
            Err(err) => out.recheck.error = Some(format!("{err:#}")),
        }
    }

    for id in &sample {
        match differing.remove(id.as_str()) {
            None => {}
            Some(None) => out.sample_missing += 1,
            Some(Some(mismatches)) => {
                for mismatch in mismatches {
                    out.field_mismatches += 1;
                    *out.mismatched_fields
                        .entry(mismatch.field.clone())
                        .or_default() += 1;
                    if out.mismatch_examples.len() < MISMATCH_EXAMPLES {
                        out.mismatch_examples.push(FieldMismatch {
                            id: id.to_string(),
                            ..mismatch
                        });
                    }
                }
            }
        }
    }
    Ok(())
}

/// Where one type's ids are listed on each side.
struct Listings<'a> {
    entity: &'a Entity,
    their_collection: &'a str,
    our_collection: &'a str,
}

/// A gateway's paged listing can come back short (or, in principle, list
/// what it doesn't have), so before an id counts as on one side only, the
/// side missing it is asked for it by `id_in` at the same block. Ours'
/// Postgres snapshot is its own truth; a Graph endpoint of ours is asked too.
async fn recheck_listings(
    context: &Run<'_>,
    listings: &Listings<'_>,
    ours_ids: &mut BTreeSet<String>,
    theirs_ids: &mut BTreeSet<String>,
    recheck: &mut Recheck,
) {
    let only_ours: Vec<String> = ours_ids.difference(theirs_ids).cloned().collect();
    let only_theirs: Vec<String> = theirs_ids.difference(ours_ids).cloned().collect();
    recheck.unchecked +=
        only_ours.len().saturating_sub(RECHECK_CAP) + only_theirs.len().saturating_sub(RECHECK_CAP);
    let only_ours = &only_ours[..only_ours.len().min(RECHECK_CAP)];
    let only_theirs = &only_theirs[..only_theirs.len().min(RECHECK_CAP)];
    let asked: Vec<Value> = only_ours
        .iter()
        .chain(only_theirs)
        .map(|id| Value::String(id.clone()))
        .collect();
    if asked.is_empty() {
        return;
    }
    let present = |rows: Vec<Value>| -> BTreeSet<String> {
        rows.iter()
            .filter_map(|row| normalize::id(listings.entity.id, &row["id"]))
            .collect()
    };

    recheck.asked += asked.len();
    let found = match context
        .reference
        .recheck(
            listings.their_collection,
            "",
            &asked,
            Some(context.block),
            RECHECK_BATCH,
        )
        .await
    {
        Ok(rows) => present(rows),
        Err(err) => {
            recheck.error = Some(format!("{err:#}"));
            return;
        }
    };
    for id in only_ours {
        if found.contains(id) {
            theirs_ids.insert(id.clone());
            recheck.listing_missed += 1;
        }
    }
    for id in only_theirs {
        if !found.contains(id) {
            theirs_ids.remove(id);
            recheck.listing_phantom += 1;
        }
    }

    let Ours::Graph { client, .. } = context.ours else {
        return;
    };
    let still: Vec<Value> = only_theirs
        .iter()
        .filter(|id| theirs_ids.contains(*id))
        .map(|id| Value::String(id.clone()))
        .collect();
    if still.is_empty() {
        return;
    }
    recheck.asked += still.len();
    match client
        .recheck(listings.our_collection, "", &still, None, RECHECK_BATCH)
        .await
    {
        Ok(rows) => {
            for id in present(rows) {
                if theirs_ids.contains(&id) && ours_ids.insert(id) {
                    recheck.ours_listing_missed += 1;
                }
            }
        }
        Err(err) => recheck.error = Some(format!("{err:#}")),
    }
}

/// Ours stores a relation as the id it points at, which graph-node resolves by
/// joining the target's table: a nullable relation to an entity that doesn't
/// exist is served as `null`, and a list leaves such ids out. (A non-null one
/// fails the query, which the first batch already handles.) Each such field
/// gets the table to check against, when ours has one for the target; an
/// interface has none, and is compared as stored.
async fn resolve_relations(pg: &PgSide, compared: &mut [Compared<'_>]) -> Result<()> {
    let mut id_udts: BTreeMap<String, Option<String>> = BTreeMap::new();
    for compared in compared.iter_mut() {
        let field = compared.field;
        let Some(target) = &field.target else {
            continue;
        };
        if !(field.nullable || field.list) {
            continue;
        }
        if !id_udts.contains_key(target) {
            let columns = pg.columns(target).await?;
            id_udts.insert(
                target.clone(),
                columns.get("id").map(|column| column.udt.clone()),
            );
        }
        compared.relation = id_udts[target].clone().map(|id_udt| Relation {
            table: target.clone(),
            id_udt,
        });
    }
    Ok(())
}

fn plan_of(compared: &[Compared<'_>]) -> Vec<Planned> {
    compared
        .iter()
        .filter_map(|c| {
            c.column.clone().map(|column| Planned {
                field: c.field.name.clone(),
                column,
                relation: c.relation.clone(),
            })
        })
        .collect()
}

struct Fetch<'a> {
    entity: &'a Entity,
    plan: &'a [Planned],
    id_udt: &'a str,
    selection: &'a str,
    their_collection: &'a str,
    our_collection: &'a str,
}

/// One batch of sampled entities from both sides.
/// One batch of sampled rows: ours, then the reference's.
type RowPair = (Vec<Value>, Vec<Value>);

/// A sampled-rows read that failed, and on which side.
struct BatchError {
    ours: bool,
    error: anyhow::Error,
}

async fn fetch_batch(
    context: &Run<'_>,
    fetch: &Fetch<'_>,
    ids: Vec<Value>,
) -> Result<RowPair, BatchError> {
    let ours = async {
        match context.ours {
            Ours::Postgres(pg) => pg.rows(fetch.entity, fetch.plan, fetch.id_udt, &ids).await,
            Ours::Graph { client, .. } => {
                client
                    .rows(fetch.our_collection, fetch.selection, &ids, None)
                    .await
            }
        }
    };
    let theirs = context.reference.rows(
        fetch.their_collection,
        fetch.selection,
        &ids,
        Some(context.block),
    );
    let (ours, theirs) = tokio::join!(ours, theirs);
    let ours = ours.map_err(|error| BatchError {
        ours: true,
        error: error.context("Failed to read ours' sampled rows"),
    })?;
    let theirs = theirs.map_err(|error| BatchError {
        ours: false,
        error: error.context("Failed to read the reference's sampled rows"),
    })?;
    Ok((ours, theirs))
}

/// The first `size` ids by the hash of each id: the same ids on every run
/// against the same data, spread across the id space rather than its start.
pub fn sample(candidates: Vec<&String>, size: usize) -> Vec<&String> {
    let mut keyed: Vec<([u8; 32], &String)> = candidates
        .into_iter()
        .map(|id| (Sha256::digest(id.as_bytes()).into(), id))
        .collect();
    keyed.sort();
    keyed.into_iter().take(size).map(|(_, id)| id).collect()
}

fn progress_line(entity: &EntityReport) -> String {
    match &entity.error {
        Some(error) => format!("[diff] {}: {error}", entity.name),
        None => format!(
            "[diff] {}: ours {}, theirs {}{}, sampled {}, field mismatches {}",
            entity.name,
            entity.ours.unwrap_or_default(),
            entity.theirs.unwrap_or_default(),
            if entity.theirs_complete { "" } else { "+" },
            entity.sampled,
            entity.field_mismatches
        ),
    }
}

#[cfg(test)]
mod tests;
