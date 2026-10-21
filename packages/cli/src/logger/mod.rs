mod fields;
mod format;
mod level;

use fields::Fields;
use format::Record;
pub use level::Level;
use napi_derive::napi;
use serde_json::Value;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, IsTerminal, Write},
    os::fd::FromRawFd,
    path::Path,
    sync::{Mutex, OnceLock},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

enum Format {
    Pretty { colorize: bool },
    Json,
    Ecs,
}

enum Target {
    Stdout,
    File(Mutex<File>),
    Memory(Mutex<Vec<Value>>),
}

struct Sink {
    format: Format,
    target: Target,
    level: Level,
}

impl Sink {
    fn new(format: Format, target: Target, level: Level) -> Self {
        Sink {
            format,
            target,
            level,
        }
    }

    fn accepts(&self, level: Level) -> bool {
        level >= self.level
    }

    fn write(&self, record: &Record, line: &mut Vec<u8>) {
        if let Target::Memory(lines) = &self.target {
            if let Ok(mut lines) = lines.lock() {
                lines.push(format::to_captured_line(record));
            }
            return;
        }
        line.clear();
        match self.format {
            Format::Pretty { colorize } => format::write_pretty_line(record, colorize, line),
            Format::Json => format::write_json_line(record, line),
            Format::Ecs => format::write_ecs_line(record, line),
        };
        // A failed write has nowhere to be reported but the log itself.
        let _ = match &self.target {
            Target::Stdout => write_to_stdout_or_above_display(line),
            Target::File(file) => file
                .lock()
                .map_err(|_| io::Error::other("log file lock poisoned"))
                .and_then(|mut file| file.write_all(line)),
            Target::Memory(_) => Ok(()),
        };
    }
}

/// Stdout through a descriptor of the logger's own: Node may switch the
/// terminal or pipe to non-blocking mode, and a line that would block waits
/// instead of being dropped with `EAGAIN`.
fn write_to_stdout_or_above_display(line: &[u8]) -> io::Result<()> {
    if crate::tui::print_above_stdout(String::from_utf8_lossy(line).trim_end_matches('\n')) {
        return Ok(());
    }
    static STDOUT: OnceLock<Option<File>> = OnceLock::new();
    let stdout = STDOUT.get_or_init(|| {
        // SAFETY: `dup` returns a new descriptor or -1.
        let fd = unsafe { libc::dup(libc::STDOUT_FILENO) };
        // SAFETY: the descriptor was just created and nothing else owns it.
        (fd >= 0).then(|| unsafe { File::from_raw_fd(fd) })
    });
    let Some(mut stdout) = stdout.as_ref() else {
        return io::stdout().write_all(line);
    };
    let mut rest = line;
    while !rest.is_empty() {
        match stdout.write(rest) {
            Ok(written) => rest = &rest[written..],
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(1))
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

/// A line already written by a worker's logger, passed on as it is: above the
/// display while one is running, to stdout otherwise.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn write_stdout_line(line: String) {
    let _ = write_to_stdout_or_above_display(format!("{line}\n").as_bytes());
}

/// The same for a worker's stderr.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn write_stderr_line(line: String) {
    let _ = crate::tui::LogWriter.write_all(format!("{line}\n").as_bytes());
}

/// `NO_COLOR` wins over `FORCE_COLOR`, which the supervisor sets for workers
/// whose output it pipes to a terminal.
fn supports_color(
    force_color: Option<&str>,
    no_color: bool,
    term: Option<&str>,
    is_terminal: bool,
) -> bool {
    if no_color {
        return false;
    }
    match force_color {
        Some(value) => value != "0" && value != "false",
        None => term != Some("dumb") && is_terminal,
    }
}

fn stdout_supports_color() -> bool {
    supports_color(
        std::env::var("FORCE_COLOR").ok().as_deref(),
        std::env::var_os("NO_COLOR").is_some(),
        std::env::var("TERM").ok().as_deref(),
        io::stdout().is_terminal(),
    )
}

