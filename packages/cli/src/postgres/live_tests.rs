//! Checks the decoding against a real server.
//!
//! Every case asks Postgres for a value twice: once in the binary this decodes,
//! and once as the text it renders itself. The text is the answer the driver
//! being replaced would have handed to JavaScript, so anywhere the two disagree
//! is a value that would change under the migration.
//!
//! Ignored by default — CI's `cargo test` job has no database. Run against a
//! local one with `cargo test --lib postgres::live -- --ignored`.

use super::client::{PgClient, PgConnectionOptions, SslSetting};
use super::param::Param;
use super::rows::Cell;

fn client() -> PgClient {
    PgClient::connect(PgConnectionOptions {
        host: std::env::var("ENVIO_PG_HOST").unwrap_or_else(|_| "localhost".to_string()),
        port: std::env::var("ENVIO_PG_PORT")
            .ok()
            .and_then(|port| port.parse().ok())
            .unwrap_or(5433),
        user: std::env::var("ENVIO_PG_USER").unwrap_or_else(|_| "postgres".to_string()),
        password: std::env::var("ENVIO_PG_PASSWORD").unwrap_or_else(|_| "testing".to_string()),
        database: std::env::var("ENVIO_PG_DATABASE").unwrap_or_else(|_| "envio-dev".to_string()),
        ssl: SslSetting::Disable,
        max_connections: 2,
        application_name: Some("envio-live-test".to_string()),
    })
    .expect("the pool is built from a static configuration")
}

/// Asks for `expression` as a value and as its own text, and returns both.
async fn both(client: &PgClient, expression: &str) -> (Cell, Option<String>) {
    let sql = format!("SELECT ({expression}) AS value, ({expression})::text AS rendered");
    let (rows, _) = client
        .query(&sql, &[])
        .await
        .unwrap_or_else(|error| panic!("`{sql}` failed: {error:#}"));
    let row = rows.first().expect("one row");
    let rendered = match row.get::<_, Cell>(1) {
        Cell::Str(rendered) => Some(rendered),
        _ => None,
    };
    (row.get(0), rendered)
}

/// Everything Postgres renders as text should come back from binary spelled the
/// same way. `numeric` is the one this is really here for: it is the only type
/// whose value carries a scale, and the only one a float round trip would
/// quietly round.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn text_and_binary_agree_on_every_numeric() {
    let client = client();
    let expressions = [
        "0::numeric",
        "1.25::numeric",
        "1.50::numeric(10,2)",
        "0.00::numeric(10,2)",
        "(-1.25)::numeric",
        "0.5::numeric",
        "0.0001::numeric",
        "12345.6789::numeric",
        "10000::numeric",
        "99999999999999999999999999999999999999::numeric",
        "(-99999999999999999999999999999999999999)::numeric",
        "0.000000000000000000000001::numeric",
        "12.00010000::numeric(20,8)",
        "'NaN'::numeric",
    ];
    for expression in expressions {
        let (value, rendered) = both(&client, expression).await;
        assert_eq!(
            value,
            Cell::Str(rendered.clone().unwrap()),
            "`{expression}` decoded to {value:?} but Postgres renders it as {rendered:?}"
        );
    }
}

#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn the_integer_types_keep_their_javascript_shape() {
    let client = client();
    let cases = [
        ("0::int2", Cell::Num(0.0)),
        ("(-7)::int2", Cell::Num(-7.0)),
        ("2147483647::int4", Cell::Num(2147483647.0)),
        ("(-2147483648)::int4", Cell::Num(-2147483648.0)),
        // Past what a double holds exactly, which is why it is text.
        (
            "9007199254740993::int8",
            Cell::Str("9007199254740993".to_string()),
        ),
        (
            "(-9223372036854775808)::int8",
            Cell::Str("-9223372036854775808".to_string()),
        ),
        ("true", Cell::Bool(true)),
        ("false", Cell::Bool(false)),
        ("1.5::float8", Cell::Num(1.5)),
        ("(-0.25)::float4", Cell::Num(-0.25)),
    ];
    for (expression, expected) in cases {
        let (value, _) = both(&client, expression).await;
        assert_eq!(value, expected, "`{expression}`");
    }
}

#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn text_bytea_and_json_come_back_as_themselves() {
    let client = client();
    let cases = [
        ("'hello'::text", Cell::Str("hello".to_string())),
        ("''::text", Cell::Str(String::new())),
        (
            "'h\u{e9}llo \u{1f600}'::text",
            Cell::Str("h\u{e9}llo \u{1f600}".to_string()),
        ),
        (
            "'\\xdeadbeef'::bytea",
            Cell::Bytes(vec![0xde, 0xad, 0xbe, 0xef]),
        ),
        ("'\\x'::bytea", Cell::Bytes(vec![])),
        (r#"'{"a": 1}'::jsonb"#, Cell::Str(r#"{"a": 1}"#.to_string())),
        ("'null'::jsonb", Cell::Str("null".to_string())),
    ];
    for (expression, expected) in cases {
        let (value, _) = both(&client, expression).await;
        assert_eq!(value, expected, "`{expression}`");
    }
}

