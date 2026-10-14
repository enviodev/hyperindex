//! Anonymous usage telemetry: one event per CLI command, and a heartbeat from
//! a running indexer when it starts and every 6 hours. `envio telemetry status`
//! prints what would be sent; `DOCS_URL` lists every field and the opt-outs.
//!
//! Nothing here may fail or slow a command. Every entry point swallows its
//! errors, and sending happens in a detached process.

mod error_class;
mod event;
mod settings;
mod transport;

pub use event::{ErrorClass, Outcome};

use crate::{
    cli_args::{clap_definitions::CommandLineArgs, init_config::InitConfig},
    config_parsing::system_config::{self, SystemConfig},
    project_paths::ParsedProjectPaths,
};
use event::{
    Batch, CommandEvent, CommandName, Context, DurationBucket, Environment, Event, EventsBucket,
    Feature, HeartbeatEvent, HeartbeatReason, IndexerProfile, InitChoice, SyncState, UptimeBucket,
    SCHEMA_VERSION,
};
use settings::{Env, Mode, Stored};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Mutex;
use std::time::Instant;

pub const DOCS_URL: &str = "https://docs.envio.dev/docs/HyperIndex/telemetry";

const NOTICE: &str = "\
Envio collects anonymous usage data to improve HyperIndex: which commands and
features are used, and when they fail. It never collects your code, addresses,
ABIs, schema, file paths or keys.
Opt out with `envio telemetry disable` or ENVIO_TELEMETRY_DISABLED=1.";

struct Pending {
    command: CommandName,
    started: Instant,
    init: Option<InitChoice>,
}

struct Session {
    env: Env,
    stored: Stored,
    mode: Mode,
    session_id: String,
    node_major: Option<u32>,
    project: Option<ParsedProjectPaths>,
    indexer_id: Option<Option<String>>,
    pending: Option<Pending>,
    profile: Option<IndexerProfile>,
}

static SESSION: Mutex<Option<Session>> = Mutex::new(None);

fn with_session<T>(f: impl FnOnce(&mut Session) -> T) -> Option<T> {
    let mut guard = SESSION
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    guard.as_mut().map(f)
}

/// `eprintln!` panics when stderr is gone, say a closed pipe.
fn write_stderr(text: &str) {
    use std::io::Write;
    let _ = std::io::stderr().write_all(text.as_bytes());
}

fn is_release_build() -> bool {
    system_config::is_valid_release_version_number(system_config::VERSION)
}

fn node_major(node_version: &str) -> Option<u32> {
    node_version
        .trim_start_matches('v')
        .split('.')
        .next()?
        .parse()
        .ok()
}

/// Called once per process, before the command runs. Prints the first-run
/// notice when this command is about to send for the first time.
pub fn begin(args: &CommandLineArgs, node_version: Option<&str>) {
    let env = Env::from_process();
    let stored = Stored::load(env.config_dir.as_deref());
    let mode = settings::resolve_mode(&env, &stored, is_release_build());
    let command = CommandName::of(&args.command);
    let mut session = Session {
        env,
        stored,
        mode,
        session_id: settings::new_id(),
        node_major: node_version.and_then(node_major),
        project: ParsedProjectPaths::try_from(args.project_paths.clone()).ok(),
        indexer_id: None,
        pending: command.map(|command| Pending {
            command,
            started: Instant::now(),
            init: None,
        }),
        profile: None,
    };
    if session.pending.is_some() {
        session.show_notice_once();
    }
    *SESSION
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(session);
}

/// `envio init` learns what was chosen, and where the project lives, only
/// after its prompts.
pub fn set_init(init_config: &InitConfig, project: &ParsedProjectPaths) {
    with_session(|session| {
        session.project = Some(project.clone());
        session.indexer_id = None;
        if let Some(pending) = session.pending.as_mut() {
            pending.init = Some(InitChoice::of(init_config));
        }
    });
}

/// The config a `start` or `dev` hands to the runtime, kept for its
/// heartbeats.
pub fn set_profile(config: &SystemConfig) {
    with_session(|session| session.profile = Some(IndexerProfile::of(config)));
}

/// Reports the command that's running, unless the runtime already has.
pub fn finish_command(outcome: Outcome, error_class: Option<ErrorClass>) {
    with_session(|session| {
        if let Some(pending) = session.pending.take() {
            let event = session.command_event(pending, outcome, error_class);
            session.dispatch(vec![event]);
        }
    });
}

pub fn finish_command_with_error(err: &anyhow::Error) {
    let (outcome, error_class) = error_class::classify(err);
    finish_command(outcome, Some(error_class));
}

/// What the running indexer reports. Strings arrive from JS, so anything that
/// isn't a known feature or error class is dropped rather than sent.
pub struct RuntimeReport<'a> {
    pub reason: &'a str,
    pub features: &'a [String],
    pub synced: bool,
    pub uptime_seconds: f64,
    pub events_processed: f64,
    pub errors: &'a HashMap<String, u32>,
}