fn open_log_file(path: &str) -> io::Result<File> {
    if let Some(dir) = Path::new(path)
        .parent()
        .filter(|dir| !dir.as_os_str().is_empty())
    {
        fs::create_dir_all(dir)?;
    }
    OpenOptions::new().create(true).append(true).open(path)
}

/// Where a run's logs go and how they read there, as `LOG_STRATEGY` names it.
#[napi(object)]
pub struct LoggerConfig {
    /// One of `LOG_STRATEGIES`.
    pub strategy: String,
    pub log_file: String,
    /// The level for the terminal.
    pub level: String,
    pub file_level: String,
}

/// The values `LOG_STRATEGY` takes, in the order an error lists them.
const LOG_STRATEGIES: [&str; 7] = [
    "console-pretty",
    "console-raw",
    "ecs-console",
    "ecs-console-multistream",
    "ecs-file",
    "file-only",
    "both-prettyconsole",
];

fn parse_level(name: &str) -> napi::Result<Level> {
    Level::parse(name).ok_or_else(|| napi::Error::from_reason(format!("Unknown log level: {name}")))
}

fn sinks_for_strategy(config: &LoggerConfig) -> napi::Result<Vec<Sink>> {
    let level = parse_level(&config.level)?;
    let file_level = parse_level(&config.file_level)?;
    let file = || -> napi::Result<Target> {
        open_log_file(&config.log_file)
            .map(|file| Target::File(Mutex::new(file)))
            .map_err(|error| {
                napi::Error::from_reason(format!(
                    "Failed to open the log file {}: {error}",
                    config.log_file
                ))
            })
    };
    let pretty = || Format::Pretty {
        colorize: stdout_supports_color(),
    };
    Ok(match config.strategy.as_str() {
        // pino gated these at the logger before the file's own level: info
        // for `ecs-file`, the terminal's level for `both-prettyconsole`.
        "ecs-file" => vec![Sink::new(Format::Ecs, file()?, file_level.max(Level::INFO))],
        "ecs-console" | "ecs-console-multistream" => {
            vec![Sink::new(Format::Ecs, Target::Stdout, level)]
        }
        "file-only" => vec![Sink::new(Format::Json, file()?, file_level)],
        "console-raw" | "console-pretty" => vec![Sink::new(pretty(), Target::Stdout, level)],
        "both-prettyconsole" => vec![
            Sink::new(pretty(), Target::Stdout, level),
            Sink::new(Format::Json, file()?, file_level.max(level)),
        ],
        other => {
            return Err(napi::Error::from_reason(format!(
                "Invalid LOG_STRATEGY \"{other}\". Expected one of: {}.",
                LOG_STRATEGIES.join(", ")
            )))
        }
    })
}

/// JS's `JSON.stringify` writes some text serde refuses, such as a lone
/// surrogate; a log call never throws over its fields, so the line keeps them
/// as text.
fn parse_fields_or_keep_as_text(json: &str) -> Fields {
    fields::parse_object_fields(json).unwrap_or_else(|_| {
        serde_json::value::to_raw_value(json)
            .map(|raw| vec![("unparsedFields".to_string(), raw)])
            .unwrap_or_default()
    })
}

/// Where a run's lines go. Holds no fields of its own: a caller's bound fields
/// arrive with each line, so a logger scoped to a chain or a query is a value
/// on the caller's side that costs nothing until it writes.
#[napi]
pub struct Logger {
    sinks: Vec<Sink>,
}

impl Logger {
    /// `bindings` are the caller's bound fields and `params` the line's own,
    /// which replace a bound field of the same name.
    pub fn log(&self, level: Level, msg: &str, bindings: &Fields, params: &Fields) {
        if !self.sinks.iter().any(|sink| sink.accepts(level)) {
            return;
        }
        let merged = fields::merge_later_wins(&[bindings, params]);
        let record = Record {
            level,
            millis: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |since| since.as_millis() as i64),
            msg,
            fields: &merged,
        };
        let mut line = Vec::with_capacity(256);
        for sink in self.sinks.iter().filter(|sink| sink.accepts(level)) {
            sink.write(&record, &mut line);
        }
    }

    fn read_in_memory_lines(&self) -> Vec<Value> {
        self.sinks
            .iter()
            .filter_map(|sink| match &sink.target {
                Target::Memory(lines) => Some(lines),
                _ => None,
            })
            .flat_map(|lines| lines.lock().map(|lines| lines.clone()).unwrap_or_default())
            .collect()
    }
}

