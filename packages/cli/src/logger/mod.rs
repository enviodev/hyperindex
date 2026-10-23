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
    mem::ManuallyDrop,
    os::fd::FromRawFd,
    path::Path,
    sync::{mpsc, Mutex, OnceLock},
    thread,
    time::{Duration, Instant},
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

struct Cursor<'a>(&'a [u8]);

impl<'a> Cursor<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        let (taken, rest) = self.0.split_at_checked(len)?;
        self.0 = rest;
        Some(taken)
    }

    fn text(&mut self) -> Option<std::borrow::Cow<'a, str>> {
        let len = u32::from_le_bytes(self.take(4)?.try_into().ok()?);
        Some(String::from_utf8_lossy(self.take(len as usize)?))
    }

    /// A text that may be `ABSENT`.
    fn optional_text(&mut self) -> Option<Option<std::borrow::Cow<'a, str>>> {
        let len = u32::from_le_bytes(self.0.get(..4)?.try_into().ok()?);
        if len == ABSENT {
            self.take(4)?;
            return Some(None);
        }
        self.text().map(Some)
    }
}

impl Batch {
    fn with_records(&self, mut f: impl FnMut(&Record)) {
        let mut cursor = Cursor(&self.bytes);
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
                    layers.push(parse_fields_or_keep_as_text(&cursor.text()?));
                }
                if let Some(params) = cursor.optional_text()? {
                    layers.push(parse_fields_or_keep_as_text(&params));
                }
                Some((level, millis, msg))
            })() else {
                return;
            };
            let layers: Vec<&[(String, Box<serde_json::value::RawValue>)]> =
                layers.iter().map(Vec::as_slice).collect();
            f(&Record {
                level,
                millis,
                msg: &msg,
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
const QUEUE_CAPACITY: usize = 16;

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
                                if record.level.severity() >= sink.level.severity() {
                                    sink.render(record, out);
                                }
                            }
                        });
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

struct Stream {
    /// The process's own descriptor, which the stream must never close.
    file: ManuallyDrop<File>,
    /// Workers share their supervisor's pipe, and only a write of at most
    /// `PIPE_BUF` bytes reaches it whole, so a batch is cut into such writes at
    /// line ends.
    is_pipe: bool,
}

impl Stream {
    fn new(fd: libc::c_int) -> Stream {
        // SAFETY: the standard streams stay open for the life of the process,
        // and `ManuallyDrop` keeps the `File` from closing one.
        let file = ManuallyDrop::new(unsafe { File::from_raw_fd(fd) });
        let is_pipe = file
            .metadata()
            .is_ok_and(|metadata| std::os::unix::fs::FileTypeExt::is_fifo(&metadata.file_type()));
        Stream { file, is_pipe }
    }

    fn write_all(&self, bytes: &[u8]) -> io::Result<()> {
        if self.is_pipe {
            line_chunks(bytes, libc::PIPE_BUF)
                .try_for_each(|chunk| write_waiting(&self.file, chunk))
        } else {
            write_waiting(&self.file, bytes)
        }
    }
}

/// Node may switch a terminal or pipe to non-blocking mode, so a write that
/// would block is retried instead of being dropped with `EAGAIN`.
fn write_waiting(mut file: &File, bytes: &[u8]) -> io::Result<()> {
    let mut rest = bytes;
    while !rest.is_empty() {
        match file.write(rest) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
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

/// `bytes` in pieces of at most `max` bytes that each end a line, except a
/// line longer than `max`, which is a piece of its own.
fn line_chunks(bytes: &[u8], max: usize) -> impl Iterator<Item = &[u8]> {
    let mut rest = bytes;
    std::iter::from_fn(move || {
        if rest.is_empty() {
            return None;
        }
        let end = if rest.len() <= max {
            rest.len()
        } else {
            match rest[..max].iter().rposition(|&byte| byte == b'\n') {
                Some(newline) => newline + 1,
                None => rest
                    .iter()
                    .position(|&byte| byte == b'\n')
                    .map_or(rest.len(), |newline| newline + 1),
            }
        };
        let (chunk, tail) = rest.split_at(end);
        rest = tail;
        Some(chunk)
    })
}

fn stdout() -> &'static Stream {
    static STDOUT: OnceLock<Stream> = OnceLock::new();
    STDOUT.get_or_init(|| Stream::new(libc::STDOUT_FILENO))
}

fn stderr() -> &'static Stream {
    static STDERR: OnceLock<Stream> = OnceLock::new();
    STDERR.get_or_init(|| Stream::new(libc::STDERR_FILENO))
}

/// Above the display while one is running, which a direct write would land in
/// the middle of, and to stdout otherwise.
fn write_to_stdout_or_above_display(bytes: &[u8]) -> io::Result<()> {
    if crate::tui::print_above_stdout(bytes) {
        return Ok(());
    }
    stdout().write_all(bytes)
}

