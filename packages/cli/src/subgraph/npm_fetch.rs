//! Files a manifest names inside an npm package the repo's install didn't
//! provide.
//!
//! A manifest can decode with an ABI shipped in a package
//! (`../../node_modules/@sushiswap/core/build/abi/UniswapV2Factory.json`),
//! and an old repo's install can fail on graph-cli's own dead git
//! dependencies, leaving no node_modules. The package is then fetched, as the
//! runtime fetches a mapping's libraries (§6a): at the version the repo's
//! lockfile pins, else its package.json range, with npm, no lifecycle scripts,
//! into envio's cache — never into the repo.

use std::path::{Path, PathBuf};

use crate::utils::project_env::ProjectEnv;

/// `ENVIO_SUBGRAPH_CACHE_DIR`, else the user's cache, as the runtime picks it.
fn cache_dir(project_dir: &Path) -> PathBuf {
    let env = ProjectEnv::new(project_dir);
    if let Some(dir) = env
        .var("ENVIO_SUBGRAPH_CACHE_DIR")
        .filter(|dir| !dir.is_empty())
    {
        return PathBuf::from(dir);
    }
    let base = env
        .var("XDG_CACHE_HOME")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env.var("HOME")
                .map(|home| PathBuf::from(home).join(".cache"))
        })
        .unwrap_or_else(|| PathBuf::from(".cache"));
    base.join("envio").join("subgraph")
}

/// The package a path runs through (`node_modules/@scope/name/rest`), and the
/// path inside it.
fn split(path: &str) -> Option<(String, PathBuf)> {
    let parts: Vec<&str> = path.split('/').collect();
    let index = parts.iter().rposition(|part| *part == "node_modules")?;
    let (name, rest) = match parts.get(index + 1) {
        Some(scope) if scope.starts_with('@') => (
            format!("{scope}/{}", parts.get(index + 2)?),
            &parts[index + 3..],
        ),
        Some(name) => (name.to_string(), &parts[index + 2..]),
        None => return None,
    };
    let valid = name.chars().all(|ch| {
        ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '@' | '/' | '-' | '_' | '.')
    });
    (valid && !rest.is_empty()).then(|| (name, rest.iter().collect()))
}

fn read_json(path: &Path) -> Option<serde_json::Value> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

fn exact_version(version: &str) -> bool {
    let core = version.split('-').next().unwrap_or_default();
    core.split('.').count() == 3 && core.split('.').all(|part| part.parse::<u64>().is_ok())
}

/// The version a lockfile in `dir` resolved `name` to: npm, yarn or pnpm.
fn locked_version(dir: &Path, name: &str) -> Option<String> {
    if let Some(lock) = read_json(&dir.join("package-lock.json")) {
        let version = lock
            .pointer(&format!(
                "/packages/node_modules~1{}/version",
                name.replace('/', "~1")
            ))
            .or_else(|| lock.get("dependencies")?.get(name)?.get("version"))
            .and_then(|version| version.as_str());
        if let Some(version) = version.filter(|version| exact_version(version)) {
            return Some(version.to_string());
        }
    }
    if let Ok(yarn) = std::fs::read_to_string(dir.join("yarn.lock")) {
        for block in yarn.split("\n\n") {
            let Some(header) = block
                .lines()
                .find(|line| !line.is_empty() && !line.starts_with('#'))
            else {
                continue;
            };
            let entries = header.trim_end_matches(':').split(", ");
            if !entries
                .map(|entry| entry.trim().trim_matches('"'))
                .any(|entry| entry.starts_with(&format!("{name}@")))
            {
                continue;
            }
            let version = block.lines().find_map(|line| {
                let line = line.trim();
                let rest = line.strip_prefix("version")?;
                Some(
                    rest.trim_start_matches(':')
                        .trim()
                        .trim_matches('"')
                        .to_string(),
                )
            });
            if let Some(version) = version.filter(|version| exact_version(version)) {
                return Some(version);
            }
        }
    }
    if let Ok(pnpm) = std::fs::read_to_string(dir.join("pnpm-lock.yaml")) {
        let pattern = regex::Regex::new(&format!(
            r"(?m)^\s+'?/?{}@(\d[^:(')\s]*)",
            regex::escape(name)
        ))
        .ok()?;
        if let Some(captures) = pattern.captures(&pnpm) {
            if exact_version(&captures[1]) {
                return Some(captures[1].to_string());
            }
        }
    }
    None
}

