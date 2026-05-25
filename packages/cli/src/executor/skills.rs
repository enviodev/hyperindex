use anyhow::{Context, Result};
use include_dir::DirEntry;
use serde::Deserialize;
use std::{collections::HashSet, fs, path::Path};

use crate::{project_paths::ParsedProjectPaths, template_dirs::TemplateDirs};

/// Names this CLI shipped before the introduction of the `managed-by`
/// metadata marker. Used only to clean up pre-marker installations during
/// `envio skills update`. Adding a name here is a one-way ratchet: once
/// it's listed, every future update will delete a same-named directory in
/// the user's project if that project has no marker-bearing skills at all.
const LEGACY_SKILL_NAMES: &[&str] = &[
    "indexing-blocks",
    "indexing-config",
    "indexing-external-calls",
    "indexing-factory",
    "indexing-filters",
    "indexing-handler-syntax",
    "indexing-multichain",
    "indexing-performance",
    "indexing-schema",
    "indexing-traces",
    "indexing-transactions",
    "indexing-wildcard",
    "subgraph-migration",
    "testing",
    "migrate-from-subgraph",
];

const MANAGED_BY_ENVIO: &str = "envio";

#[derive(Deserialize)]
struct SkillFrontmatter {
    metadata: Option<SkillMetadata>,
}

#[derive(Deserialize)]
struct SkillMetadata {
    #[serde(rename = "managed-by")]
    managed_by: Option<String>,
}

/// Reads `<dir>/SKILL.md` and returns the value of `metadata.managed-by`
/// from its YAML frontmatter, if present and well-formed. Anything else
/// (missing file, malformed frontmatter, missing field) returns `None`
/// so the caller can treat it as "not managed."
fn read_managed_by(skill_dir: &Path) -> Option<String> {
    let content = fs::read_to_string(skill_dir.join("SKILL.md")).ok()?;
    let after_open = content.strip_prefix("---")?.trim_start_matches('\n');
    let close = after_open.find("\n---")?;
    let frontmatter = &after_open[..close];
    let parsed: SkillFrontmatter = serde_yaml::from_str(frontmatter).ok()?;
    parsed.metadata?.managed_by
}

