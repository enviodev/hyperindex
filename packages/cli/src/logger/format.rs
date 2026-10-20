use super::level::Level;
use chrono::{DateTime, Local, SecondsFormat};
use serde_json::{value::RawValue, Map, Value};
use std::io::Write;

/// One logged line, before it is rendered for a sink.
pub struct Record<'a> {
    pub level: Level,
    pub millis: i64,
    pub msg: &'a str,
    /// Bound fields then the call's own params, already merged.
    pub fields: &'a [(&'a str, &'a RawValue)],
}

fn push_str(out: &mut Vec<u8>, value: &str) {
    // Serializing a string into a Vec can't fail.
    let _ = serde_json::to_writer(&mut *out, value);
}

/// A value serde wrote but won't read back, such as one nested past its depth
/// limit, is shown as its text.
fn parse(raw: &RawValue) -> Value {
    serde_json::from_str(raw.get()).unwrap_or_else(|_| Value::String(raw.get().to_owned()))
}

/// The fields a format writes, minus any named like a key the format writes
/// itself: the line's own level, time and message win over a param's.
fn fields_not_written_by_format<'a>(
    record: &'a Record,
    reserved: &'a [&str],
) -> impl Iterator<Item = &'a (&'a str, &'a RawValue)> {
    record
        .fields
        .iter()
        .filter(move |(key, _)| !reserved.contains(key))
}

const JSON_KEYS: [&str; 3] = ["level", "time", "msg"];
const ECS_KEYS: [&str; 4] = ["log.level", "@timestamp", "ecs.version", "message"];
const CAPTURED_KEYS: [&str; 2] = ["level", "msg"];

/// What pino writes: the line a log shipper or `jq` reads.
pub fn write_json_line(record: &Record, out: &mut Vec<u8>) {
    let _ = write!(
        out,
        "{{\"level\":{},\"time\":{}",
        record.level.value(),
        record.millis
    );
    for (key, value) in fields_not_written_by_format(record, &JSON_KEYS) {
        out.push(b',');
        push_str(out, key);
        out.push(b':');
        out.extend_from_slice(value.get().as_bytes());
    }
    out.extend_from_slice(b",\"msg\":");
    push_str(out, record.msg);
    out.extend_from_slice(b"}\n");
}

/// Elastic Common Schema, as `@elastic/ecs-pino-format` wrote it.
pub fn write_ecs_line(record: &Record, out: &mut Vec<u8>) {
    let timestamp = DateTime::from_timestamp_millis(record.millis)
        .unwrap_or_default()
        .to_rfc3339_opts(SecondsFormat::Millis, true);
    let _ = write!(
        out,
        "{{\"log.level\":\"{}\",\"@timestamp\":\"{timestamp}\",\"ecs.version\":\"1.6.0\"",
        record.level.name()
    );
    for (key, value) in fields_not_written_by_format(record, &ECS_KEYS) {
        out.push(b',');
        match (*key == "err")
            .then(|| error_fields(&parse(value)))
            .flatten()
        {
            Some(error) => {
                out.extend_from_slice(b"\"error\":");
                let _ = serde_json::to_writer(&mut *out, &error);
            }
            None => {
                push_str(out, key);
                out.push(b':');
                out.extend_from_slice(value.get().as_bytes());
            }
        }
    }
    out.extend_from_slice(b",\"message\":");
    push_str(out, record.msg);
    out.extend_from_slice(b"}\n");
}

/// An error as ECS names its parts, for an `err` that is a serialized error
/// rather than some other value thrown.
fn error_fields(value: &Value) -> Option<Value> {
    let error = value.as_object()?;
    let stack = error.get("stack")?;
    let mut fields = Map::new();
    if let Some(kind) = error.get("type") {
        fields.insert("type".into(), kind.clone());
    }
    if let Some(message) = error.get("message") {
        fields.insert("message".into(), message.clone());
    }
    fields.insert("stack_trace".into(), stack.clone());
    Some(Value::Object(fields))
}

/// What a test reads back: the level by name and no timestamp, so a whole
/// line can be compared at once.
pub fn to_captured_line(record: &Record) -> Value {
    let mut line = Map::with_capacity(record.fields.len() + 2);
    line.insert("level".into(), record.level.name().into());
    line.insert("msg".into(), record.msg.into());
    for (key, value) in fields_not_written_by_format(record, &CAPTURED_KEYS) {
        line.insert(key.to_string(), parse(value));
    }
    Value::Object(line)
}