/// The first heartbeat of a `start` or `dev` also reports the command as
/// having succeeded: its job was to get the indexer running.
pub fn heartbeat(report: RuntimeReport) {
    with_session(|session| {
        let Some(profile) = session.profile.clone() else {
            return;
        };
        let Ok(reason) = HeartbeatReason::from_str(report.reason) else {
            return;
        };
        let mut events = vec![];
        if let Some(pending) = session.pending.take() {
            events.push(session.command_event(pending, Outcome::Success, None));
        }
        events.push(Event::Heartbeat(heartbeat_event(
            session.indexer_id(),
            reason,
            profile,
            &report,
        )));
        session.dispatch(events);
    });
}

fn heartbeat_event(
    indexer_id: Option<String>,
    reason: HeartbeatReason,
    mut profile: IndexerProfile,
    report: &RuntimeReport,
) -> HeartbeatEvent {
    profile.features.extend(
        report
            .features
            .iter()
            .filter_map(|feature| Feature::from_str(feature).ok()),
    );
    let mut errors = BTreeMap::new();
    for (class, count) in report.errors {
        if let (Ok(class), true) = (ErrorClass::from_str(class), *count > 0) {
            *errors.entry(class).or_insert(0) += count;
        }
    }
    HeartbeatEvent {
        indexer_id,
        reason,
        profile,
        sync_state: if report.synced {
            SyncState::Synced
        } else {
            SyncState::Backfilling
        },
        uptime: UptimeBucket::of(report.uptime_seconds),
        events_processed: EventsBucket::of(report.events_processed),
        errors,
    }
}

impl Session {
    fn persists(&self) -> bool {
        matches!(self.mode, Mode::Send { .. })
    }

    fn show_notice_once(&mut self) {
        if !self.persists() || self.stored.notice_shown {
            return;
        }
        write_stderr(&format!("{NOTICE}\nLearn more: {DOCS_URL}\n\n"));
        if let Some(dir) = self.env.config_dir.clone() {
            let mut updated = self.stored.clone();
            updated.notice_shown = true;
            if updated.save(&dir).is_ok() {
                self.stored = updated;
            }
        }
    }

    /// Only a directory with a config in it gets an id, so a command run
    /// anywhere else leaves no `.envio` behind. Debug mode stores nothing, and
    /// shows a fresh id where sending would have created one.
    fn indexer_id(&mut self) -> Option<String> {
        if self.indexer_id.is_none() {
            let persist = self.persists();
            let debug = self.mode == Mode::Debug;
            self.indexer_id = Some(
                self.project
                    .as_ref()
                    .filter(|project| project.config.is_file())
                    .and_then(|project| {
                        settings::indexer_id(&project.envio_dir, persist)
                            .or_else(|| debug.then(settings::new_id))
                    }),
            );
        }
        self.indexer_id.clone().flatten()
    }

    fn context(&mut self) -> Context {
        let persist = self.persists();
        let mut install_id =
            settings::install_id(self.env.config_dir.as_deref(), &mut self.stored, persist);
        if install_id.is_none() && self.mode == Mode::Debug {
            let id = settings::new_id();
            self.stored.install_id = Some(id.clone());
            install_id = Some(id);
        }
        context(&self.env, install_id, &self.session_id, self.node_major)
    }

    fn command_event(
        &mut self,
        pending: Pending,
        outcome: Outcome,
        error_class: Option<ErrorClass>,
    ) -> Event {
        Event::Command(CommandEvent {
            indexer_id: self.indexer_id(),
            command: pending.command,
            outcome,
            error_class: if outcome == Outcome::Failure {
                error_class
            } else {
                None
            },
            duration: DurationBucket::of(pending.started.elapsed()),
            init: pending.init,
        })
    }

    fn dispatch(&mut self, events: Vec<Event>) {
        if matches!(self.mode, Mode::Off(_)) || events.is_empty() {
            return;
        }
        let batch = Batch {
            schema_version: SCHEMA_VERSION,
            context: self.context(),
            events,
        };
        match &self.mode {
            Mode::Send { endpoint } => {
                if let Ok(payload) = serde_json::to_string(&batch) {
                    transport::send_detached(endpoint, &payload);
                }
            }
            Mode::Debug => {
                if let Ok(payload) = serde_json::to_string_pretty(&batch) {
                    write_stderr(&format!(
                        "envio telemetry (debug mode, not sent):\n{payload}\n"
                    ));
                }
            }
            Mode::Off(_) => {}
        }
    }
}