/// Re-extracts every skill shipped by this CLI version into
/// `<project_root>/.claude/skills/<name>/`.
///
/// Cleanup before extraction follows the user's project state:
/// 1. If any directory under `.claude/skills/` declares
///    `metadata.managed-by: envio` in its `SKILL.md`, delete every
///    envio-managed directory (regardless of whether the name is still
///    shipped). User-authored skills are left untouched.
/// 2. Otherwise the project predates the marker. Delete any directory
///    whose name matches a name this CLI has ever shipped (current set
///    plus `LEGACY_SKILL_NAMES`) so stale pre-rename copies are removed
///    before the fresh ones get written.
pub fn run_update(project_paths: &ParsedProjectPaths) -> Result<()> {
    let project_root = &project_paths.project_root;
    let skills_root = project_root.join(".claude").join("skills");
    fs::create_dir_all(&skills_root)
        .with_context(|| format!("Failed creating {}", skills_root.display()))?;

    let template_dirs = TemplateDirs::new();
    let shipped = template_dirs
        .get_shared_skills_dir()
        .context("Failed locating shipped skills directory")?;

    let shipped_names: Vec<String> = shipped
        .entries()
        .iter()
        .filter_map(|e| match e {
            DirEntry::Dir(d) => d
                .path()
                .file_name()
                .and_then(|n| n.to_str())
                .map(String::from),
            DirEntry::File(_) => None,
        })
        .collect();

    let managed_existing: Vec<String> = fs::read_dir(&skills_root)
        .with_context(|| format!("Failed reading {}", skills_root.display()))?
        .filter_map(|entry| {
            let entry = entry.ok()?;
            if !entry.file_type().ok()?.is_dir() {
                return None;
            }
            let name = entry.file_name().into_string().ok()?;
            match read_managed_by(&entry.path()).as_deref() {
                Some(MANAGED_BY_ENVIO) => Some(name),
                _ => None,
            }
        })
        .collect();

    let to_remove: HashSet<String> = if managed_existing.is_empty() {
        shipped_names
            .iter()
            .map(String::from)
            .chain(LEGACY_SKILL_NAMES.iter().map(|s| s.to_string()))
            .collect()
    } else {
        managed_existing.into_iter().collect()
    };

    for name in &to_remove {
        let target = skills_root.join(name);
        if target.exists() {
            fs::remove_dir_all(&target)
                .with_context(|| format!("Failed removing {}", target.display()))?;
        }
    }

    for entry in shipped.entries() {
        let DirEntry::Dir(dir) = entry else { continue };
        let name = dir
            .path()
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| anyhow::anyhow!("Skill dir has no name: {:?}", dir.path()))?;
        let target = skills_root.join(name);
        // `RelativeDir::extract` walks children and only creates dirs as it
        // recurses into them; the top-level dir of the skill itself isn't
        // created, so do it here before writing files into it.
        fs::create_dir_all(&target)
            .with_context(|| format!("Failed creating {}", target.display()))?;
        shipped
            .new_child(dir)
            .extract(&skills_root)
            .with_context(|| format!("Failed extracting skill {}", name))?;
    }

    let mut sorted = shipped_names;
    sorted.sort();
    println!(
        "Wrote {} skill{} to {}:",
        sorted.len(),
        if sorted.len() == 1 { "" } else { "s" },
        skills_root.display()
    );
    for name in &sorted {
        println!("  {}", name);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempdir::TempDir;

    fn shipped_skill_names() -> Vec<String> {
        let mut names: Vec<String> = TemplateDirs::new()
            .get_shared_skills_dir()
            .expect("shipped skills")
            .entries()
            .iter()
            .filter_map(|e| match e {
                DirEntry::Dir(d) => d
                    .path()
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map(String::from),
                DirEntry::File(_) => None,
            })
            .collect();
        names.sort();
        names
    }

    fn dir_listing(path: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(path)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().expect("utf-8"))
            .collect();
        names.sort();
        names
    }

    fn write_skill(dir: &Path, body: &str) {
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join("SKILL.md"), body).unwrap();
    }

    /// Marker present → replace marked skills, leave unrelated ones alone.
    /// Even a marked skill whose name is no longer shipped (e.g. an older
    /// envio-managed directory) gets removed.
    #[test]
    fn run_update_marker_branch_replaces_managed_and_keeps_user_skills() {
        let tmp = TempDir::new("envio_skills_marker").expect("tempdir");
        let project_paths =
            ParsedProjectPaths::default_with_root(tmp.path().to_str().expect("utf-8 path"))
                .expect("parsed project paths");
        let skills_root = tmp.path().join(".claude").join("skills");

        let managed_marker =
            "---\nname: indexer-configuration\nmetadata:\n  managed-by: envio\n---\nold body";
        // A previously-shipped envio skill that no longer exists in the
        // current set; should still be removed because it's marked.
        let managed_orphan =
            "---\nname: indexing-blocks-old\nmetadata:\n  managed-by: envio\n---\nold body";
        let user_unmarked = "---\nname: my-custom\n---\ncustom body";

        write_skill(&skills_root.join("indexer-configuration"), managed_marker);
        write_skill(&skills_root.join("indexing-blocks-old"), managed_orphan);
        write_skill(&skills_root.join("my-custom"), user_unmarked);

        run_update(&project_paths).expect("update succeeds");

        let mut expected = shipped_skill_names();
        expected.push("my-custom".to_string());
        expected.sort();

        let actual = dir_listing(&skills_root);
        let custom_body =
            fs::read_to_string(skills_root.join("my-custom").join("SKILL.md")).unwrap();
        let new_config_body =
            fs::read_to_string(skills_root.join("indexer-configuration").join("SKILL.md")).unwrap();

        assert_eq!(
            (
                actual,
                custom_body,
                new_config_body.contains("managed-by: envio"),
            ),
            (
                expected,
                "---\nname: my-custom\n---\ncustom body".to_string(),
                true
            ),
        );
    }

    /// No markers anywhere → treat as a pre-marker install. Wipe any
    /// directory whose name matches a current or legacy shipped name,
    /// leave everything else, then write the fresh set.
    #[test]
    fn run_update_legacy_branch_cleans_up_unmarked_old_skills() {
        let tmp = TempDir::new("envio_skills_legacy").expect("tempdir");
        let project_paths =
            ParsedProjectPaths::default_with_root(tmp.path().to_str().expect("utf-8 path"))
                .expect("parsed project paths");
        let skills_root = tmp.path().join(".claude").join("skills");

        // Three pre-marker shapes: a renamed skill (indexing-config), a
        // current-name skill that pre-dates markers (indexer-configuration),
        // and a user skill that must survive.
        write_skill(
            &skills_root.join("indexing-config"),
            "---\nname: indexing-config\n---\nlegacy",
        );
        write_skill(
            &skills_root.join("indexer-configuration"),
            "---\nname: indexer-configuration\n---\npre-marker",
        );
        write_skill(
            &skills_root.join("my-custom"),
            "---\nname: my-custom\n---\nkeep me",
        );

        run_update(&project_paths).expect("update succeeds");

        let mut expected = shipped_skill_names();
        expected.push("my-custom".to_string());
        expected.sort();

        let actual = dir_listing(&skills_root);
        let keep_body = fs::read_to_string(skills_root.join("my-custom").join("SKILL.md")).unwrap();
        let rewritten =
            fs::read_to_string(skills_root.join("indexer-configuration").join("SKILL.md")).unwrap();

        assert_eq!(
            (actual, keep_body, rewritten.contains("managed-by: envio")),
            (
                expected,
                "---\nname: my-custom\n---\nkeep me".to_string(),
                true
            ),
        );
    }
}