const RESET_FG: &str = "\x1b[39m";
const RESET_BG: &str = "\x1b[49m";
const CYAN: &str = "\x1b[36m";
const MAGENTA: &str = "\x1b[35m";

fn level_color(level: Level) -> (&'static str, &'static str) {
    let color = match level {
        Level::FATAL | Level::UERROR => "\x1b[41m",
        Level::ERROR => "\x1b[31m",
        Level::WARN => "\x1b[33m",
        Level::INFO => "\x1b[32m",
        Level::UDEBUG => "\x1b[44m",
        Level::UINFO => "\x1b[42m",
        Level::UWARN => "\x1b[43m",
        Level::DEBUG => "\x1b[34m",
        _ => "\x1b[90m",
    };
    let reset = if color.starts_with("\x1b[4") {
        RESET_BG
    } else {
        RESET_FG
    };
    (color, reset)
}

/// For a person at a terminal, laid out the way `pino-pretty` laid it out.
/// Ends with a blank line, as `pino-pretty` through `console.log` printed it,
/// which keeps multi-line params apart.
pub fn write_pretty_line(record: &Record, colorize: bool, out: &mut Vec<u8>) {
    let paint = |color: &str, reset: &str, text: &str| {
        if colorize {
            format!("{color}{text}{reset}")
        } else {
            text.to_string()
        }
    };
    let (color, reset) = level_color(record.level);
    let time = DateTime::from_timestamp_millis(record.millis)
        .unwrap_or_default()
        .with_timezone(&Local)
        .format("%H:%M:%S%.3f");
    let _ = write!(
        out,
        "[{time}] {}:",
        paint(color, reset, &record.level.name().to_uppercase())
    );
    if !record.msg.is_empty() {
        out.push(b' ');
        out.extend_from_slice(paint(CYAN, RESET_FG, record.msg).as_bytes());
    }
    out.push(b'\n');
    for (key, value) in record.fields {
        let is_error = *key == "err" || *key == "error";
        let label = if is_error {
            key.to_string()
        } else {
            paint(MAGENTA, RESET_FG, key)
        };
        let value = parse(value);
        let rendered = if is_error {
            pretty_error(&value)
        } else {
            pretty_json(&value)
        };
        let _ = writeln!(out, "    {label}: {}", rendered.replace('\n', "\n    "));
    }
    out.push(b'\n');
}

fn pretty_json(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
}

/// A stack trace reads as the lines it is, not as one escaped string.
fn pretty_error(value: &Value) -> String {
    let Some((stack, rest)) = value.as_object().and_then(|error| {
        let stack = error.get("stack")?.as_str()?;
        let mut rest = error.clone();
        rest.remove("stack");
        Some((stack, rest))
    }) else {
        return pretty_json(value);
    };
    let mut out = pretty_json(&Value::Object(rest));
    // Reopens the object to append the stack as its last entry.
    out.truncate(out.trim_end_matches('}').trim_end().len());
    if out.ends_with('{') {
        out.push('\n');
    } else {
        out.push_str(",\n");
    }
    out.push_str("  \"stack\":\n");
    for line in stack.lines() {
        out.push_str("      ");
        out.push_str(line);
        out.push('\n');
    }
    out.push('}');
    out
}

#[cfg(test)]
mod tests {
    use super::super::fields::{merge_later_wins, parse_object_fields, Fields};
    use super::*;

    const AT_EPOCH: i64 = 1_700_000_000_123;

    fn render(
        level: Level,
        msg: &str,
        fields: &Fields,
        format: fn(&Record, &mut Vec<u8>),
    ) -> String {
        let merged = merge_later_wins(&[fields]);
        let mut out = Vec::new();
        format(
            &Record {
                level,
                millis: AT_EPOCH,
                msg,
                fields: &merged,
            },
            &mut out,
        );
        String::from_utf8(out).unwrap()
    }

    fn fields(json: &str) -> Fields {
        parse_object_fields(json).unwrap()
    }

