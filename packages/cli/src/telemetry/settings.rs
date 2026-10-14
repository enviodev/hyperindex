use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const DEFAULT_ENDPOINT: &str = "https://telemetry.envio.dev/v1/hyperindex";

const SETTINGS_FILE: &str = "telemetry.json";
const INDEXER_ID_DIR: &str = "telemetry";
const INDEXER_ID_FILE: &str = "id";

/// Set by any CI provider worth naming; `CI` alone covers most of them.
const CI_VARS: &[&str] = &[
    "CI",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "BUILDKITE",
    "CIRCLECI",
    "JENKINS_URL",
    "TF_BUILD",
    "CODEBUILD_BUILD_ID",
    "TEAMCITY_VERSION",
];

/// The process inputs telemetry decides from, read once so tests can supply
/// their own.
#[derive(Debug, Clone, Default)]
pub struct Env {
    pub do_not_track: Option<String>,
    pub disabled: Option<String>,
    pub debug: Option<String>,
    pub endpoint: Option<String>,
    pub ci: bool,
    pub kubernetes: bool,
    pub docker: bool,
    pub config_dir: Option<PathBuf>,
}

impl Env {
    pub fn from_process() -> Self {
        let var = |name: &str| std::env::var(name).ok();
        Self {
            do_not_track: var("DO_NOT_TRACK"),
            disabled: var("ENVIO_TELEMETRY_DISABLED"),
            debug: var("ENVIO_TELEMETRY_DEBUG"),
            endpoint: var("ENVIO_TELEMETRY_ENDPOINT").filter(|v| !v.trim().is_empty()),
            ci: CI_VARS.iter().any(|name| is_on(var(name).as_deref())),
            kubernetes: var("KUBERNETES_SERVICE_HOST").is_some(),
            docker: Path::new("/.dockerenv").exists() || Path::new("/run/.containerenv").exists(),
            config_dir: user_config_dir(var("XDG_CONFIG_HOME"), var("HOME")),
        }
    }
}

/// `~/.config/envio` on every platform, so the file is where a reader of the
/// docs expects it on macOS too.
fn user_config_dir(xdg_config_home: Option<String>, home: Option<String>) -> Option<PathBuf> {
    let xdg = xdg_config_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    let base = xdg.or_else(|| {
        home.filter(|home| !home.is_empty())
            .map(|home| PathBuf::from(home).join(".config"))
    })?;
    Some(base.join("envio"))
}