/// A package.json spec npm can fetch from the registry: not a git, file,
/// link or workspace one.
fn registry_spec(spec: &str) -> Option<String> {
    let refused = spec.is_empty()
        || spec == "*"
        || spec == "latest"
        || spec.contains("://")
        || [
            "git",
            "github:",
            "file:",
            "link:",
            "workspace:",
            "portal:",
            "patch:",
            "npm:",
        ]
        .iter()
        .any(|prefix| spec.starts_with(prefix))
        || (spec.contains('/') && !spec.starts_with('@'));
    (!refused).then(|| spec.to_string())
}

/// The version of `name` to fetch, from `dir` up: a lockfile's, else a
/// package.json range.
fn declared_version(dir: &Path, name: &str) -> Option<String> {
    let dirs: Vec<&Path> = dir.ancestors().collect();
    if let Some(version) = dirs.iter().find_map(|dir| locked_version(dir, name)) {
        return Some(version);
    }
    dirs.iter().find_map(|dir| {
        let manifest = read_json(&dir.join("package.json"))?;
        [
            "dependencies",
            "devDependencies",
            "peerDependencies",
            "optionalDependencies",
        ]
        .iter()
        .find_map(|field| manifest.get(field)?.get(name)?.as_str())
        .and_then(registry_spec)
    })
}

/// npm into `dir` (a prefix with its own node_modules), atomically, as the
/// runtime's toolchain fetch does it.
fn npm_install(dir: &Path, spec: &str) -> bool {
    let staging = PathBuf::from(format!("{}.tmp-{}", dir.display(), std::process::id()));
    let _ = std::fs::remove_dir_all(&staging);
    if std::fs::create_dir_all(&staging).is_err()
        || std::fs::write(
            staging.join("package.json"),
            r#"{"name":"envio-subgraph-cache","private":true}"#,
        )
        .is_err()
    {
        return false;
    }
    eprintln!(
        "Envio Subgraph is fetching {spec} into {}: the manifest reads an ABI from it, and the \
         project's own node_modules lacks it.",
        dir.display()
    );
    let installed = std::process::Command::new("npm")
        .args([
            "install",
            "--no-audit",
            "--no-fund",
            "--no-package-lock",
            "--ignore-scripts",
            "--legacy-peer-deps",
            "--loglevel=error",
            spec,
        ])
        .current_dir(&staging)
        .stdout(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if !installed || std::fs::write(staging.join(".envio-installed"), spec).is_err() {
        let _ = std::fs::remove_dir_all(&staging);
        return false;
    }
    let _ = std::fs::remove_dir_all(dir);
    dir.parent()
        .is_some_and(|parent| std::fs::create_dir_all(parent).is_ok())
        && std::fs::rename(&staging, dir).is_ok()
}

/// `path` (relative to `dir`, through node_modules) read from the package
/// fetched into envio's cache, fetching it first when it isn't there.
pub fn fetched_file(dir: &Path, path: &str) -> Option<PathBuf> {
    let (name, rest) = split(path)?;
    // The version is looked for up through the workspace root.
    let dir = &crate::project_paths::path_utils::normalize_path(
        std::env::current_dir().unwrap_or_default().join(dir),
    );
    // A workspace package (pnpm and yarn link them into node_modules) is the
    // repo's own: read from its directory, never fetched.
    if let Some(package) = dir.ancestors().find_map(|root| {
        super::render::workspace_package_dirs(root)
            .into_iter()
            .find(|package| {
                read_json(&package.join("package.json"))
                    .and_then(|manifest| manifest.get("name")?.as_str().map(str::to_string))
                    .is_some_and(|package_name| package_name == name)
            })
    }) {
        let file = package.join(&rest);
        return file.is_file().then_some(file);
    }
    let specs = match declared_version(dir, &name) {
        Some(version) => vec![format!("{name}@{version}"), name.clone()],
        None => vec![name.clone()],
    };
    let cache = cache_dir(dir).join("abi-packages");
    for spec in specs {
        let installed = cache.join(spec.replace('/', "+"));
        if !installed.join(".envio-installed").exists() && !npm_install(&installed, &spec) {
            continue;
        }
        let file = installed.join("node_modules").join(&name).join(&rest);
        return file.is_file().then_some(file);
    }
    None
}