/// A line already written by a worker's logger, passed on as it is.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn write_stdout_line(line: String) {
    let _ = write_to_stdout_or_above_display(format!("{line}\n").as_bytes());
}

#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn write_stderr_line(line: String) {
    let line = format!("{line}\n");
    if !crate::tui::print_above_stderr(line.as_bytes()) {
        let _ = stderr().write_all(line.as_bytes());
    }
}

/// `NO_COLOR` wins over `FORCE_COLOR`, which the supervisor sets for workers
/// whose output it pipes to a terminal. CI log viewers render colour, so CI
/// output is coloured though it isn't a terminal.
fn supports_color(
    force_color: Option<&str>,
    no_color: bool,
    term: Option<&str>,
    is_terminal: bool,
    is_ci: bool,
) -> bool {
    if no_color {
        return false;
    }
    match force_color {
        Some(value) => value != "0" && value != "false",
        None => (term != Some("dumb") && is_terminal) || is_ci,
    }
}

fn stdout_supports_color() -> bool {
    supports_color(
        std::env::var("FORCE_COLOR").ok().as_deref(),
        std::env::var_os("NO_COLOR").is_some(),
        std::env::var("TERM").ok().as_deref(),
        io::stdout().is_terminal(),
        std::env::var_os("CI").is_some()
            && ["GITHUB_ACTIONS", "GITLAB_CI", "CIRCLECI"]
                .iter()
                .any(|name| std::env::var_os(name).is_some()),
    )
}

fn create_parent_dir(path: &str) -> io::Result<()> {
    match Path::new(path).parent() {
        Some(dir) => fs::create_dir_all(dir),
        None => Ok(()),
    }
}

fn open_log_file(path: &str) -> io::Result<File> {
    create_parent_dir(path)?;
    OpenOptions::new().create(true).append(true).open(path)
}

