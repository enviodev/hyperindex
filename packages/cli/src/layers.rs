use std::path::{Path, PathBuf};

/// Which `crate::` paths files under each directory must not name, so that
/// imports point down: ecosystem modules, then the address store and the chain
/// buffer, then the sources. None of them reads the environment: the indexer
/// reads it where it starts and passes values in as config.
const FORBIDDEN_IMPORTS: &[(&str, &[&str])] = &[
    (
        "evm/",
        &[
            "crate::chain_buffer",
            "crate::address_store",
            "crate::sources",
            "crate::env",
        ],
    ),
    (
        "fuel/",
        &[
            "crate::chain_buffer",
            "crate::address_store",
            "crate::sources",
            "crate::env",
        ],
    ),
    (
        "svm/",
        &[
            "crate::chain_buffer",
            "crate::address_store",
            "crate::sources",
            "crate::env",
        ],
    ),
    ("chain_buffer/", &["crate::sources", "crate::env"]),
    ("address_store/", &["crate::sources", "crate::env"]),
    ("sources/", &["crate::env"]),
];

fn rust_files_under(directory: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files.extend(rust_files_under(&path));
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            files.push(path);
        }
    }
    files
}

#[test]
fn layer_imports_point_down() {
    let source_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut violations = Vec::new();
    for file in rust_files_under(&source_root) {
        let relative_path = file
            .strip_prefix(&source_root)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        let forbidden: Vec<&str> = FORBIDDEN_IMPORTS
            .iter()
            .filter(|(directory, _)| relative_path.starts_with(directory))
            .flat_map(|(_, paths)| paths.iter().copied())
            .collect();
        if forbidden.is_empty() {
            continue;
        }
        let text = std::fs::read_to_string(&file).unwrap();
        for (line_index, line) in text.lines().enumerate() {
            for path in &forbidden {
                if line.contains(path) {
                    violations.push(format!("src/{relative_path}:{}: {path}", line_index + 1));
                }
            }
        }
    }
    assert!(
        violations.is_empty(),
        "imports pointing up a layer:\n{}",
        violations.join("\n")
    );
}
