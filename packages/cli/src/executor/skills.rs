use anyhow::{Context, Result};
use include_dir::DirEntry;
use serde::Deserialize;
use std::{fs, path::Path};

use crate::{project_paths::ParsedProjectPaths, template_dirs::TemplateDirs};

/// Skill names shipped before the `managed-by` marker existed.
/// These lack the marker, so the marker-based cleanup won't find them.
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
/// Deletes all existing directories whose `SKILL.md` declares
/// `metadata.managed-by: envio`, then writes the current shipped set.
/// User-authored skills (no marker or a different marker) are left
/// untouched.
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

    for entry in fs::read_dir(&skills_root)
        .with_context(|| format!("Failed reading {}", skills_root.display()))?
    {
        let entry = entry.context("Failed reading skills directory entry")?;
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        if read_managed_by(&entry.path()).as_deref() == Some(MANAGED_BY_ENVIO) {
            fs::remove_dir_all(entry.path())
                .with_context(|| format!("Failed removing {}", entry.path().display()))?;
        }
    }

    for name in LEGACY_SKILL_NAMES {
        let target = skills_root.join(name);
        if target.exists() {
            fs::remove_dir_all(&target)
                .with_context(|| format!("Failed removing legacy skill {}", target.display()))?;
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

    #[test]
    fn replaces_managed_skills_and_keeps_user_skills() {
        let tmp = TempDir::new("envio_skills").expect("tempdir");
        let project_paths =
            ParsedProjectPaths::default_with_root(tmp.path().to_str().expect("utf-8 path"))
                .expect("parsed project paths");
        let skills_root = tmp.path().join(".claude").join("skills");

        write_skill(
            &skills_root.join("indexer-configuration"),
            "---\nname: indexer-configuration\nmetadata:\n  managed-by: envio\n---\nold body",
        );
        write_skill(
            &skills_root.join("retired-envio-skill"),
            "---\nname: retired-envio-skill\nmetadata:\n  managed-by: envio\n---\nold body",
        );
        write_skill(
            &skills_root.join("my-custom"),
            "---\nname: my-custom\n---\ncustom body",
        );

        run_update(&project_paths).expect("update succeeds");

        let mut expected = shipped_skill_names();
        expected.push("my-custom".to_string());
        expected.sort();

        assert_eq!(
            (
                dir_listing(&skills_root),
                fs::read_to_string(skills_root.join("my-custom").join("SKILL.md")).unwrap(),
                fs::read_to_string(skills_root.join("indexer-configuration").join("SKILL.md"))
                    .unwrap()
                    .contains("managed-by: envio"),
            ),
            (
                expected,
                "---\nname: my-custom\n---\ncustom body".to_string(),
                true,
            ),
        );
    }

    #[test]
    fn removes_legacy_skills_without_marker() {
        let tmp = TempDir::new("envio_skills_legacy").expect("tempdir");
        let project_paths =
            ParsedProjectPaths::default_with_root(tmp.path().to_str().expect("utf-8 path"))
                .expect("parsed project paths");
        let skills_root = tmp.path().join(".claude").join("skills");

        write_skill(
            &skills_root.join("indexing-blocks"),
            "---\nname: indexing-blocks\n---\nold content",
        );
        write_skill(
            &skills_root.join("testing"),
            "---\nname: testing\n---\nold content",
        );
        write_skill(
            &skills_root.join("my-custom"),
            "---\nname: my-custom\n---\nkeep me",
        );

        run_update(&project_paths).expect("update succeeds");

        let mut expected = shipped_skill_names();
        expected.push("my-custom".to_string());
        expected.sort();

        assert_eq!(
            (
                dir_listing(&skills_root),
                fs::read_to_string(skills_root.join("my-custom").join("SKILL.md")).unwrap(),
            ),
            (expected, "---\nname: my-custom\n---\nkeep me".to_string(),),
        );
    }

    #[test]
    fn leaves_unmarked_skills_untouched() {
        let tmp = TempDir::new("envio_skills_unmarked").expect("tempdir");
        let project_paths =
            ParsedProjectPaths::default_with_root(tmp.path().to_str().expect("utf-8 path"))
                .expect("parsed project paths");
        let skills_root = tmp.path().join(".claude").join("skills");

        write_skill(
            &skills_root.join("old-no-marker"),
            "---\nname: old-no-marker\n---\nlegacy",
        );

        run_update(&project_paths).expect("update succeeds");

        let mut expected = shipped_skill_names();
        expected.push("old-no-marker".to_string());
        expected.sort();

        assert_eq!(
            (
                dir_listing(&skills_root),
                fs::read_to_string(skills_root.join("old-no-marker").join("SKILL.md")).unwrap(),
            ),
            (
                expected,
                "---\nname: old-no-marker\n---\nlegacy".to_string(),
            ),
        );
    }
}
