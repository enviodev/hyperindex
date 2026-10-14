//! The parity report: its JSON shape is a contract for agents (bump
//! `SCHEMA_VERSION` on any breaking change), and the table is for people.

use serde::Serialize;
use serde_json::Value;

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Match,
    Mismatch,
    /// Compared only partly: the reference listing stopped at
    /// `--max-entities` and nothing seen so far differs.
    Incomplete,
    /// Couldn't compare.
    Error,
}

impl Status {
    pub fn exit_code(self) -> i32 {
        match self {
            Status::Match => 0,
            Status::Mismatch => 1,
            Status::Incomplete | Status::Error => 2,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub schema_version: u32,
    pub status: Status,
    pub exit_code: i32,
    /// The block both sides were compared at.
    pub block: Option<u64>,
    pub ours: Side,
    pub reference: Side,
    pub tolerance: Tolerance,
    pub sample_per_type: usize,
    pub summary: Summary,
    pub entities: Vec<EntityReport>,
    pub skipped_types: Vec<Skipped>,
    /// Why the comparison couldn't run at all, or ran degraded.
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
    pub elapsed_secs: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Side {
    /// `postgres` or `graph`.
    pub kind: String,
    pub source: String,
    /// The latest block this side has indexed.
    pub latest_block: Option<u64>,
    pub deployment: Option<String>,
    pub has_indexing_errors: Option<bool>,
    pub requests: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tolerance {
    pub count_pct: f64,
    pub field_mismatches: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub types: usize,
    pub matched: usize,
    pub mismatched: usize,
    pub incomplete: usize,
    pub errored: usize,
    pub field_mismatches: usize,
    pub sampled: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Skipped {
    pub name: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntityReport {
    #[serde(rename = "type")]
    pub name: String,
    /// `match`, `mismatch` or `error` for this type alone.
    pub status: Option<Status>,
    pub ours: Option<u64>,
    pub theirs: Option<u64>,
    /// False when the reference count stopped at `--max-entities`; `theirs` is
    /// then a lower bound and the id sets weren't compared.
    pub theirs_complete: bool,
    /// |ours − theirs| / theirs, in percent.
    pub delta_pct: Option<f64>,
    pub only_ours: Option<u64>,
    pub only_theirs: Option<u64>,
    pub only_ours_examples: Vec<String>,
    pub only_theirs_examples: Vec<String>,
    /// The fields compared on every sampled entity.
    pub fields_compared: Vec<String>,
    pub sampled: usize,
    /// Sampled ids the reference didn't return.
    pub sample_missing: usize,
    pub field_mismatches: usize,
    /// Mismatch count per field, for the fields that had any.
    pub mismatched_fields: std::collections::BTreeMap<String, usize>,
    pub mismatch_examples: Vec<FieldMismatch>,
    pub skipped_fields: Vec<Skipped>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldMismatch {
    pub id: String,
    pub field: String,
    pub ours: Value,
    pub theirs: Value,
}

impl EntityReport {
    /// Whether the entity sets differ by more than the tolerance: counts, ids
    /// on one side only, or sampled ids the reference doesn't have.
    fn sets_differ(&self, tolerance: &Tolerance) -> bool {
        let over = |delta: f64| delta > tolerance.count_pct;
        let counts = self.theirs_complete && self.delta_pct.is_some_and(over);
        let ids = match (self.only_ours, self.only_theirs, self.theirs) {
            (Some(ours), Some(theirs), Some(total)) => over(pct(ours + theirs, total)),
            _ => false,
        };
        // A capped reference count is a lower bound, which still proves a gap
        // when ours falls short of it.
        let capped_short = !self.theirs_complete
            && matches!((self.ours, self.theirs), (Some(ours), Some(theirs)) if ours < theirs);
        counts || ids || capped_short || self.sample_missing > 0
    }

    fn decide(&mut self, tolerance: &Tolerance, fields_over: bool) {
        self.status = Some(if self.error.is_some() {
            Status::Error
        } else if self.sets_differ(tolerance) || (fields_over && self.field_mismatches > 0) {
            Status::Mismatch
        } else if !self.theirs_complete {
            Status::Incomplete
        } else {
            Status::Match
        });
    }
}

pub fn pct(delta: u64, total: u64) -> f64 {
    if total == 0 {
        if delta == 0 {
            0.0
        } else {
            100.0
        }
    } else {
        delta as f64 * 100.0 / total as f64
    }
}

impl Report {
    /// Settles every status: any mismatch fails the parity check, and
    /// otherwise anything left uncompared makes it inconclusive. The field
    /// allowance is for the whole run, not per type.
    pub fn finish(&mut self) {
        let field_mismatches: usize = self.entities.iter().map(|e| e.field_mismatches).sum();
        let fields_over = field_mismatches > self.tolerance.field_mismatches;
        let mut summary = Summary {
            types: self.entities.len(),
            field_mismatches,
            ..Summary::default()
        };
        for entity in &mut self.entities {
            entity.decide(&self.tolerance, fields_over);
            match entity.status {
                Some(Status::Match) => summary.matched += 1,
                Some(Status::Mismatch) => summary.mismatched += 1,
                Some(Status::Incomplete) => summary.incomplete += 1,
                _ => summary.errored += 1,
            }
            summary.sampled += entity.sampled;
        }
        self.status = if !self.errors.is_empty() {
            Status::Error
        } else if summary.mismatched > 0 {
            Status::Mismatch
        } else if summary.errored > 0 {
            Status::Error
        } else if summary.incomplete > 0 {
            Status::Incomplete
        } else {
            Status::Match
        };
        self.exit_code = self.status.exit_code();
        self.summary = summary;
    }

    pub fn render_table(&self) -> String {
        let mut out = String::new();
        let block = self
            .block
            .map(|block| block.to_string())
            .unwrap_or_else(|| "-".to_string());
        out.push_str(&format!("Subgraph parity at block {block}\n"));
        out.push_str(&format!(
            "  ours:      {}{}\n",
            self.ours.source,
            self.ours
                .latest_block
                .map(|b| format!(" (at block {b})"))
                .unwrap_or_default()
        ));
        out.push_str(&format!(
            "  reference: {}{}{}\n",
            self.reference.source,
            self.reference
                .latest_block
                .map(|b| format!(" (at block {b})"))
                .unwrap_or_default(),
            self.reference
                .deployment
                .as_ref()
                .map(|d| format!(", deployment {d}"))
                .unwrap_or_default()
        ));

        if !self.entities.is_empty() {
            out.push('\n');
            let header = [
                "TYPE",
                "OURS",
                "THEIRS",
                "Δ%",
                "ONLY OURS",
                "ONLY THEIRS",
                "SAMPLED",
                "FIELDS",
                "FIELD MISMATCHES",
                "STATUS",
            ];
            let rows: Vec<[String; 10]> = self
                .entities
                .iter()
                .map(|entity| {
                    let opt = |value: Option<u64>| {
                        value
                            .map(|v| v.to_string())
                            .unwrap_or_else(|| "-".to_string())
                    };
                    [
                        entity.name.clone(),
                        opt(entity.ours),
                        match (entity.theirs, entity.theirs_complete) {
                            (Some(theirs), false) => format!("≥{theirs}"),
                            (theirs, _) => opt(theirs),
                        },
                        entity
                            .delta_pct
                            .map(|delta| format!("{delta:.2}"))
                            .unwrap_or_else(|| "-".to_string()),
                        opt(entity.only_ours),
                        opt(entity.only_theirs),
                        if entity.sample_missing > 0 {
                            format!("{} ({} missing)", entity.sampled, entity.sample_missing)
                        } else {
                            entity.sampled.to_string()
                        },
                        entity.fields_compared.len().to_string(),
                        entity.field_mismatches.to_string(),
                        match entity.status {
                            Some(Status::Match) => "ok".to_string(),
                            Some(Status::Mismatch) => "MISMATCH".to_string(),
                            Some(Status::Incomplete) => "partial".to_string(),
                            _ => "ERROR".to_string(),
                        },
                    ]
                })
                .collect();
            let mut widths = header.map(|h| h.chars().count());
            for row in &rows {
                for (width, cell) in widths.iter_mut().zip(row) {
                    *width = (*width).max(cell.chars().count());
                }
            }
            let line = |cells: Vec<&str>| {
                cells
                    .iter()
                    .zip(widths)
                    .enumerate()
                    .map(|(i, (cell, width))| {
                        let pad = width - cell.chars().count();
                        if i == 0 || i == cells.len() - 1 {
                            format!("{cell}{}", " ".repeat(pad))
                        } else {
                            format!("{}{cell}", " ".repeat(pad))
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("  ")
                    .trim_end()
                    .to_string()
            };
            out.push_str(&line(header.to_vec()));
            out.push('\n');
            for row in &rows {
                out.push_str(&line(row.iter().map(String::as_str).collect()));
                out.push('\n');
            }
        }

        let details: Vec<String> = self
            .entities
            .iter()
            .flat_map(|entity| {
                let mut lines = Vec::new();
                if let Some(error) = &entity.error {
                    lines.push(format!("  {}: {error}", entity.name));
                }
                if !entity.only_ours_examples.is_empty() {
                    lines.push(format!(
                        "  {}: only in ours, e.g. {}",
                        entity.name,
                        entity.only_ours_examples.join(", ")
                    ));
                }
                if !entity.only_theirs_examples.is_empty() {
                    lines.push(format!(
                        "  {}: only in the reference, e.g. {}",
                        entity.name,
                        entity.only_theirs_examples.join(", ")
                    ));
                }
                for mismatch in &entity.mismatch_examples {
                    lines.push(format!(
                        "  {} {} .{}: ours {} ≠ theirs {}",
                        entity.name,
                        mismatch.id,
                        mismatch.field,
                        short(&mismatch.ours),
                        short(&mismatch.theirs)
                    ));
                }
                lines
            })
            .collect();
        if !details.is_empty() {
            out.push_str("\nDifferences:\n");
            for line in details {
                out.push_str(&line);
                out.push('\n');
            }
        }
        let skipped: Vec<String> = self
            .skipped_types
            .iter()
            .map(|s| format!("  type {}: {}", s.name, s.reason))
            .chain(self.entities.iter().flat_map(|entity| {
                entity
                    .skipped_fields
                    .iter()
                    .map(move |s| format!("  {}.{}: {}", entity.name, s.name, s.reason))
            }))
            .collect();
        if !skipped.is_empty() {
            out.push_str("\nNot compared:\n");
            for line in skipped {
                out.push_str(&line);
                out.push('\n');
            }
        }
        for warning in &self.warnings {
            out.push_str(&format!("\nWarning: {warning}\n"));
        }
        for error in &self.errors {
            out.push_str(&format!("\nError: {error}\n"));
        }

        out.push_str(&format!(
            "\nResult: {} (exit {}) — {} types: {} match, {} mismatch, {} partial, {} not \
             compared; {} entities sampled, {} field mismatches; {:.1}s\n",
            match self.status {
                Status::Match => "MATCH",
                Status::Mismatch => "MISMATCH",
                Status::Incomplete => "INCOMPLETE",
                Status::Error => "COULD NOT COMPARE",
            },
            self.exit_code,
            self.summary.types,
            self.summary.matched,
            self.summary.mismatched,
            self.summary.incomplete,
            self.summary.errored,
            self.summary.sampled,
            self.summary.field_mismatches,
            self.elapsed_secs
        ));
        out
    }
}

fn short(value: &Value) -> String {
    let rendered = value.to_string();
    match rendered.char_indices().nth(80) {
        Some((at, _)) => format!("{}…", &rendered[..at]),
        None => rendered,
    }
}
