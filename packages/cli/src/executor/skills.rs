use anyhow::{Context, Result};
use include_dir::DirEntry;
use std::fs;

use crate::{project_paths::ParsedProjectPaths, template_dirs::TemplateDirs};

/// Re-extracts every skill shipped by this CLI version into
/// `<project_root>/.claude/skills/<name>/`. For each shipped skill we
/// remove the matching directory if present and write the embedded copy
/// in its place. Skills under `.claude/skills/` that are not part of the
/// shipped set are left untouched.
pub fn run_update(project_paths: &ParsedProjectPaths) -> Result<()> {
    let project_root = &project_paths.project_root;
    let skills_root = project_root.join(".claude").join("skills");
    fs::create_dir_all(&skills_root)
        .with_context(|| format!("Failed creating {}", skills_root.display()))?;

    let template_dirs = TemplateDirs::new();
    let shipped = template_dirs
        .get_shared_skills_dir()
        .context("Failed locating shipped skills directory")?;

    let mut updated: Vec<String> = Vec::new();
    for entry in shipped.entries() {
        let DirEntry::Dir(dir) = entry else { continue };
        let name = dir
            .path()
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| anyhow::anyhow!("Skill dir has no name: {:?}", dir.path()))?
            .to_string();

        let target = skills_root.join(&name);
        if target.exists() {
            fs::remove_dir_all(&target)
                .with_context(|| format!("Failed removing {}", target.display()))?;
        }
        // `RelativeDir::extract` walks children and only creates dirs as it
        // recurses into them; the top-level dir of the skill itself isn't
        // created, so do it here before writing files into it.
        fs::create_dir_all(&target)
            .with_context(|| format!("Failed creating {}", target.display()))?;
        shipped
            .new_child(dir)
            .extract(&skills_root)
            .with_context(|| format!("Failed extracting skill {}", name))?;
        updated.push(name);
    }

    updated.sort();
    println!(
        "Updated {} skill{} in {}:",
        updated.len(),
        if updated.len() == 1 { "" } else { "s" },
        skills_root.display()
    );
    for name in &updated {
        println!("  {}", name);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempdir::TempDir;

    #[test]
    fn run_update_extracts_all_shipped_skills_and_overwrites_modified_ones() {
        let tmp = TempDir::new("envio_skills_update").expect("tempdir");
        let project_paths =
            ParsedProjectPaths::default_with_root(tmp.path().to_str().expect("utf-8 tempdir path"))
                .expect("parsed project paths");

        // Pre-seed a stale copy of one skill plus an unrelated user-authored
        // skill. The unrelated one must survive the update.
        let skills_root = tmp.path().join(".claude").join("skills");
        let stale = skills_root.join("indexing-config");
        let user = skills_root.join("user-authored");
        fs::create_dir_all(&stale).unwrap();
        fs::create_dir_all(&user).unwrap();
        fs::write(stale.join("SKILL.md"), b"stale contents").unwrap();
        fs::write(user.join("SKILL.md"), b"user contents").unwrap();

        run_update(&project_paths).expect("update succeeds");

        let shipped = TemplateDirs::new()
            .get_shared_skills_dir()
            .expect("shipped skills");
        let mut expected: Vec<String> = shipped
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
        expected.push("user-authored".to_string());
        expected.sort();

        let mut actual: Vec<String> = fs::read_dir(&skills_root)
            .unwrap()
            .map(|e| {
                e.unwrap()
                    .file_name()
                    .into_string()
                    .expect("utf-8 dir name")
            })
            .collect();
        actual.sort();

        let stale_skill_md =
            fs::read_to_string(skills_root.join("indexing-config").join("SKILL.md")).unwrap();
        let user_skill_md =
            fs::read_to_string(skills_root.join("user-authored").join("SKILL.md")).unwrap();

        assert_eq!(
            (actual, stale_skill_md.starts_with("stale"), user_skill_md),
            (expected, false, "user contents".to_string())
        );
    }
}