    #[test]
    fn json_line_puts_level_and_time_first_and_msg_last() {
        assert_eq!(
            render(Level::INFO, "hello \"you\"", &fields(r#"{"chainId":1,"block":5}"#), write_json_line),
            "{\"level\":30,\"time\":1700000000123,\"chainId\":1,\"block\":5,\"msg\":\"hello \\\"you\\\"\"}\n"
        );
    }

    #[test]
    fn ecs_line_names_an_error_the_ecs_way() {
        assert_eq!(
            render(
                Level::ERROR,
                "failed",
                &fields(r#"{"chainId":1,"err":{"type":"Error","message":"boom","stack":"Error: boom\n    at x"}}"#),
                write_ecs_line
            ),
            "{\"log.level\":\"error\",\"@timestamp\":\"2023-11-14T22:13:20.123Z\",\"ecs.version\":\"1.6.0\",\"chainId\":1,\"error\":{\"type\":\"Error\",\"message\":\"boom\",\"stack_trace\":\"Error: boom\\n    at x\"},\"message\":\"failed\"}\n"
        );
    }

    #[test]
    fn a_field_named_like_a_lines_own_key_gives_way_to_it() {
        let params = fields(r#"{"level":"x","time":"x","msg":"x","message":"x","n":1}"#);
        let merged = merge_later_wins(&[&params]);
        let record = Record {
            level: Level::INFO,
            millis: AT_EPOCH,
            msg: "hi",
            fields: &merged,
        };
        assert_eq!(
            (
                render(Level::INFO, "hi", &params, write_json_line),
                render(Level::INFO, "hi", &params, write_ecs_line),
                to_captured_line(&record)
            ),
            (
                "{\"level\":30,\"time\":1700000000123,\"message\":\"x\",\"n\":1,\"msg\":\"hi\"}\n"
                    .to_string(),
                "{\"log.level\":\"info\",\"@timestamp\":\"2023-11-14T22:13:20.123Z\",\"ecs.version\":\"1.6.0\",\"level\":\"x\",\"time\":\"x\",\"msg\":\"x\",\"n\":1,\"message\":\"hi\"}\n"
                    .to_string(),
                serde_json::json!({"level": "info", "msg": "hi", "time": "x", "message": "x", "n": 1})
            )
        );
    }

    #[test]
    fn ecs_line_keeps_a_thrown_value_that_isnt_an_error() {
        assert_eq!(
            render(Level::ERROR, "failed", &fields(r#"{"err":{"RE_EXN_ID":"Foo"}}"#), write_ecs_line),
            "{\"log.level\":\"error\",\"@timestamp\":\"2023-11-14T22:13:20.123Z\",\"ecs.version\":\"1.6.0\",\"err\":{\"RE_EXN_ID\":\"Foo\"},\"message\":\"failed\"}\n"
        );
    }

    #[test]
    fn captured_line_has_no_timestamp() {
        let fields = fields(r#"{"chainId":1}"#);
        let merged = merge_later_wins(&[&fields]);
        assert_eq!(
            to_captured_line(&Record {
                level: Level::UWARN,
                millis: AT_EPOCH,
                msg: "careful",
                fields: &merged,
            }),
            serde_json::json!({"level": "uwarn", "msg": "careful", "chainId": 1})
        );
    }

    #[test]
    fn pretty_lays_out_params_and_errors_below_the_message() {
        let rendered = render(
            Level::WARN,
            "careful",
            &fields(
                r#"{"data":{"blockHash":"0x1"},"err":{"type":"Error","message":"boom","stack":"Error: boom\n    at x"}}"#,
            ),
            |record, out| write_pretty_line(record, false, out),
        );
        let (_, after_time) = rendered.split_once("] ").unwrap();
        assert_eq!(
            after_time,
            "WARN: careful
    data: {
      \"blockHash\": \"0x1\"
    }
    err: {
      \"type\": \"Error\",
      \"message\": \"boom\",
      \"stack\":
          Error: boom
              at x
    }

"
        );
    }

    #[test]
    fn pretty_colors_level_message_and_keys() {
        let rendered = render(
            Level::UINFO,
            "hi",
            &fields(r#"{"chainId":1}"#),
            |record, out| write_pretty_line(record, true, out),
        );
        let (_, after_time) = rendered.split_once("] ").unwrap();
        assert_eq!(
            after_time,
            "\x1b[42mUINFO\x1b[49m: \x1b[36mhi\x1b[39m\n    \x1b[35mchainId\x1b[39m: 1\n\n"
        );
    }
}