#[napi(object)]
pub struct LoggerConfig {
    pub strategy: String,
    pub log_file: String,
    /// The terminal's level.
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
        // A file never takes lines below info for `ecs-file`, or below the
        // terminal's level for `both-prettyconsole`.
        "ecs-file" => vec![Sink {
            format: Format::Ecs,
            target: file()?,
            level: file_level.at_least(Level::INFO),
        }],
        "ecs-console" | "ecs-console-multistream" => {
            vec![Sink {
                format: Format::Ecs,
                target: Target::Stdout,
                level,
            }]
        }
        "file-only" => vec![Sink {
            format: Format::Json,
            target: file()?,
            level: file_level,
        }],
        "console-raw" | "console-pretty" => vec![Sink {
            format: pretty(),
            target: Target::Stdout,
            level,
        }],
        "both-prettyconsole" => vec![
            Sink {
                format: pretty(),
                target: Target::Stdout,
                level,
            },
            Sink {
                format: Format::Json,
                target: file()?,
                level: file_level.at_least(level),
            },
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

    #[cfg(test)]
    fn log(&self, level: Level, msg: &str, bindings: Option<&str>, params: Option<&str>) {
        let mut batch = Batch::default();
        batch.push(level, msg, bindings, params);
        self.take(batch);
    }

    /// The writer may be stuck on a full queue as well as on a write, so the
    /// request to flush waits within the same deadline as its answer.
    fn flush_within(&self, timeout: Duration) {
        let Output::Written(sender) = &self.output else {
            return;
        };
        let deadline = Instant::now() + timeout;
        let (written, done) = mpsc::sync_channel(1);
        let mut message = Message::Flush(written);
        loop {
            match sender.try_send(message) {
                Ok(()) => {
                    let _ = done.recv_timeout(deadline.saturating_duration_since(Instant::now()));
                    return;
                }
                Err(mpsc::TrySendError::Full(unsent)) if Instant::now() < deadline => {
                    message = unsent;
                    thread::sleep(Duration::from_millis(1));
                }
                Err(_) => return,
            }
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
            .min_by_key(|level| level.severity())
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
    /// the lines still waiting for the writer aren't lost with the process; a
    /// reader that has stopped reading can't keep the process from exiting.
    #[napi]
    pub fn flush(&self) {
        self.flush_within(Duration::from_secs(5));
    }

    /// The lowest level any sink writes, read once when the logger is made so
    /// the caller can skip a line no sink would take before building it.
    #[napi]
    pub fn min_level(&self) -> u32 {
        self.min_level.severity()
    }

    #[napi]
    pub fn in_memory_lines(&self) -> Vec<Value> {
        match &self.output {
            Output::Memory(lines) => lines.lock().map(|lines| lines.clone()).unwrap_or_default(),
            Output::Written(_) => Vec::new(),
        }
    }

    #[napi]
    pub fn write_in_memory_lines_to_file(&self, path: String) -> napi::Result<()> {
        let mut out = String::new();
        for line in self.in_memory_lines() {
            out.push_str(&line.to_string());
            out.push('\n');
        }
        create_parent_dir(&path)
            .and_then(|()| fs::write(&path, out))
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
    fn file_level_is_capped_for_ecs_file_and_both_prettyconsole() {
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
    fn a_damaged_batch_keeps_the_lines_before_the_damage() {
        let logger = Logger::make_in_memory();
        let mut cut_short = Batch::default();
        cut_short.push(Level::INFO, "whole", None, None);
        cut_short.push(Level::INFO, "cut", None, Some(r#"{"a":1}"#));
        cut_short.bytes.truncate(cut_short.bytes.len() - 3);
        cut_short.lines += 1;
        logger.take(cut_short);
        let mut unknown_level = Batch::default();
        unknown_level.push(Level::INFO, "unknown level", None, None);
        unknown_level.bytes[0] = 99;
        logger.take(unknown_level);
        assert_eq!(
            logger.in_memory_lines(),
            vec![json!({"level": "info", "msg": "whole"})]
        );
    }

    #[test]
    fn flush_gives_up_on_a_writer_stuck_on_a_reader_that_stopped_reading() {
        let mut fds = [0; 2];
        // SAFETY: `pipe` fills both descriptors, which the `File`s then own.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let (reader, writer) = unsafe { (File::from_raw_fd(fds[0]), File::from_raw_fd(fds[1])) };
        let logger = std::sync::Arc::new(Logger {
            min_level: Level::TRACE,
            output: Output::Written(
                spawn_writer(vec![Sink {
                    format: Format::Json,
                    target: Target::File(writer),
                    level: Level::TRACE,
                }])
                .unwrap(),
            ),
        });
        let line = "x".repeat(1 << 17);
        let filling = {
            let logger = logger.clone();
            thread::spawn(move || {
                for _ in 0..QUEUE_CAPACITY * 2 {
                    logger.log(Level::INFO, &line, None, None);
                }
            })
        };
        thread::sleep(Duration::from_millis(200));
        let (flushed, gave_up) = mpsc::channel();
        let flushing = {
            let logger = logger.clone();
            thread::spawn(move || {
                logger.flush_within(Duration::from_millis(100));
                let _ = flushed.send(());
            })
        };
        let returned = gave_up.recv_timeout(Duration::from_secs(3)).is_ok();
        drop(reader);
        filling.join().unwrap();
        flushing.join().unwrap();
        assert!(returned);
    }

    #[test]
    fn a_users_level_passes_where_its_standard_counterpart_does() {
        let dir = tempdir::TempDir::new("envio-logger").unwrap();
        let written_at = |file_level: &str| {
            let path = dir.path().join(format!("{file_level}.log"));
            let logger = Logger::make(LoggerConfig {
                strategy: "file-only".into(),
                log_file: path.to_string_lossy().into(),
                level: "silent".into(),
                file_level: file_level.into(),
            })
            .unwrap();
            for level in Level::ALL {
                logger.log(level, level.name(), None, None);
            }
            logger.flush();
            let names: Vec<String> = fs::read_to_string(&path)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str::<Value>(line).unwrap()["msg"].to_string())
                .collect();
            (logger.min_level(), names.join(" ").replace('"', ""))
        };
        assert_eq!(
            [
                written_at("warn"),
                written_at("uerror"),
                written_at("uinfo")
            ],
            [
                (40, "uwarn uerror warn error fatal".to_string()),
                (50, "uerror error fatal".to_string()),
                (30, "info uinfo uwarn uerror warn error fatal".to_string()),
            ]
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
    fn pipe_writes_end_at_lines_and_fit_the_atomic_size() {
        let chunks = |text: &str, max| {
            line_chunks(text.as_bytes(), max)
                .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            (
                chunks("aa\nbbbb\ncc\n", 5),
                chunks("aa\nbbbb\ncc\n", 8),
                chunks("xxxxxxxxxx\nyy\n", 4),
                chunks("ab", 4),
            ),
            (
                vec!["aa\n".to_string(), "bbbb\n".into(), "cc\n".into()],
                vec!["aa\nbbbb\n".to_string(), "cc\n".into()],
                vec!["xxxxxxxxxx\n".to_string(), "yy\n".into()],
                vec!["ab".to_string()],
            )
        );
    }

    #[test]
    fn no_color_wins_over_force_color() {
        assert_eq!(
            [
                supports_color(Some("1"), true, None, true, false),
                supports_color(Some("1"), false, None, false, false),
                supports_color(Some("0"), false, None, true, false),
                supports_color(None, false, Some("dumb"), true, false),
                supports_color(None, false, None, true, false),
                supports_color(None, false, None, false, true),
                supports_color(None, true, None, false, true),
            ],
            [false, true, false, false, true, true, false]
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