/// Postgres counts from 2000 and JavaScript from 1970, so an epoch that is not
/// shifted lands thirty years out — far enough to be obvious in a test and
/// quiet enough to miss in a column.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn timestamps_land_on_the_javascript_epoch() {
    let client = client();
    let cases = [
        ("'1970-01-01T00:00:00Z'::timestamptz", 0.0),
        ("'2000-01-01T00:00:00Z'::timestamptz", 946_684_800_000.0),
        (
            "'2009-02-13T23:31:30.123Z'::timestamptz",
            1_234_567_890_123.0,
        ),
        ("'1969-12-31T23:59:59Z'::timestamptz", -1000.0),
        ("'1970-01-01'::date", 0.0),
        ("'2009-02-13'::date", 1_234_483_200_000.0),
    ];
    for (expression, millis) in cases {
        let (value, rendered) = both(&client, expression).await;
        assert_eq!(
            value,
            Cell::Timestamp(millis),
            "`{expression}` ({rendered:?})"
        );
    }
}

#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_null_column_is_null_whatever_its_type() {
    let client = client();
    for expression in [
        "NULL::text",
        "NULL::int8",
        "NULL::numeric",
        "NULL::bytea",
        "NULL::timestamptz",
        "NULL::jsonb",
    ] {
        let (value, _) = both(&client, expression).await;
        assert_eq!(value, Cell::Null, "`{expression}`");
    }
}

/// Parameters go out as text and have to come back as the same value, which is
/// what says the text encoding and the server's own parsing agree.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_text_parameter_round_trips() {
    let client = client();
    let cases = [
        (
            "$1::text",
            Param::text("plain"),
            Cell::Str("plain".to_string()),
        ),
        (
            "$1::text",
            Param::text("with 'quotes' and \\ backslash"),
            Cell::Str("with 'quotes' and \\ backslash".to_string()),
        ),
        (
            "$1::numeric",
            Param::text("1.50"),
            Cell::Str("1.50".to_string()),
        ),
        (
            "$1::int8",
            Param::text("9007199254740993"),
            Cell::Str("9007199254740993".to_string()),
        ),
        (
            "$1::bytea",
            Param::text("\\xdeadbeef"),
            Cell::Bytes(vec![0xde, 0xad, 0xbe, 0xef]),
        ),
        ("$1::text", Param::Null, Cell::Null),
    ];
    for (expression, param, expected) in cases {
        let sql = format!("SELECT {expression} AS value");
        let (rows, _) = client
            .query(&sql, std::slice::from_ref(&param))
            .await
            .unwrap_or_else(|error| panic!("`{sql}` with {param:?} failed: {error:#}"));
        assert_eq!(
            rows[0].get::<_, Cell>(0),
            expected,
            "`{sql}` with {param:?}"
        );
    }
}

/// An array parameter is one text literal, and the elements have to survive the
/// characters that literal reads — a comma, a brace, a quote, a backslash.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn an_array_parameter_survives_its_own_punctuation() {
    let client = client();
    let elements = [
        "a,b",
        "{nested}",
        "has \"quotes\"",
        "back\\slash",
        "",
        "NULL",
    ];
    let literal = super::param::array_literal(elements.map(Some));
    let (rows, _) = client
        .query(
            "SELECT unnest($1::text[]) AS value",
            &[Param::Text(literal.clone())],
        )
        .await
        .unwrap_or_else(|error| panic!("`{literal}` failed: {error:#}"));
    let read = rows
        .iter()
        .map(|row| row.get::<_, Option<String>>(0))
        .collect::<Vec<_>>();
    assert_eq!(
        read,
        elements.map(|e| Some(e.to_string())).to_vec(),
        "from {literal}"
    );
}

/// The one an array literal cannot quote: quoted, it would be the four-letter
/// word rather than the absence of a value.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn an_array_keeps_null_apart_from_the_word() {
    let client = client();
    let literal = super::param::array_literal([None, Some("NULL")]);
    let (rows, _) = client
        .query(
            "SELECT unnest($1::text[]) AS value",
            &[Param::Text(literal)],
        )
        .await
        .unwrap();
    assert_eq!(
        rows.iter()
            .map(|row| row.get::<_, Option<String>>(0))
            .collect::<Vec<_>>(),
        vec![None, Some("NULL".to_string())]
    );
}
