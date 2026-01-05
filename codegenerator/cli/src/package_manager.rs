//! Package manager and runtime detection for the Envio CLI.
//!
//! This module provides automatic detection of package managers (npm, yarn, pnpm, bun)
//! and JavaScript runtimes (node, bun) based on lockfiles in the project directory.

use clap::ValueEnum;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Supported package managers
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema, Default, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum PackageManager {
    #[default]
    Npm,
    Yarn,
    Pnpm,
    Bun,
}

impl PackageManager {
    /// Get the command name for this package manager
    pub fn command(&self) -> &'static str {
        match self {
            Self::Npm => "npm",
            Self::Yarn => "yarn",
            Self::Pnpm => "pnpm",
            Self::Bun => "bun",
        }
    }

    /// Get the display name (for user messages)
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Npm => "npm",
            Self::Yarn => "Yarn",
            Self::Pnpm => "pnpm",
            Self::Bun => "Bun",
        }
    }

    /// Get arguments for running `install`
    pub fn install_args(&self) -> Vec<&'static str> {
        match self {
            Self::Npm => vec!["install"],
            Self::Yarn => vec!["install"],
            Self::Pnpm => vec!["install"],
            Self::Bun => vec!["install"],
        }
    }

    /// Get arguments for running `install` with flags for CI/offline optimization
    pub fn install_args_optimized(&self) -> Vec<&'static str> {
        match self {
            Self::Npm => vec!["install"],
            Self::Yarn => vec!["install"],
            Self::Pnpm => vec!["install", "--prefer-offline"],
            Self::Bun => vec!["install"],
        }
    }

    /// Get arguments for running `install` without generating lockfile
    pub fn install_args_no_lockfile(&self) -> Vec<&'static str> {
        match self {
            Self::Npm => vec!["install", "--no-package-lock"],
            Self::Yarn => vec!["install", "--no-lockfile"],
            Self::Pnpm => vec!["install", "--no-lockfile", "--prefer-offline"],
            Self::Bun => vec!["install", "--no-save"],
        }
    }

    /// Get arguments for running a script (e.g., "start", "test")
    pub fn run_script_args(&self, script: &str) -> Vec<String> {
        match self {
            Self::Npm => vec!["run".to_string(), script.to_string()],
            Self::Yarn => vec![script.to_string()],
            Self::Pnpm => vec![script.to_string()],
            Self::Bun => vec!["run".to_string(), script.to_string()],
        }
    }

    /// Check if this package manager can auto-install if missing
    /// Only pnpm is auto-installed (via npm install -g pnpm) for backwards compatibility
    pub fn can_auto_install(&self) -> bool {
        matches!(self, Self::Pnpm)
    }
}

/// JavaScript runtimes
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Runtime {
    #[default]
    Node,
    Bun,
}

impl Runtime {
    /// Get the command name for this runtime
    pub fn command(&self) -> &'static str {
        match self {
            Self::Node => "node",
            Self::Bun => "bun",
        }
    }
}

/// Combined configuration for package manager and runtime
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageManagerConfig {
    pub package_manager: PackageManager,
    pub runtime: Runtime,
}

impl Default for PackageManagerConfig {
    fn default() -> Self {
        Self {
            package_manager: PackageManager::Npm,
            runtime: Runtime::Node,
        }
    }
}

impl PackageManagerConfig {
    /// Create a new PackageManagerConfig with the given package manager
    /// Runtime is automatically determined based on the package manager
    pub fn new(package_manager: PackageManager) -> Self {
        let runtime = match package_manager {
            PackageManager::Bun => Runtime::Bun,
            _ => Runtime::Node,
        };
        Self {
            package_manager,
            runtime,
        }
    }

    /// Detect package manager from lockfiles in project directory, with optional config override
    ///
    /// Priority order (when no config override):
    /// 1. bun.lockb or bun.lock → bun (runtime + package manager)
    /// 2. pnpm-lock.yaml → pnpm + node
    /// 3. yarn.lock → yarn + node
    /// 4. package-lock.json → npm + node
    /// 5. No lockfile → npm + node (most universal fallback)
    pub fn detect(project_root: &Path, config_override: Option<PackageManager>) -> Self {
        // If config specifies a package manager, use it
        if let Some(pm) = config_override {
            return Self::new(pm);
        }

        // Detect from lockfiles (priority order)
        let pm = if project_root.join("bun.lockb").exists()
            || project_root.join("bun.lock").exists()
        {
            PackageManager::Bun
        } else if project_root.join("pnpm-lock.yaml").exists() {
            PackageManager::Pnpm
        } else if project_root.join("yarn.lock").exists() {
            PackageManager::Yarn
        } else if project_root.join("package-lock.json").exists() {
            PackageManager::Npm
        } else {
            // Default fallback - npm is the most universal
            PackageManager::Npm
        };

        Self::new(pm)
    }

