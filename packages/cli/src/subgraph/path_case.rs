//! Files a manifest names in a case the repo doesn't have them in.
//!
//! macOS and Windows filesystems ignore case by default, so a manifest written
//! there can name `./abis/WrappedPunks.json` for a file committed as
//! `abis/wrappedpunks.json` (CryptoPunks), and it builds and deploys fine from
//! the author's machine — the subgraph runs on hosted platforms. Linux tells
//! the two apart, and graph-cli there fails the same way envio did. envio reads
//! the one entry that differs only in case, as the author's filesystem does,
//! and says so; two such entries are left to the "doesn't exist" error.

use std::path::{Component, Path};

use serde_yaml::Value;

/// `path` (relative to `dir`) as the filesystem spells it, when it doesn't
/// exist as written but each missing component has exactly one entry that
/// differs from it only in case.
pub fn on_disk(dir: &Path, path: &str) -> Option<String> {
    if dir.join(path).exists() {
        return None;
    }
    let mut current = dir.to_path_buf();
    let mut spelled: Vec<String> = Vec::new();
    for component in Path::new(path).components() {
        match component {
            Component::CurDir => spelled.push(".".to_string()),
            Component::ParentDir => {
                current.push("..");
                spelled.push("..".to_string());
            }
            Component::Normal(name) => {
                let name = name.to_string_lossy().to_string();
                let exact = current.join(&name);
                if exact.exists() {
                    current = exact;
                    spelled.push(name);
                    continue;
                }
                let lowered = name.to_lowercase();
                let matches: Vec<String> = std::fs::read_dir(&current)
                    .ok()?
                    .filter_map(|entry| entry.ok())
                    .map(|entry| entry.file_name().to_string_lossy().to_string())
                    .filter(|entry| entry.to_lowercase() == lowered)
                    .collect();
                let [found] = matches.as_slice() else {
                    return None;
                };
                current.push(found);
                spelled.push(found.clone());
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    Some(spelled.join("/"))
}

/// The manifest with every file it names (schema, mappings, ABIs) spelled as
/// the filesystem has it, and each path changed, as written and as found.
pub fn match_manifest(dir: &Path, yaml: &str) -> (String, Vec<(String, String)>) {
    let Ok(mut manifest) = serde_yaml::from_str::<Value>(yaml) else {
        return (yaml.to_string(), Vec::new());
    };
    let mut changed: Vec<(String, String)> = Vec::new();
    let mut fix = |value: &mut Value| {
        let Some(path) = value.as_str() else {
            return;
        };
        if let Some(found) = on_disk(dir, path) {
            if !changed.iter().any(|(from, _)| from == path) {
                changed.push((path.to_string(), found.clone()));
            }
            *value = Value::String(found);
        }
    };
    if let Some(file) = manifest
        .get_mut("schema")
        .and_then(|schema| schema.get_mut("file"))
    {
        fix(file);
    }
    for key in ["dataSources", "templates"] {
        let Some(list) = manifest.get_mut(key).and_then(Value::as_sequence_mut) else {
            continue;
        };
        for source in list {
            let Some(mapping) = source.get_mut("mapping") else {
                continue;
            };
            if let Some(file) = mapping.get_mut("file") {
                fix(file);
            }
            if let Some(abis) = mapping.get_mut("abis").and_then(Value::as_sequence_mut) {
                for abi in abis {
                    if let Some(file) = abi.get_mut("file") {
                        fix(file);
                    }
                }
            }
        }
    }
    if changed.is_empty() {
        return (yaml.to_string(), changed);
    }
    match serde_yaml::to_string(&manifest) {
        Ok(text) => (text, changed),
        Err(_) => (yaml.to_string(), Vec::new()),
    }
}
