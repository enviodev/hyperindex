use super::level::Level;
use chrono::{DateTime, Local, SecondsFormat, Utc};
use serde_json::{Map, Value};

/// One logged line, before it is rendered for a sink.
pub struct Record<'a> {
    pub level: Level,
    pub time: DateTime<Utc>,
    pub msg: &'a str,
    /// The logger's bindings followed by the call's own params; a param
    /// replaces a binding of the same name.
    pub fields: &'a Map<String, Value>,
}

/// What pino writes: the line a log shipper or `jq` reads.
pub fn json(record: &Record) -> String {
    let mut line = Map::with_capacity(record.fields.len() + 3);
    line.insert("level".into(), record.level.value().into());
    line.insert("time".into(), record.time.timestamp_millis().into());
    extend(&mut line, record.fields);
    line.insert("msg".into(), record.msg.into());
    Value::Object(line).to_string()
}

/// Elastic Common Schema, as `@elastic/ecs-pino-format` wrote it.
pub fn ecs(record: &Record) -> String {
    let mut line = Map::with_capacity(record.fields.len() + 4);
    line.insert("log.level".into(), record.level.name().into());
    line.insert(
        "@timestamp".into(),
        record
            .time
            .to_rfc3339_opts(SecondsFormat::Millis, true)
            .into(),
    );
    line.insert("ecs.version".into(), "1.6.0".into());
    for (key, value) in record.fields {
        match error_fields(key, value) {
            Some(error) => line.insert("error".into(), error),
            None => line.insert(key.clone(), value.clone()),
        };
    }
    line.insert("message".into(), record.msg.into());
    Value::Object(line).to_string()
}

/// An error as ECS names its parts, for an `err` field that is a serialized
/// error rather than some other value thrown.
fn error_fields(key: &str, value: &Value) -> Option<Value> {
    let error = value.as_object().filter(|_| key == "err")?;
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
pub fn captured(record: &Record) -> Value {
    let mut line = Map::with_capacity(record.fields.len() + 2);
    line.insert("level".into(), record.level.name().into());
    line.insert("msg".into(), record.msg.into());
    extend(&mut line, record.fields);
    Value::Object(line)
}

fn extend(line: &mut Map<String, Value>, fields: &Map<String, Value>) {
    for (key, value) in fields {
        line.insert(key.clone(), value.clone());
    }
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
pub fn pretty(record: &Record, colorize: bool) -> String {
    let paint = |color: &str, reset: &str, text: &str| {
        if colorize {
            format!("{color}{text}{reset}")
        } else {
            text.to_string()
        }
    };
    let (color, reset) = level_color(record.level);
    let time = record
        .time
        .with_timezone(&Local)
        .format("%H:%M:%S%.3f")
        .to_string();
    let mut out = format!(
        "[{time}] {}:",
        paint(color, reset, &record.level.name().to_uppercase())
    );
    if !record.msg.is_empty() {
        out.push(' ');
        out.push_str(&paint(CYAN, RESET_FG, record.msg));
    }
    out.push('\n');
    for (key, value) in record.fields {
        let is_error = key == "err" || key == "error";
        out.push_str("    ");
        out.push_str(&if is_error {
            key.clone()
        } else {
            paint(MAGENTA, RESET_FG, key)
        });
        out.push_str(": ");
        let rendered = if is_error {
            pretty_error(value)
        } else {
            pretty_json(value)
        };
        out.push_str(&indent_continuation(&rendered, "    "));
        out.push('\n');
    }
    out
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

fn indent_continuation(text: &str, indent: &str) -> String {
    text.replace('\n', &format!("\n{indent}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fields(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    fn at_epoch() -> DateTime<Utc> {
        DateTime::from_timestamp_millis(1_700_000_000_123).unwrap()
    }

    #[test]
    fn json_line_puts_level_and_time_first_and_msg_last() {
        let fields = fields(json!({"chainId": 1, "block": 5}));
        let record = Record {
            level: Level::INFO,
            time: at_epoch(),
            msg: "hello",
            fields: &fields,
        };
        assert_eq!(
            json(&record),
            r#"{"level":30,"time":1700000000123,"chainId":1,"block":5,"msg":"hello"}"#
        );
    }

    #[test]
    fn ecs_line_names_an_error_the_ecs_way() {
        let fields = fields(json!({
            "chainId": 1,
            "err": {"type": "Error", "message": "boom", "stack": "Error: boom\n    at x"}
        }));
        let record = Record {
            level: Level::ERROR,
            time: at_epoch(),
            msg: "failed",
            fields: &fields,
        };
        assert_eq!(
            ecs(&record),
            r#"{"log.level":"error","@timestamp":"2023-11-14T22:13:20.123Z","ecs.version":"1.6.0","chainId":1,"error":{"type":"Error","message":"boom","stack_trace":"Error: boom\n    at x"},"message":"failed"}"#
        );
    }

    #[test]
    fn ecs_line_keeps_a_thrown_value_that_isnt_an_error() {
        let fields = fields(json!({"err": {"RE_EXN_ID": "Foo"}}));
        let record = Record {
            level: Level::ERROR,
            time: at_epoch(),
            msg: "failed",
            fields: &fields,
        };
        assert_eq!(
            ecs(&record),
            r#"{"log.level":"error","@timestamp":"2023-11-14T22:13:20.123Z","ecs.version":"1.6.0","err":{"RE_EXN_ID":"Foo"},"message":"failed"}"#
        );
    }

    #[test]
    fn captured_line_has_no_timestamp() {
        let fields = fields(json!({"chainId": 1}));
        let record = Record {
            level: Level::UWARN,
            time: at_epoch(),
            msg: "careful",
            fields: &fields,
        };
        assert_eq!(
            captured(&record),
            json!({"level": "uwarn", "msg": "careful", "chainId": 1})
        );
    }

    #[test]
    fn pretty_lays_out_params_and_errors_below_the_message() {
        let fields = fields(json!({
            "data": {"blockHash": "0x1"},
            "err": {"type": "Error", "message": "boom", "stack": "Error: boom\n    at x"}
        }));
        let record = Record {
            level: Level::WARN,
            time: at_epoch(),
            msg: "careful",
            fields: &fields,
        };
        let rendered = pretty(&record, false);
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
        let fields = fields(json!({"chainId": 1}));
        let record = Record {
            level: Level::UINFO,
            time: at_epoch(),
            msg: "hi",
            fields: &fields,
        };
        let rendered = pretty(&record, true);
        let (_, after_time) = rendered.split_once("] ").unwrap();
        assert_eq!(
            after_time,
            "\x1b[42mUINFO\x1b[49m: \x1b[36mhi\x1b[39m\n    \x1b[35mchainId\x1b[39m: 1\n"
        );
    }
}