/// `DO_NOT_TRACK=0` and `ENVIO_TELEMETRY_DISABLED=false` mean what they say.
pub fn is_on(value: Option<&str>) -> bool {
    match value.map(|v| v.trim().to_ascii_lowercase()) {
        None => false,
        Some(v) => !matches!(v.as_str(), "" | "0" | "false" | "no" | "off"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OffReason {
    DoNotTrack,
    EnvVar,
    UserDisabled,
    DevelopmentBuild,
}

impl OffReason {
    pub fn describe(&self) -> &'static str {
        match self {
            OffReason::DoNotTrack => "DO_NOT_TRACK is set",
            OffReason::EnvVar => "ENVIO_TELEMETRY_DISABLED is set",
            OffReason::UserDisabled => "turned off with `envio telemetry disable`",
            OffReason::DevelopmentBuild => {
                "this is a development build of envio, which never sends anything unless \
                 ENVIO_TELEMETRY_ENDPOINT is set"
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    Send {
        endpoint: String,
    },
    /// Prints each batch to stderr instead of sending it.
    Debug,
    Off(OffReason),
}

/// Every opt-out beats debug mode: someone who said no should not see payloads
/// being assembled. A development build sends only to an endpoint set
/// explicitly, which keeps the repo's own tests and local builds silent.
pub fn resolve_mode(env: &Env, stored: &Stored, is_release_build: bool) -> Mode {
    if is_on(env.do_not_track.as_deref()) {
        return Mode::Off(OffReason::DoNotTrack);
    }
    if is_on(env.disabled.as_deref()) {
        return Mode::Off(OffReason::EnvVar);
    }
    if stored.enabled == Some(false) {
        return Mode::Off(OffReason::UserDisabled);
    }
    if is_on(env.debug.as_deref()) {
        return Mode::Debug;
    }
    match (&env.endpoint, is_release_build) {
        (Some(endpoint), _) => Mode::Send {
            endpoint: endpoint.clone(),
        },
        (None, true) => Mode::Send {
            endpoint: DEFAULT_ENDPOINT.to_string(),
        },
        (None, false) => Mode::Off(OffReason::DevelopmentBuild),
    }
}

/// `~/.config/envio/telemetry.json`.
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct Stored {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub install_id: Option<String>,
    #[serde(default)]
    pub notice_shown: bool,
}

impl Stored {
    /// A missing or unreadable file reads as defaults: telemetry must never
    /// fail a command.
    pub fn load(config_dir: Option<&Path>) -> Self {
        config_dir
            .and_then(|dir| std::fs::read_to_string(dir.join(SETTINGS_FILE)).ok())
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, config_dir: &Path) -> std::io::Result<()> {
        std::fs::create_dir_all(config_dir)?;
        let raw = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(config_dir.join(SETTINGS_FILE), raw + "\n")
    }

    pub fn path(config_dir: &Path) -> PathBuf {
        config_dir.join(SETTINGS_FILE)
    }
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn valid_id(raw: &str) -> Option<String> {
    uuid::Uuid::parse_str(raw.trim())
        .ok()
        .map(|id| id.to_string())
}

/// The stored install id, creating and storing one when `persist` allows.
/// `None` when there is none and it can't be kept: an id that changes on every
/// run would count one machine many times.
pub fn install_id(config_dir: Option<&Path>, stored: &mut Stored, persist: bool) -> Option<String> {
    if let Some(id) = stored.install_id.as_deref().and_then(valid_id) {
        return Some(id);
    }
    if !persist {
        return None;
    }
    let dir = config_dir?;
    let id = new_id();
    let mut updated = stored.clone();
    updated.install_id = Some(id.clone());
    updated.save(dir).ok()?;
    *stored = updated;
    Some(id)
}

/// `<project>/.envio/telemetry/id`. The directory ignores itself, because
/// `.envio/.gitignore` is the user's and other `.envio` entries are committed:
/// an id in git would follow the project into every clone and public repo.
pub fn indexer_id(envio_dir: &Path, persist: bool) -> Option<String> {
    let dir = envio_dir.join(INDEXER_ID_DIR);
    let path = dir.join(INDEXER_ID_FILE);
    if let Some(id) = std::fs::read_to_string(&path)
        .ok()
        .as_deref()
        .and_then(valid_id)
    {
        return Some(id);
    }
    if !persist {
        return None;
    }
    let id = new_id();
    std::fs::create_dir_all(&dir).ok()?;
    std::fs::write(dir.join(".gitignore"), "*\n").ok()?;
    std::fs::write(&path, format!("{id}\n")).ok()?;
    Some(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> Env {
        Env::default()
    }

    #[test]
    fn opt_outs_take_precedence_in_order() {
        let enabled_by_user = Stored {
            enabled: Some(true),
            ..Stored::default()
        };
        let disabled_by_user = Stored {
            enabled: Some(false),
            ..Stored::default()
        };
        let default_send = Mode::Send {
            endpoint: DEFAULT_ENDPOINT.to_string(),
        };
        let cases = [
            (
                "DO_NOT_TRACK beats everything",
                Env {
                    do_not_track: Some("1".into()),
                    debug: Some("1".into()),
                    endpoint: Some("http://localhost:1".into()),
                    ..env()
                },
                enabled_by_user.clone(),
                true,
            ),
            (
                "ENVIO_TELEMETRY_DISABLED beats a stored enable",
                Env {
                    disabled: Some("true".into()),
                    ..env()
                },
                enabled_by_user.clone(),
                true,
            ),
            (
                "a stored disable beats debug",
                Env {
                    debug: Some("1".into()),
                    ..env()
                },
                disabled_by_user.clone(),
                true,
            ),
            (
                "debug beats sending",
                Env {
                    debug: Some("1".into()),
                    ..env()
                },
                Stored::default(),
                true,
            ),
            ("a release build sends", env(), Stored::default(), true),
            (
                "a falsy opt-out is not an opt-out",
                Env {
                    do_not_track: Some("0".into()),
                    disabled: Some("false".into()),
                    ..env()
                },
                Stored::default(),
                true,
            ),
            (
                "a development build stays off",
                env(),
                Stored::default(),
                false,
            ),
            (
                "an explicit endpoint turns a development build on",
                Env {
                    endpoint: Some("http://localhost:4318/v1".into()),
                    ..env()
                },
                Stored::default(),
                false,
            ),
            (
                "debug works on a development build",
                Env {
                    debug: Some("1".into()),
                    ..env()
                },
                Stored::default(),
                false,
            ),
        ];
        let resolved: Vec<(&str, Mode)> = cases
            .iter()
            .map(|(name, env, stored, release)| (*name, resolve_mode(env, stored, *release)))
            .collect();
        assert_eq!(
            resolved,
            vec![
                (
                    "DO_NOT_TRACK beats everything",
                    Mode::Off(OffReason::DoNotTrack)
                ),
                (
                    "ENVIO_TELEMETRY_DISABLED beats a stored enable",
                    Mode::Off(OffReason::EnvVar)
                ),
                (
                    "a stored disable beats debug",
                    Mode::Off(OffReason::UserDisabled)
                ),
                ("debug beats sending", Mode::Debug),
                ("a release build sends", default_send.clone()),
                ("a falsy opt-out is not an opt-out", default_send),
                (
                    "a development build stays off",
                    Mode::Off(OffReason::DevelopmentBuild)
                ),
                (
                    "an explicit endpoint turns a development build on",
                    Mode::Send {
                        endpoint: "http://localhost:4318/v1".into()
                    }
                ),
                ("debug works on a development build", Mode::Debug),
            ]
        );
    }

    #[test]
    fn config_dir_prefers_an_absolute_xdg_config_home() {
        assert_eq!(
            (
                user_config_dir(Some("/xdg".into()), Some("/home/me".into())),
                user_config_dir(Some("relative".into()), Some("/home/me".into())),
                user_config_dir(None, Some("/home/me".into())),
                user_config_dir(None, None),
            ),
            (
                Some(PathBuf::from("/xdg/envio")),
                Some(PathBuf::from("/home/me/.config/envio")),
                Some(PathBuf::from("/home/me/.config/envio")),
                None,
            )
        );
    }

    #[test]
    fn install_id_is_created_once_and_reused() {
        let dir = tempdir::TempDir::new("envio-telemetry").unwrap();
        let mut stored = Stored::default();
        let first = install_id(Some(dir.path()), &mut stored, true);
        let reloaded = Stored::load(Some(dir.path()));
        let mut stored_again = reloaded.clone();
        let second = install_id(Some(dir.path()), &mut stored_again, true);
        assert_eq!(
            (
                first.is_some(),
                first == second,
                reloaded.install_id == first
            ),
            (true, true, true)
        );
    }

    #[test]
    fn install_id_is_not_created_when_it_cannot_persist() {
        let dir = tempdir::TempDir::new("envio-telemetry").unwrap();
        let mut stored = Stored::default();
        assert_eq!(
            (
                install_id(Some(dir.path()), &mut stored, false),
                install_id(None, &mut stored, true),
                dir.path().join(SETTINGS_FILE).exists(),
            ),
            (None, None, false)
        );
    }

    #[test]
    fn indexer_id_lives_in_a_self_ignoring_directory() {
        let dir = tempdir::TempDir::new("envio-telemetry").unwrap();
        let envio_dir = dir.path().join(".envio");
        let peeked = indexer_id(&envio_dir, false);
        let created = indexer_id(&envio_dir, true);
        let reread = indexer_id(&envio_dir, false);
        let gitignore = std::fs::read_to_string(envio_dir.join("telemetry/.gitignore")).ok();
        assert_eq!(
            (peeked, created.is_some(), reread == created, gitignore),
            (None, true, true, Some("*\n".to_string()))
        );
    }
}