#[napi]
impl Logger {
    #[napi(factory)]
    pub fn make(config: LoggerConfig) -> napi::Result<Logger> {
        Ok(Logger {
            sinks: sinks_for_strategy(&config)?,
        })
    }

    /// Keeps every line, trace included, for a test to read back. Not a
    /// `LOG_STRATEGY`, so a deployment can't swallow its own logs.
    #[napi(factory)]
    pub fn make_in_memory() -> Logger {
        Logger {
            sinks: vec![Sink::new(
                Format::Json,
                Target::Memory(Mutex::new(Vec::new())),
                Level::TRACE,
            )],
        }
    }

    /// `level` is the numeric one, which the caller already compared against
    /// `minLevel` before serializing anything. `bindings` and `params` are JSON
    /// objects; a key repeated in `bindings` takes its last value.
    #[napi(js_name = "log")]
    pub fn log_js(
        &self,
        level: u32,
        msg: String,
        bindings: Option<String>,
        params: Option<String>,
    ) -> napi::Result<()> {
        let level = Level::from_value(level)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown log level: {level}")))?;
        let parse = |json: Option<String>| {
            json.as_deref()
                .map_or_else(Vec::new, parse_fields_or_keep_as_text)
        };
        self.log(level, &msg, &parse(bindings), &parse(params));
        Ok(())
    }

    /// The lowest level any sink writes, read once when the logger is made so
    /// the caller can skip a line no sink would take before building it.
    #[napi]
    pub fn min_level(&self) -> u32 {
        self.sinks
            .iter()
            .map(|sink| sink.level.value())
            .min()
            .unwrap_or(Level::SILENT.value())
    }

    /// Every line an in-memory logger has taken, oldest first.
    #[napi]
    pub fn in_memory_lines(&self) -> Vec<Value> {
        self.read_in_memory_lines()
    }