fn context(
    env: &Env,
    install_id: Option<String>,
    session_id: &str,
    node_major: Option<u32>,
) -> Context {
    Context {
        install_id,
        session_id: session_id.to_string(),
        envio_version: system_config::VERSION.to_string(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        node_major,
        ci: env.ci,
        environment: if env.kubernetes {
            Environment::Kubernetes
        } else if env.docker {
            Environment::Docker
        } else {
            Environment::Local
        },
    }
}

/// Turns telemetry on or off for this machine. Turning it off also forgets the
/// install id, so turning it back on starts a new one.
pub fn set_enabled(enabled: bool) -> anyhow::Result<PathBuf> {
    let env = Env::from_process();
    let dir = env.config_dir.ok_or_else(|| {
        anyhow::anyhow!(
            "Couldn't find a config directory (HOME isn't set). Set \
             ENVIO_TELEMETRY_DISABLED=1 in the environment instead."
        )
    })?;
    let mut stored = Stored::load(Some(&dir));
    stored.enabled = Some(enabled);
    stored.notice_shown = true;
    if !enabled {
        stored.install_id = None;
    }
    stored.save(&dir)?;
    Ok(Stored::path(&dir))
}

/// `envio telemetry status`: whether anything is sent, why, and the batches a
/// command and a heartbeat in this directory would send. Writes nothing; ids
/// that don't exist yet are shown as the fresh ones that would be created.
pub fn status_report(project: &ParsedProjectPaths) -> String {
    use std::fmt::Write;

    let (env, stored, mode, session_id, node_major) = with_session(|session| {
        (
            session.env.clone(),
            session.stored.clone(),
            session.mode.clone(),
            session.session_id.clone(),
            session.node_major,
        )
    })
    .unwrap_or_else(|| {
        let env = Env::from_process();
        let stored = Stored::load(env.config_dir.as_deref());
        let mode = settings::resolve_mode(&env, &stored, is_release_build());
        (env, stored, mode, settings::new_id(), None)
    });

    let mut out = String::new();
    let _ = match &mode {
        Mode::Send { endpoint } => writeln!(out, "Telemetry is on. Events are sent to {endpoint}."),
        Mode::Debug => writeln!(
            out,
            "Telemetry is in debug mode (ENVIO_TELEMETRY_DEBUG is set): events are printed to \
             stderr and never sent."
        ),
        Mode::Off(reason) => writeln!(
            out,
            "Telemetry is off: {}. Nothing is sent.",
            reason.describe()
        ),
    };

    let stored_install_id = stored.install_id.clone();
    let install_id = stored_install_id.clone().unwrap_or_else(settings::new_id);
    let _ = match (&env.config_dir, &stored_install_id) {
        (Some(dir), Some(_)) => writeln!(
            out,
            "Install ID: {install_id} (stored in {})",
            Stored::path(dir).display()
        ),
        (Some(dir), None) => writeln!(
            out,
            "Install ID: not created yet; the first send stores one in {}",
            Stored::path(dir).display()
        ),
        (None, _) => writeln!(out, "Install ID: none, since HOME isn't set"),
    };

    let has_project = project.config.is_file();
    let indexer_id = has_project
        .then(|| settings::indexer_id(&project.envio_dir, false).unwrap_or_else(settings::new_id));
    if has_project {
        let _ = writeln!(
            out,
            "Indexer ID: kept in {}",
            project.envio_dir.join("telemetry").display()
        );
    }

    let context = context(&env, Some(install_id), &session_id, node_major);
    let command_batch = Batch {
        schema_version: SCHEMA_VERSION,
        context: context.clone(),
        events: vec![Event::Command(CommandEvent {
            indexer_id: indexer_id.clone(),
            command: CommandName::Codegen,
            outcome: Outcome::Success,
            error_class: None,
            duration: DurationBucket::UnderOneSecond,
            init: None,
        })],
    };
    let _ = writeln!(
        out,
        "\n{}\nEach command sends one event, like this for `envio codegen` here:\n{}",
        match mode {
            Mode::Off(_) => "If it were on, this is what would be sent.",
            Mode::Send { .. } | Mode::Debug => "This is what is sent.",
        },
        serde_json::to_string_pretty(&command_batch).unwrap_or_default()
    );

    match has_project.then(|| SystemConfig::parse_from_project_files(project)) {
        Some(Ok(config)) => {
            let heartbeat_batch = Batch {
                schema_version: SCHEMA_VERSION,
                context,
                events: vec![Event::Heartbeat(heartbeat_event(
                    indexer_id,
                    HeartbeatReason::Start,
                    IndexerProfile::of(&config),
                    &RuntimeReport {
                        reason: "start",
                        features: &[],
                        synced: false,
                        uptime_seconds: 0.0,
                        events_processed: 0.0,
                        errors: &HashMap::new(),
                    },
                ))],
            };
            let _ = writeln!(
                out,
                "\nA running indexer sends a heartbeat when it starts and every 6 hours. This \
                 indexer's first one would be the following, plus any of the features `effects`, \
                 `contract_register`, `wildcard`, `block_handlers`, `dev_mode`, `split_run` and \
                 `isolated_chains` its handlers and command use:\n{}",
                serde_json::to_string_pretty(&heartbeat_batch).unwrap_or_default()
            );
        }
        Some(Err(_)) => {
            let _ = writeln!(
                out,
                "\nThe config here doesn't parse, so its heartbeat can't be shown."
            );
        }
        None => {
            let _ = writeln!(
                out,
                "\nRun this in an indexer's directory to see the heartbeat it would send."
            );
        }
    }
    let _ = writeln!(
        out,
        "\nWhat each field means, and how to opt out: {DOCS_URL}"
    );
    out
}

#[cfg(test)]
mod tests;
