//! The packages of the workspace a subgraph project sits in.
//!
//! A monorepo's subgraph imports its shared mapping code by package name
//! (enzyme's `@enzymefinance/subgraph-utils`), which only the workspace install
//! links into node_modules. Without that install the name still means the
//! workspace's own package: npm, yarn and pnpm link every package the
//! workspace declares, by its package.json name.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const MAX_DEPTH: usize = 6;

/// The workspace globs a directory declares: package.json `workspaces` (a list,
/// or yarn's `{packages: [...]}`), or pnpm-workspace.yaml `packages`.
fn declared_globs(dir: &Path) -> Option<Vec<String>> {
    let strings = |value: Option<&serde_json::Value>| -> Option<Vec<String>> {
        Some(
            value?
                .as_array()?
                .iter()
                .filter_map(|glob| glob.as_str().map(str::to_string))
                .collect(),
        )
    };
    if let Some(manifest) = std::fs::read_to_string(dir.join("package.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
    {
        let workspaces = manifest.get("workspaces");
        if let Some(globs) =
            strings(workspaces).or_else(|| strings(workspaces.and_then(|w| w.get("packages"))))
        {
            return Some(globs);
        }
    }
    let pnpm = std::fs::read_to_string(dir.join("pnpm-workspace.yaml")).ok()?;
    let yaml = serde_yaml::from_str::<serde_yaml::Value>(&pnpm).ok()?;
    Some(
        yaml.get("packages")?
            .as_sequence()?
            .iter()
            .filter_map(|glob| glob.as_str().map(str::to_string))
            .collect(),
    )
}

fn segment_matches(pattern: &str, name: &str) -> bool {
    let pattern = format!(
        "^{}$",
        pattern
            .split('*')
            .map(regex::escape)
            .collect::<Vec<_>>()
            .join(".*")
    );
    regex::Regex::new(&pattern).is_ok_and(|pattern| pattern.is_match(name))
}

fn expand(dir: &Path, segments: &[&str], depth: usize, out: &mut Vec<PathBuf>) {
    let Some((first, rest)) = segments.split_first() else {
        out.push(dir.to_path_buf());
        return;
    };
    if depth > MAX_DEPTH {
        return;
    }
    match *first {
        "" | "." => expand(dir, rest, depth, out),
        ".." => {
            if let Some(parent) = dir.parent() {
                expand(parent, rest, depth, out);
            }
        }
        "**" => {
            expand(dir, rest, depth, out);
            for child in children(dir) {
                expand(&child, segments, depth + 1, out);
            }
        }
        pattern if pattern.contains('*') => {
            for child in children(dir) {
                let name = child
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("");
                if segment_matches(pattern, name) {
                    expand(&child, rest, depth + 1, out);
                }
            }
        }
        name => expand(&dir.join(name), rest, depth + 1, out),
    }
}

fn children(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut dirs: Vec<PathBuf> = entries
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter(|entry| {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            !name.starts_with('.') && name != "node_modules"
        })
        .map(|entry| entry.path())
        .collect();
    dirs.sort();
    dirs
}

/// The nearest directory at or above `start` that declares a workspace.
pub fn root(start: &Path) -> Option<PathBuf> {
    let start = std::fs::canonicalize(start).unwrap_or_else(|_| start.to_path_buf());
    start
        .ancestors()
        .find(|dir| declared_globs(dir).is_some())
        .map(Path::to_path_buf)
}

/// Every package of the nearest workspace at or above `start`, by name.
pub fn packages(start: &Path) -> BTreeMap<String, PathBuf> {
    let Some((root, globs)) =
        root(start).and_then(|root| declared_globs(&root).map(|globs| (root, globs)))
    else {
        return BTreeMap::new();
    };
    let mut included = Vec::new();
    let mut excluded = Vec::new();
    for glob in &globs {
        let (target, glob) = match glob.strip_prefix('!') {
            Some(negated) => (&mut excluded, negated),
            None => (&mut included, glob.as_str()),
        };
        let segments: Vec<&str> = glob.trim_end_matches('/').split('/').collect();
        expand(&root, &segments, 0, target);
    }
    let mut found = BTreeMap::new();
    for dir in included {
        if excluded.contains(&dir) {
            continue;
        }
        let name = std::fs::read_to_string(dir.join("package.json"))
            .ok()
            .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
            .and_then(|manifest| manifest.get("name")?.as_str().map(str::to_string));
        if let Some(name) = name {
            found.entry(name).or_insert(dir);
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_packages_a_workspace_declares() {
        let dir = tempdir::TempDir::new("envio_subgraph_workspace").unwrap();
        let write = |path: &str, text: &str| {
            let file = dir.path().join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, text).unwrap();
        };
        write(
            "package.json",
            r#"{"workspaces":{"packages":["packages/*","subgraphs/**","!packages/skip"]}}"#,
        );
        write("packages/utils/package.json", r#"{"name":"@ws/utils"}"#);
        write("packages/skip/package.json", r#"{"name":"@ws/skip"}"#);
        write("subgraphs/a/core/package.json", r#"{"name":"@ws/core"}"#);
        write("other/package.json", r#"{"name":"@ws/other"}"#);
        let root = std::fs::canonicalize(dir.path()).unwrap();
        assert_eq!(
            packages(&root.join("subgraphs/a/core")),
            BTreeMap::from([
                ("@ws/core".to_string(), root.join("subgraphs/a/core")),
                ("@ws/utils".to_string(), root.join("packages/utils")),
            ])
        );
    }

    #[test]
    fn names_the_directory_that_declares_the_workspace() {
        let dir = tempdir::TempDir::new("envio_subgraph_workspace_root").unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        std::fs::write(
            root.join("pnpm-workspace.yaml"),
            "packages:\n  - subgraphs/*\n",
        )
        .unwrap();
        std::fs::create_dir_all(root.join("subgraphs/exchange")).unwrap();
        std::fs::write(
            root.join("subgraphs/exchange/package.json"),
            r#"{"name":"exchange"}"#,
        )
        .unwrap();
        assert_eq!(super::root(&root.join("subgraphs/exchange")), Some(root));
    }
}
