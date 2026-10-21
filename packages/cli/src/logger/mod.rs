mod fields;
mod format;
mod level;

use fields::Fields;
use format::Record;
pub use level::Level;
use napi::bindgen_prelude::Buffer;
use napi_derive::napi;
use serde_json::Value;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, IsTerminal, Write},
    os::fd::FromRawFd,
    path::Path,
    sync::{mpsc, Mutex, OnceLock},
    thread,
    time::Duration,
};

enum Format {
    Pretty { colorize: bool },
    Json,
    Ecs,
}

enum Target {
    Stdout,
    File(File),
}

impl Target {
    // A failed write has nowhere to be reported but the log itself.
    fn write_all(&self, bytes: &[u8]) {
        let _ = match self {
            Target::Stdout => write_to_stdout_or_above_display(bytes),
            Target::File(file) => (&*file).write_all(bytes),
        };
    }
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

    fn render(&self, record: &Record, out: &mut Vec<u8>) {
        match self.format {
            Format::Pretty { colorize } => format::write_pretty_line(record, colorize, out),
            Format::Json => format::write_json_line(record, out),
            Format::Ecs => format::write_ecs_line(record, out),
        }
    }
}

/// Lines as the caller hands them over, many at a time, in one buffer: parsing,
/// formatting and writing them are the writer thread's. Each line is its level
/// as a byte, its time in milliseconds as a little-endian `f64`, its message,
/// a byte counting its bound fields' JSON objects (the logger's parents' first)
/// and those objects, then its params' JSON object. Each text is a
/// little-endian `u32` byte length and that much UTF-8; `ABSENT` in place of
/// the params' length stands for none.
#[derive(Default)]
struct Batch {
    bytes: Vec<u8>,
    lines: usize,
}

const ABSENT: u32 = u32::MAX;

/// Reads a [`Batch`]'s bytes from the front.
struct Cursor<'a>(&'a [u8]);

impl<'a> Cursor<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        let (taken, rest) = self.0.split_at_checked(len)?;
        self.0 = rest;
        Some(taken)
    }

    fn text(&mut self) -> Option<Option<std::borrow::Cow<'a, str>>> {
        let len = u32::from_le_bytes(self.take(4)?.try_into().ok()?);
        if len == ABSENT {
            return Some(None);
        }
        Some(Some(String::from_utf8_lossy(self.take(len as usize)?)))
    }
}

impl Batch {
    fn with_records(&self, mut f: impl FnMut(&Record)) {
        let mut cursor = Cursor(&self.bytes);
        let parse = |json: Option<std::borrow::Cow<str>>| {
            json.map_or_else(Vec::new, |json| parse_fields_or_keep_as_text(&json))
        };
        let mut layers: Vec<Fields> = Vec::new();
        for _ in 0..self.lines {
            layers.clear();
            // A batch only this module's caller lays out, so a short one ends
            // the batch rather than being reported.
            let Some((level, millis, msg)) = (|| {
                let level = Level::from_value(u32::from(*cursor.take(1)?.first()?))?;
                let millis = f64::from_le_bytes(cursor.take(8)?.try_into().ok()?) as i64;
                let msg = cursor.text()?;
                for _ in 0..*cursor.take(1)?.first()? {
                    layers.push(parse(cursor.text()?));
                }
                layers.push(parse(cursor.text()?));
                Some((level, millis, msg))
            })() else {
                return;
            };
            let layers: Vec<&[(String, Box<serde_json::value::RawValue>)]> =
                layers.iter().map(Vec::as_slice).collect();
            f(&Record {
                level,
                millis,
                msg: msg.as_deref().unwrap_or_default(),
                fields: &fields::merge_later_wins(&layers),
            });
        }
    }

    #[cfg(test)]
    fn push(&mut self, level: Level, msg: &str, bindings: Option<&str>, params: Option<&str>) {
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |since| since.as_millis() as f64);
        fn push_text(bytes: &mut Vec<u8>, text: &str) {
            bytes.extend_from_slice(&(text.len() as u32).to_le_bytes());
            bytes.extend_from_slice(text.as_bytes());
        }
        self.bytes.push(level.value() as u8);
        self.bytes.extend_from_slice(&millis.to_le_bytes());
        push_text(&mut self.bytes, msg);
        self.bytes.push(u8::from(bindings.is_some()));
        if let Some(bindings) = bindings {
            push_text(&mut self.bytes, bindings);
        }
        match params {
            Some(params) => push_text(&mut self.bytes, params),
            None => self.bytes.extend_from_slice(&ABSENT.to_le_bytes()),
        }
        self.lines += 1;
    }
}

enum Message {
    Batch(Batch),
    /// Answered once every batch sent before it is written.
    Flush(mpsc::SyncSender<()>),
}

/// How many batches may wait for the writer before a caller waits with them: a
/// reader that can't keep up slows the indexer rather than filling its memory.
const QUEUE_CAPACITY: usize = 256;