    /// Returns true if bun is used as the runtime
    pub fn is_bun_runtime(&self) -> bool {
        self.runtime == Runtime::Bun
    }

    /// Generate package.json script prefix for chaining commands
    /// e.g., "pnpm build && " for pnpm with ReScript
    pub fn script_chain_prefix(&self, script: &str) -> String {
        match self.package_manager {
            PackageManager::Npm => format!("npm run {} && ", script),
            PackageManager::Yarn => format!("yarn {} && ", script),
            PackageManager::Pnpm => format!("pnpm {} && ", script),
            PackageManager::Bun => format!("bun run {} && ", script),
        }
    }

    /// Generate the run script command for package.json scripts
    /// e.g., "pnpm mocha" for pnpm
    pub fn run_script(&self, script: &str) -> String {
        match self.package_manager {
            PackageManager::Npm => format!("npm run {}", script),
            PackageManager::Yarn => format!("yarn {}", script),
            PackageManager::Pnpm => format!("pnpm {}", script),
            PackageManager::Bun => format!("bun run {}", script),
        }
    }

    /// Get the run script prefix for use in package.json templates
    /// e.g., "npm run " for npm, "pnpm " for pnpm
    pub fn run_script_prefix(&self) -> &'static str {
        match self.package_manager {
            PackageManager::Npm => "npm run ",
            PackageManager::Yarn => "yarn ",
            PackageManager::Pnpm => "pnpm ",
            PackageManager::Bun => "bun run ",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use tempfile::tempdir;

    #[test]
    fn test_detect_bun_from_lockb() {
        let dir = tempdir().unwrap();
        File::create(dir.path().join("bun.lockb")).unwrap();

        let config = PackageManagerConfig::detect(dir.path(), None);
        assert_eq!(config.package_manager, PackageManager::Bun);
        assert_eq!(config.runtime, Runtime::Bun);
    }

    #[test]
    fn test_detect_bun_from_lock() {
        let dir = tempdir().unwrap();
        File::create(dir.path().join("bun.lock")).unwrap();

        let config = PackageManagerConfig::detect(dir.path(), None);
        assert_eq!(config.package_manager, PackageManager::Bun);
        assert_eq!(config.runtime, Runtime::Bun);
    }

    #[test]
    fn test_detect_pnpm_from_lockfile() {
        let dir = tempdir().unwrap();
        File::create(dir.path().join("pnpm-lock.yaml")).unwrap();

        let config = PackageManagerConfig::detect(dir.path(), None);
        assert_eq!(config.package_manager, PackageManager::Pnpm);
        assert_eq!(config.runtime, Runtime::Node);
    }

    #[test]
    fn test_detect_yarn_from_lockfile() {
        let dir = tempdir().unwrap();
        File::create(dir.path().join("yarn.lock")).unwrap();

        let config = PackageManagerConfig::detect(dir.path(), None);
        assert_eq!(config.package_manager, PackageManager::Yarn);
        assert_eq!(config.runtime, Runtime::Node);
    }

    #[test]
    fn test_detect_npm_from_lockfile() {
        let dir = tempdir().unwrap();
        File::create(dir.path().join("package-lock.json")).unwrap();

        let config = PackageManagerConfig::detect(dir.path(), None);
        assert_eq!(config.package_manager, PackageManager::Npm);
        assert_eq!(config.runtime, Runtime::Node);
    }

    #[test]
    fn test_detect_defaults_to_npm() {
        let dir = tempdir().unwrap();
        // No lockfiles

        let config = PackageManagerConfig::detect(dir.path(), None);
        assert_eq!(config.package_manager, PackageManager::Npm);
        assert_eq!(config.runtime, Runtime::Node);
    }

    #[test]
    fn test_config_override_takes_precedence() {
        let dir = tempdir().unwrap();
        // Create pnpm lockfile
        File::create(dir.path().join("pnpm-lock.yaml")).unwrap();

        // Override should take precedence
        let config = PackageManagerConfig::detect(dir.path(), Some(PackageManager::Yarn));
        assert_eq!(config.package_manager, PackageManager::Yarn);
        assert_eq!(config.runtime, Runtime::Node);
    }

    #[test]
    fn test_bun_lockfile_priority() {
        let dir = tempdir().unwrap();
        // Create multiple lockfiles - bun should win
        File::create(dir.path().join("bun.lockb")).unwrap();
        File::create(dir.path().join("pnpm-lock.yaml")).unwrap();
        File::create(dir.path().join("yarn.lock")).unwrap();

        let config = PackageManagerConfig::detect(dir.path(), None);
        assert_eq!(config.package_manager, PackageManager::Bun);
    }

    #[test]
    fn test_command_generation() {
        assert_eq!(PackageManager::Npm.command(), "npm");
        assert_eq!(PackageManager::Yarn.command(), "yarn");
        assert_eq!(PackageManager::Pnpm.command(), "pnpm");
        assert_eq!(PackageManager::Bun.command(), "bun");
    }

    #[test]
    fn test_run_script_args() {
        assert_eq!(
            PackageManager::Npm.run_script_args("test"),
            vec!["run", "test"]
        );
        assert_eq!(PackageManager::Yarn.run_script_args("test"), vec!["test"]);
        assert_eq!(PackageManager::Pnpm.run_script_args("test"), vec!["test"]);
        assert_eq!(
            PackageManager::Bun.run_script_args("test"),
            vec!["run", "test"]
        );
    }

    #[test]
    fn test_install_args_no_lockfile() {
        assert_eq!(
            PackageManager::Npm.install_args_no_lockfile(),
            vec!["install", "--no-package-lock"]
        );
        assert_eq!(
            PackageManager::Yarn.install_args_no_lockfile(),
            vec!["install", "--no-lockfile"]
        );
        assert_eq!(
            PackageManager::Pnpm.install_args_no_lockfile(),
            vec!["install", "--no-lockfile", "--prefer-offline"]
        );
        assert_eq!(
            PackageManager::Bun.install_args_no_lockfile(),
            vec!["install", "--no-save"]
        );
    }

    #[test]
    fn test_script_chain_prefix() {
        let npm_config = PackageManagerConfig::new(PackageManager::Npm);
        assert_eq!(npm_config.script_chain_prefix("build"), "npm run build && ");

        let yarn_config = PackageManagerConfig::new(PackageManager::Yarn);
        assert_eq!(yarn_config.script_chain_prefix("build"), "yarn build && ");

        let pnpm_config = PackageManagerConfig::new(PackageManager::Pnpm);
        assert_eq!(pnpm_config.script_chain_prefix("build"), "pnpm build && ");

        let bun_config = PackageManagerConfig::new(PackageManager::Bun);
        assert_eq!(bun_config.script_chain_prefix("build"), "bun run build && ");
    }

    #[test]
    fn test_is_bun_runtime() {
        let bun_config = PackageManagerConfig::new(PackageManager::Bun);
        assert!(bun_config.is_bun_runtime());

        let npm_config = PackageManagerConfig::new(PackageManager::Npm);
        assert!(!npm_config.is_bun_runtime());
    }

    #[test]
    fn test_serde_roundtrip() {
        let pm = PackageManager::Pnpm;
        let serialized = serde_json::to_string(&pm).unwrap();
        assert_eq!(serialized, "\"pnpm\"");

        let deserialized: PackageManager = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, pm);
    }

    #[test]
    fn test_serde_all_variants() {
        assert_eq!(
            serde_json::to_string(&PackageManager::Npm).unwrap(),
            "\"npm\""
        );
        assert_eq!(
            serde_json::to_string(&PackageManager::Yarn).unwrap(),
            "\"yarn\""
        );
        assert_eq!(
            serde_json::to_string(&PackageManager::Pnpm).unwrap(),
            "\"pnpm\""
        );
        assert_eq!(
            serde_json::to_string(&PackageManager::Bun).unwrap(),
            "\"bun\""
        );
    }
}