    /// Writes what an in-memory logger has taken to `path`, a line of JSON
    /// each.
    #[napi]
    pub fn write_in_memory_lines_to_file(&self, path: String) -> napi::Result<()> {
        let mut out = String::new();
        for line in self.read_in_memory_lines() {
            out.push_str(&line.to_string());
            out.push('\n');
        }
        if let Some(dir) = Path::new(&path).parent() {
            fs::create_dir_all(dir).map_err(|e| napi::Error::from_reason(e.to_string()))?;
        }
        fs::write(&path, out)
            .map_err(|e| napi::Error::from_reason(format!("Failed to write {path}: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn lines_merge_bindings_and_params() {
        let logger = Logger::make_in_memory();
        let chain = Some(r#"{"chainId":1,"source":"a","source":"b"}"#.to_string());
        logger
            .log_js(Level::TRACE.value(), "bound".into(), chain.clone(), None)
            .unwrap();
        logger
            .log_js(
                Level::WARN.value(),
                "overridden".into(),
                chain,
                Some(r#"{"chainId":2,"a":1}"#.into()),
            )
            .unwrap();
        assert_eq!(
            (logger.in_memory_lines(), logger.min_level()),
            (
                vec![
                    json!({"level": "trace", "msg": "bound", "chainId": 1, "source": "b"}),
                    json!({"level": "warn", "msg": "overridden", "chainId": 2, "source": "b", "a": 1}),
                ],
                Level::TRACE.value()
            )
        );
    }

    #[test]
    fn file_level_is_capped_by_the_terminal_level_where_pino_capped_it() {
        let dir = tempdir::TempDir::new("envio-logger").unwrap();
        let min_level = |strategy: &str, level: &str, file_level: &str| {
            Logger::make(LoggerConfig {
                strategy: strategy.into(),
                log_file: dir.path().join("envio.log").to_string_lossy().into(),
                level: level.into(),
                file_level: file_level.into(),
            })
            .unwrap()
            .min_level()
        };
        assert_eq!(
            [
                min_level("ecs-file", "trace", "trace"),
                min_level("ecs-file", "info", "warn"),
                min_level("both-prettyconsole", "info", "trace"),
                min_level("both-prettyconsole", "warn", "error"),
                min_level("file-only", "info", "trace"),
            ],
            [
                Level::INFO.value(),
                Level::WARN.value(),
                Level::INFO.value(),
                Level::WARN.value(),
                Level::TRACE.value(),
            ]
        );
    }

    #[test]
    fn file_sink_appends_json_lines_at_its_own_level() {
        let dir = tempdir::TempDir::new("envio-logger").unwrap();
        let path = dir.path().join("nested/envio.log");
        let logger = Logger::make(LoggerConfig {
            strategy: "file-only".into(),
            log_file: path.to_string_lossy().into(),
            level: "silent".into(),
            file_level: "debug".into(),
        })
        .unwrap();
        logger.log(Level::TRACE, "skipped", &Vec::new(), &Vec::new());
        logger.log(
            Level::DEBUG,
            "kept",
            &fields::parse_object_fields(r#"{"chainId":1}"#).unwrap(),
            &Vec::new(),
        );
        let lines: Vec<Value> = fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(|line| {
                let mut value: Value = serde_json::from_str(line).unwrap();
                value.as_object_mut().unwrap().remove("time");
                value
            })
            .collect();
        assert_eq!(
            lines,
            vec![json!({"level": 20, "chainId": 1, "msg": "kept"})]
        );
    }

    #[test]
    fn writes_in_memory_lines_to_a_file_as_json_lines() {
        let dir = tempdir::TempDir::new("envio-logger").unwrap();
        let path = dir.path().join("logs/run.jsonl");
        let logger = Logger::make_in_memory();
        logger.log(Level::INFO, "one", &Vec::new(), &Vec::new());
        logger.log(
            Level::ERROR,
            "two",
            &Vec::new(),
            &fields::parse_object_fields(r#"{"x":1}"#).unwrap(),
        );
        logger
            .write_in_memory_lines_to_file(path.to_string_lossy().into())
            .unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "{\"level\":\"info\",\"msg\":\"one\"}\n{\"level\":\"error\",\"msg\":\"two\",\"x\":1}\n"
        );
    }

    #[test]
    fn fields_serde_rejects_still_log_the_line() {
        let logger = Logger::make_in_memory();
        let lone_surrogate_key = r#"{"\ud800":1}"#.to_string();
        let result = logger.log_js(
            Level::INFO.value(),
            "kept".into(),
            None,
            Some(lone_surrogate_key.clone()),
        );
        assert_eq!(
            (result.is_ok(), logger.in_memory_lines()),
            (
                true,
                vec![json!({"level": "info", "msg": "kept", "unparsedFields": lone_surrogate_key})]
            )
        );
    }

    #[test]
    fn no_color_wins_over_force_color() {
        assert_eq!(
            [
                supports_color(Some("1"), true, None, true),
                supports_color(Some("1"), false, None, false),
                supports_color(Some("0"), false, None, true),
                supports_color(None, false, Some("dumb"), true),
                supports_color(None, false, None, true),
            ],
            [false, true, false, false, true]
        );
    }

    #[test]
    fn unknown_strategy_is_refused_by_name() {
        let refusal = |strategy: &str| {
            Logger::make(LoggerConfig {
                strategy: strategy.into(),
                log_file: String::new(),
                level: "info".into(),
                file_level: "trace".into(),
            })
            .err()
            .map(|error| error.reason.clone())
        };
        let expected = |strategy: &str| {
            Some(format!("Invalid LOG_STRATEGY \"{strategy}\". Expected one of: console-pretty, console-raw, ecs-console, ecs-console-multistream, ecs-file, file-only, both-prettyconsole."))
        };
        assert_eq!(
            (refusal("nope"), refusal("in-memory")),
            (expected("nope"), expected("in-memory"))
        );
    }
}