fn spawn_writer(sinks: Vec<Sink>) -> io::Result<mpsc::SyncSender<Message>> {
    let (sender, receiver) = mpsc::sync_channel::<Message>(QUEUE_CAPACITY);
    thread::Builder::new()
        .name("envio-logger".into())
        .spawn(move || {
            let mut outs: Vec<Vec<u8>> = sinks.iter().map(|_| Vec::new()).collect();
            for message in receiver {
                match message {
                    Message::Batch(batch) => {
                        batch.with_records(|record| {
                            for (sink, out) in sinks.iter().zip(outs.iter_mut()) {
                                if record.level >= sink.level {
                                    sink.render(record, out);
                                }
                            }
                        });
                        // One write per sink for the whole batch.
                        for (sink, out) in sinks.iter().zip(outs.iter_mut()) {
                            if !out.is_empty() {
                                sink.target.write_all(out);
                                out.clear();
                            }
                        }
                    }
                    Message::Flush(written) => {
                        let _ = written.send(());
                    }
                }
            }
        })?;
    Ok(sender)
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
            .map(Target::File)
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

enum Output {
    /// Lines a test reads back, kept as they are logged.
    Memory(Mutex<Vec<Value>>),
    /// Formatted and written off the caller's thread, which only hands each
    /// line over.
    Written(mpsc::SyncSender<Message>),
}

/// Where a run's lines go. Holds no fields of its own: a caller's bound fields
/// arrive with each line, so a logger scoped to a chain or a query is a value
/// on the caller's side that costs nothing until it writes.
#[napi]
pub struct Logger {
    min_level: Level,
    output: Output,
}

impl Logger {
    fn take(&self, batch: Batch) {
        match &self.output {
            Output::Memory(lines) => {
                if let Ok(mut lines) = lines.lock() {
                    batch.with_records(|record| lines.push(format::to_captured_line(record)));
                }
            }
            Output::Written(sender) => {
                let _ = sender.send(Message::Batch(batch));
            }
        }
    }

    /// One line, the way `write` takes each of its lines.
    #[cfg(test)]
    fn log(&self, level: Level, msg: &str, bindings: Option<&str>, params: Option<&str>) {
        let mut batch = Batch::default();
        batch.push(level, msg, bindings, params);
        self.take(batch);
    }

    fn read_in_memory_lines(&self) -> Vec<Value> {
        match &self.output {
            Output::Memory(lines) => lines.lock().map(|lines| lines.clone()).unwrap_or_default(),
            Output::Written(_) => Vec::new(),
        }
    }
}

#[napi]
impl Logger {
    #[napi(factory)]
    pub fn make(config: LoggerConfig) -> napi::Result<Logger> {
        let sinks = sinks_for_strategy(&config)?;
        let min_level = sinks
            .iter()
            .map(|sink| sink.level)
            .min()
            .unwrap_or(Level::SILENT);
        let sender = spawn_writer(sinks).map_err(|error| {
            napi::Error::from_reason(format!("Failed to start the log writer: {error}"))
        })?;
        Ok(Logger {
            min_level,
            output: Output::Written(sender),
        })
    }

    /// Keeps every line, trace included, for a test to read back. Not a
    /// `LOG_STRATEGY`, so a deployment can't swallow its own logs.
    #[napi(factory)]
    pub fn make_in_memory() -> Logger {
        Logger {
            min_level: Level::TRACE,
            output: Output::Memory(Mutex::new(Vec::new())),
        }
    }

    /// `level` is the numeric one, which the caller already compared against
    /// `minLevel` before serializing anything. `bindings` and `params` are JSON
    /// objects; a key repeated in `bindings` takes its last value.
    /// Takes the `lines` the caller buffered since its last call, laid out as
    /// a [`Batch`] lays them out. A key repeated in the bound fields takes its
    /// last value, and a param replaces a bound field of the same name. The
    /// caller has already dropped lines below `minLevel`.
    #[napi]
    pub fn write(&self, bytes: Buffer, lines: u32) {
        self.take(Batch {
            bytes: bytes.to_vec(),
            lines: lines as usize,
        });
    }

    /// Returns once every line logged before it is written. Called on exit, so
    /// the lines still waiting for the writer aren't lost with the process.
    #[napi]
    pub fn flush(&self) {
        if let Output::Written(sender) = &self.output {
            let (written, done) = mpsc::sync_channel(1);
            if sender.send(Message::Flush(written)).is_ok() {
                let _ = done.recv();
            }
        }
    }

    /// The lowest level any sink writes, read once when the logger is made so
    /// the caller can skip a line no sink would take before building it.
    #[napi]
    pub fn min_level(&self) -> u32 {
        self.min_level.value()
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
        let chain = Some(r#"{"chainId":1,"source":"a","source":"b"}"#);
        logger.log(Level::TRACE, "bound", chain, None);
        logger.log(
            Level::WARN,
            "overridden",
            chain,
            Some(r#"{"chainId":2,"a":1}"#),
        );
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
        logger.log(Level::TRACE, "skipped", None, None);
        for index in 0..10_000 {
            logger.log(
                Level::DEBUG,
                &format!("kept {index}"),
                Some(r#"{"chainId":1}"#),
                None,
            );
        }
        logger.flush();
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
            (0..10_000)
                .map(|index| json!({"level": 20, "chainId": 1, "msg": format!("kept {index}")}))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn writes_in_memory_lines_to_a_file_as_json_lines() {
        let dir = tempdir::TempDir::new("envio-logger").unwrap();
        let path = dir.path().join("logs/run.jsonl");
        let logger = Logger::make_in_memory();
        logger.log(Level::INFO, "one", None, None);
        logger.log(Level::ERROR, "two", None, Some(r#"{"x":1}"#));
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
        let lone_surrogate_key = r#"{"\ud800":1}"#;
        logger.log(Level::INFO, "kept", None, Some(lone_surrogate_key));
        assert_eq!(
            logger.in_memory_lines(),
            vec![json!({"level": "info", "msg": "kept", "unparsedFields": lone_surrogate_key})]
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
