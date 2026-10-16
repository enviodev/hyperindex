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
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc, Mutex, OnceLock,
    },
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
    level: AtomicU32,
}

impl Sink {
    fn new(format: Format, target: Target, level: Level) -> Self {
        Sink {
            format,
            target,
            level: AtomicU32::new(level.value()),
        }
    }

    fn accepts(&self, level: Level) -> bool {
        level.value() >= self.level.load(Ordering::Relaxed)
    }

    fn write(&self, record: &Record, line: &mut Vec<u8>) {
        if let Target::Memory(lines) = &self.target {
            if let Ok(mut lines) = lines.lock() {
                lines.push(format::captured(record));
            }
            return;
        }
        line.clear();
        match self.format {
            Format::Pretty { colorize } => format::pretty(record, colorize, line),
            Format::Json => format::json(record, line),
            Format::Ecs => format::ecs(record, line),
        };
        // A failed write has nowhere to be reported but the log itself.
        let _ = match &self.target {
            Target::Stdout => write_stdout(line),
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
fn write_stdout(line: &[u8]) -> io::Result<()> {
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

/// Colors as the `colorette` package pino-pretty used decided them.
fn stdout_supports_color() -> bool {
    if let Ok(value) = std::env::var("FORCE_COLOR") {
        return value != "0" && value != "false";
    }
    std::env::var_os("NO_COLOR").is_none()
        && std::env::var("TERM").map_or(true, |term| term != "dumb")
        && io::stdout().is_terminal()
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
pub struct LoggerOptions {
    /// One of `LOG_STRATEGY`'s values, or `capture` for a test that reads its
    /// logs back.
    pub strategy: String,
    pub log_file: String,
    /// The level for the terminal, or for the capture.
    pub level: String,
    pub file_level: String,
}

fn parse_level(name: &str) -> napi::Result<Level> {
    Level::parse(name).ok_or_else(|| napi::Error::from_reason(format!("Unknown log level: {name}")))
}

fn sinks_for(options: &LoggerOptions) -> napi::Result<Vec<Sink>> {
    let level = parse_level(&options.level)?;
    let file_level = parse_level(&options.file_level)?;
    let file = || -> napi::Result<Target> {
        open_log_file(&options.log_file)
            .map(|file| Target::File(Mutex::new(file)))
            .map_err(|error| {
                napi::Error::from_reason(format!(
                    "Failed to open the log file {}: {error}",
                    options.log_file
                ))
            })
    };
    let pretty = || Format::Pretty {
        colorize: stdout_supports_color(),
    };
    Ok(match options.strategy.as_str() {
        "ecs-file" => vec![Sink::new(Format::Ecs, file()?, file_level)],
        "ecs-console" | "ecs-console-multistream" => {
            vec![Sink::new(Format::Ecs, Target::Stdout, level)]
        }
        "file-only" => vec![Sink::new(Format::Json, file()?, file_level)],
        "console-raw" | "console-pretty" => vec![Sink::new(pretty(), Target::Stdout, level)],
        "both-prettyconsole" => vec![
            Sink::new(pretty(), Target::Stdout, level),
            Sink::new(Format::Json, file()?, file_level),
        ],
        "capture" => vec![Sink::new(
            Format::Json,
            Target::Memory(Mutex::new(Vec::new())),
            level,
        )],
        other => {
            return Err(napi::Error::from_reason(format!(
                "Unknown log strategy: {other}"
            )))
        }
    })
}

fn fields_or_error(json: &str) -> napi::Result<Fields> {
    fields::parse(json)
        .map_err(|error| napi::Error::from_reason(format!("Log fields aren't JSON: {error}")))
}

/// Where a run's lines go. Holds no fields of its own: a caller's bound fields
/// arrive with each line, so a logger scoped to a chain or a query is a value
/// on the caller's side that costs nothing until it writes.
#[napi]
pub struct Logger {
    sinks: Arc<Vec<Sink>>,
}

impl Logger {
    /// `bindings` are the caller's bound fields and `params` the line's own,
    /// which replace a bound field of the same name.
    pub fn log(&self, level: Level, msg: &str, bindings: &Fields, params: &Fields) {
        if !self.sinks.iter().any(|sink| sink.accepts(level)) {
            return;
        }
        let merged = fields::merge(&[bindings, params]);
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

    fn captured_lines(&self) -> Vec<Value> {
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
    pub fn make(options: LoggerOptions) -> napi::Result<Logger> {
        Ok(Logger {
            sinks: Arc::new(sinks_for(&options)?),
        })
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
        let parse = |json: Option<String>| json.as_deref().map_or(Ok(Vec::new()), fields_or_error);
        self.log(level, &msg, &parse(bindings)?, &parse(params)?);
        Ok(())
    }

    /// Sets the level of every sink but a file, which keeps its own, and
    /// answers with the new `minLevel`.
    #[napi]
    pub fn set_level(&self, level: String) -> napi::Result<u32> {
        let level = parse_level(&level)?;
        for sink in self.sinks.iter() {
            if !matches!(sink.target, Target::File(_)) {
                sink.level.store(level.value(), Ordering::Relaxed);
            }
        }
        Ok(self.min_level())
    }

    /// The lowest level any sink writes, so a caller can skip a line no sink
    /// would take before building it.
    #[napi]
    pub fn min_level(&self) -> u32 {
        self.sinks
            .iter()
            .map(|sink| sink.level.load(Ordering::Relaxed))
            .min()
            .unwrap_or(Level::SILENT.value())
    }

    /// Every line a `capture` logger has taken, oldest first.
    #[napi]
    pub fn captured(&self) -> Vec<Value> {
        self.captured_lines()
    }

    /// Writes what a `capture` logger has taken to `path`, a line of JSON each.
    #[napi]
    pub fn write_captured(&self, path: String) -> napi::Result<()> {
        let mut out = String::new();
        for line in self.captured_lines() {
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

    fn capture(level: &str) -> Logger {
        Logger::make(LoggerOptions {
            strategy: "capture".into(),
            log_file: String::new(),
            level: level.into(),
            file_level: "trace".into(),
        })
        .unwrap()
    }

    #[test]
    fn lines_merge_bindings_and_params_and_follow_the_level() {
        let logger = capture("info");
        let chain = Some(r#"{"chainId":1,"source":"a","source":"b"}"#.to_string());
        logger
            .log_js(Level::TRACE.value(), "hidden".into(), chain.clone(), None)
            .unwrap();
        logger
            .log_js(
                Level::WARN.value(),
                "shown".into(),
                chain,
                Some(r#"{"chainId":2,"a":1}"#.into()),
            )
            .unwrap();
        let min_level = logger.set_level("trace".into()).unwrap();
        logger
            .log_js(Level::TRACE.value(), "now shown".into(), None, None)
            .unwrap();
        assert_eq!(
            (logger.captured(), min_level),
            (
                vec![
                    json!({"level": "warn", "msg": "shown", "chainId": 2, "source": "b", "a": 1}),
                    json!({"level": "trace", "msg": "now shown"}),
                ],
                Level::TRACE.value()
            )
        );
    }

    #[test]
    fn file_sink_appends_json_lines_at_its_own_level() {
        let dir = tempdir::TempDir::new("envio-logger").unwrap();
        let path = dir.path().join("nested/envio.log");
        let logger = Logger::make(LoggerOptions {
            strategy: "file-only".into(),
            log_file: path.to_string_lossy().into(),
            level: "silent".into(),
            file_level: "debug".into(),
        })
        .unwrap();
        logger.set_level("silent".into()).unwrap();
        logger.log(Level::TRACE, "skipped", &Vec::new(), &Vec::new());
        logger.log(
            Level::DEBUG,
            "kept",
            &fields::parse(r#"{"chainId":1}"#).unwrap(),
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
    fn write_captured_dumps_json_lines() {
        let dir = tempdir::TempDir::new("envio-logger").unwrap();
        let path = dir.path().join("logs/run.jsonl");
        let logger = capture("trace");
        logger.log(Level::INFO, "one", &Vec::new(), &Vec::new());
        logger.log(
            Level::ERROR,
            "two",
            &Vec::new(),
            &fields::parse(r#"{"x":1}"#).unwrap(),
        );
        logger
            .write_captured(path.to_string_lossy().into())
            .unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "{\"level\":\"info\",\"msg\":\"one\"}\n{\"level\":\"error\",\"msg\":\"two\",\"x\":1}\n"
        );
    }

    #[test]
    fn unknown_strategy_is_refused_by_name() {
        let error = Logger::make(LoggerOptions {
            strategy: "nope".into(),
            log_file: String::new(),
            level: "info".into(),
            file_level: "trace".into(),
        })
        .err()
        .unwrap();
        assert_eq!(error.reason, "Unknown log strategy: nope");
    }
}
