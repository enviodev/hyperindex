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
use super::rows::ReadKind;
use futures_util::future;

use crate::columnar::{Arena, ColumnKind, ColumnSpec};

fn client() -> PgClient {
    client_with(SslSetting::Disable, &default_host())
}

fn default_host() -> String {
    std::env::var("ENVIO_PG_HOST").unwrap_or_else(|_| "localhost".to_string())
}

fn client_with(ssl: SslSetting, host: &str) -> PgClient {
    PgClient::connect(PgConnectionOptions {
        host: host.to_string(),
        port: std::env::var("ENVIO_PG_PORT")
            .ok()
            .and_then(|port| port.parse().ok())
            .unwrap_or(5433),
        user: std::env::var("ENVIO_PG_USER").unwrap_or_else(|_| "postgres".to_string()),
        password: std::env::var("ENVIO_PG_PASSWORD").unwrap_or_else(|_| "testing".to_string()),
        database: std::env::var("ENVIO_PG_DATABASE").unwrap_or_else(|_| "envio-dev".to_string()),
        ssl,
        max_connections: 2,
        application_name: Some("envio-live-test".to_string()),
    })
    .expect("the pool is built from a static configuration")
}

/// Asks for `expression` as a value and as its own text, and returns both.
async fn both(client: &PgClient, expression: &str) -> (Cell<'static>, Option<String>) {
    let sql = format!("SELECT ({expression}) AS value, ({expression})::text AS rendered");
    let (rows, _) = client
        .query(&sql, &[])
        .await
        .unwrap_or_else(|error| panic!("`{sql}` failed: {error:#}"));
    let row = rows.first().expect("one row");
    let rendered = match row.get::<_, Cell>(1) {
        Cell::Str(rendered) => Some(rendered.into_owned()),
        _ => None,
    };
    (row.get::<_, Cell>(0).into_owned(), rendered)
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
            Cell::Str(rendered.clone().unwrap().into()),
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
            Cell::Str("9007199254740993".into()),
        ),
        (
            "(-9223372036854775808)::int8",
            Cell::Str("-9223372036854775808".into()),
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
        ("'hello'::text", Cell::Str("hello".into())),
        ("''::text", Cell::Str("".into())),
        (
            "'h\u{e9}llo \u{1f600}'::text",
            Cell::Str("h\u{e9}llo \u{1f600}".into()),
        ),
        (
            "'\\xdeadbeef'::bytea",
            Cell::Bytes(vec![0xde, 0xad, 0xbe, 0xef].into()),
        ),
        ("'\\x'::bytea", Cell::Bytes(vec![].into())),
        (r#"'{"a": 1}'::jsonb"#, Cell::Str(r#"{"a": 1}"#.into())),
        ("'null'::jsonb", Cell::Str("null".into())),
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
            Param::Text("plain".to_string()),
            Cell::Str("plain".into()),
        ),
        (
            "$1::text",
            Param::Text("with 'quotes' and \\ backslash".to_string()),
            Cell::Str("with 'quotes' and \\ backslash".into()),
        ),
        (
            "$1::numeric",
            Param::Text("1.50".to_string()),
            Cell::Str("1.50".into()),
        ),
        (
            "$1::int8",
            Param::Text("9007199254740993".to_string()),
            Cell::Str("9007199254740993".into()),
        ),
        (
            "$1::bytea",
            Param::Text("\\xdeadbeef".to_string()),
            Cell::Bytes(vec![0xde, 0xad, 0xbe, 0xef].into()),
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
    let literal = text_literal(&elements.map(Some));
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

/// A column of text as the literal the write path renders for it, so what goes
/// to the server here is what an insert would send.
fn text_literal(values: &[Option<&str>]) -> String {
    let mut arena = Arena::new_filled(values.len(), &[ColumnSpec::Scalar(ColumnKind::Text)]);
    for (row, value) in values.iter().enumerate() {
        match value {
            Some(value) => arena.set_bytes(0, row, value.as_bytes()),
            None => arena.mark_null(0, row),
        }
    }
    arena.seal(&["value".to_string()]).unwrap();
    match super::write::unnest_params(&arena).unwrap().remove(0) {
        Param::Text(literal) => literal,
        Param::Null => unreachable!("a column renders as a literal"),
    }
}

/// The one an array literal cannot quote: quoted, it would be the four-letter
/// word rather than the absence of a value.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn an_array_keeps_null_apart_from_the_word() {
    let client = client();
    let literal = text_literal(&[None, Some("NULL")]);
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

/// Array columns go into a list slot: the elements laid out as a column of
/// their own, and a row boundary saying which of them belong to which row.
/// `[Bytes!]!` is why they cannot travel as text the way a JSON document does.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn array_columns_lay_out_as_lists() {
    let client = client();
    let (rows, columns) = client
        .query(
            "SELECT * FROM (VALUES \
               (ARRAY['a','bb']::text[], ARRAY[1,2,3]::int4[], ARRAY['\\xde'::bytea]), \
               (ARRAY[]::text[],         ARRAY[]::int4[],      ARRAY[]::bytea[]), \
               (ARRAY['c']::text[],      NULL::int4[],         ARRAY[NULL]::bytea[]) \
             ) AS t(texts, ints, blobs)",
            &[],
        )
        .await
        .expect("the query runs");
    let types = columns
        .iter()
        .map(|column| column.ty.clone())
        .collect::<Vec<_>>();

    let arena = super::rows::into_arena(&rows, &types).expect("the rows lay out");

    assert_eq!(
        (
            arena.rows(),
            types
                .iter()
                .map(super::rows::column_read_kind)
                .collect::<Vec<_>>(),
            // the null array in the third row, and nothing else
            (0..3)
                .map(|row| arena.columns()[1].is_null(row))
                .collect::<Vec<_>>(),
        ),
        (
            3,
            vec![ReadKind::List, ReadKind::List, ReadKind::List],
            vec![false, false, true],
        )
    );
}

/// Every column type the schema can declare, in one result, laid out without
/// complaint. The point is coverage of `into_arena`'s dispatch rather than of
/// any one value.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn every_column_type_lays_out() {
    let client = client();
    let (rows, columns) = client
        .query(
            "SELECT 'x'::text, 1::int4, 1::int8, 1.5::float8, 1.25::numeric, true, \
             '\\xde'::bytea, now()::timestamptz, '{\"a\":1}'::jsonb, \
             ARRAY['a']::text[], ARRAY[1]::int4[], ARRAY[1.25]::numeric[]",
            &[],
        )
        .await
        .expect("the query runs");
    let types = columns
        .iter()
        .map(|column| column.ty.clone())
        .collect::<Vec<_>>();
    let arena = super::rows::into_arena(&rows, &types).expect("the rows lay out");
    assert_eq!(arena.rows(), 1);
}

/// A query matching nothing still has to describe its columns, or the other
/// side has nothing to build views over.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn an_empty_result_still_describes_its_columns() {
    let client = client();
    let (rows, columns) = client
        .query(
            "SELECT 'x'::text AS a, ARRAY[1]::int4[] AS b WHERE false",
            &[],
        )
        .await
        .expect("the query runs");
    let types = columns
        .iter()
        .map(|column| column.ty.clone())
        .collect::<Vec<_>>();
    let arena = super::rows::into_arena(&rows, &types).expect("the rows lay out");
    assert_eq!((arena.rows(), arena.columns().len()), (0, 2));
}

/// A transaction holds one connection, so a temporary table made inside it is
/// visible to every statement in it and gone with it.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_transaction_commits_what_it_did() {
    let client = client();
    let transaction = client.begin().await.expect("the transaction opens");
    transaction
        .batch("CREATE TEMPORARY TABLE committed_rows (n int4) ON COMMIT DROP")
        .await
        .expect("the table is made");
    transaction
        .execute("INSERT INTO committed_rows VALUES (1), (2)", &[])
        .await
        .expect("the rows go in");
    let (rows, _) = transaction
        .query("SELECT n FROM committed_rows ORDER BY n", &[])
        .await
        .expect("the rows come back");
    transaction.commit().await.expect("the transaction commits");

    assert_eq!(
        rows.iter()
            .map(|row| row.get::<_, Cell>(0))
            .collect::<Vec<_>>(),
        vec![Cell::Num(1.0), Cell::Num(2.0)]
    );
}

#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_rollback_undoes_what_it_did() {
    let client = client();
    let transaction = client.begin().await.expect("the transaction opens");
    transaction
        .batch("CREATE TEMPORARY TABLE rolled_back_rows (n int4)")
        .await
        .expect("the table is made");
    transaction
        .execute("INSERT INTO rolled_back_rows VALUES (1)", &[])
        .await
        .expect("the row goes in");
    transaction
        .rollback()
        .await
        .expect("the transaction rolls back");

    // The table went with the transaction that made it, which is the rollback
    // reaching the DDL as well as the rows.
    let (rows, _) = client
        .query(
            "SELECT to_regclass('pg_temp.rolled_back_rows') IS NULL AS gone",
            &[],
        )
        .await
        .expect("the check runs");
    assert_eq!(rows[0].get::<_, Cell>(0), Cell::Bool(true));
}

/// A batch write issues its statements at once rather than one after another,
/// which is what the driver being replaced did on its transaction's connection.
/// They have to all land, and land in a transaction that is still whole.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn statements_issued_together_all_land() {
    let client = client();
    let transaction = client.begin().await.expect("the transaction opens");
    transaction
        .batch("CREATE TEMPORARY TABLE together_rows (n int4) ON COMMIT DROP")
        .await
        .expect("the table is made");

    let writes = (0..16).map(|n| {
        let transaction = transaction.clone();
        async move {
            transaction
                .execute(
                    "INSERT INTO together_rows VALUES ($1::int4)",
                    &[Param::Text(n.to_string())],
                )
                .await
        }
    });
    future::try_join_all(writes)
        .await
        .expect("every statement lands");

    let (rows, _) = transaction
        .query("SELECT count(*)::int4 FROM together_rows", &[])
        .await
        .expect("the count comes back");
    transaction.commit().await.expect("the transaction commits");
    assert_eq!(rows[0].get::<_, Cell>(0), Cell::Num(16.0));
}

/// Once a statement has failed the server refuses the rest of the transaction,
/// and the only thing it will take is the rollback. Sending one has to work
/// rather than report the failure a second time.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_failed_statement_leaves_a_transaction_that_can_still_be_rolled_back() {
    let client = client();
    let transaction = client.begin().await.expect("the transaction opens");
    let failure = transaction
        .execute("SELECT 1 FROM nothing_is_here", &[])
        .await;
    assert!(failure.is_err(), "the statement names no table");
    transaction
        .rollback()
        .await
        .expect("the rollback is taken even so");
}

/// The write path end to end: rows laid into the arena, rendered into the
/// arrays an unnest insert binds, and read back as what went in. The rendering
/// is what replaces building these literals in JavaScript.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_staged_batch_unnests_into_its_table() {
    let client = client();
    let transaction = client.begin().await.expect("the transaction opens");
    transaction
        .batch(
            "CREATE TEMPORARY TABLE unnested (t text, n int4, b bytea, d numeric) ON COMMIT DROP",
        )
        .await
        .expect("the table is made");

    let mut arena = Arena::new_filled(
        3,
        &[
            ColumnSpec::Scalar(ColumnKind::Text),
            ColumnSpec::Scalar(ColumnKind::F64),
            ColumnSpec::Scalar(ColumnKind::Bytes),
            ColumnSpec::Scalar(ColumnKind::Text),
        ],
    );
    // A comma, a brace, a quote and a backslash are every character the array
    // literal itself reads, and an empty string is the one a bare NULL would be
    // confused with.
    for (row, text) in ["a,b", "{\"x\"}\\", ""].iter().enumerate() {
        arena.set_bytes(0, row, text.as_bytes());
        arena.set_f64(1, row, row as f64);
        arena.set_bytes(2, row, &[0xde, row as u8]);
        arena.set_bytes(3, row, b"1.50");
    }
    arena.mark_null(3, 2);
    arena
        .seal(&["t", "n", "b", "d"].map(str::to_string))
        .unwrap();

    let params = super::write::unnest_params(&arena).expect("the rows render");
    transaction
        .execute(
            "INSERT INTO unnested (t, n, b, d) SELECT * FROM unnest($1::text[], $2::int4[], \
             $3::bytea[], $4::numeric[])",
            &params,
        )
        .await
        .expect("the batch goes in");

    let (rows, _) = transaction
        .query("SELECT t, n, b, d FROM unnested ORDER BY n", &[])
        .await
        .expect("the rows come back");
    transaction.commit().await.expect("the transaction commits");

    let read = rows
        .iter()
        .map(|row| {
            (
                row.get::<_, Cell>(0),
                row.get::<_, Cell>(1),
                row.get::<_, Cell>(2),
                row.get::<_, Cell>(3),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        read,
        vec![
            (
                Cell::Str("a,b".into()),
                Cell::Num(0.0),
                Cell::Bytes(vec![0xde, 0].into()),
                Cell::Str("1.50".into()),
            ),
            (
                Cell::Str("{\"x\"}\\".into()),
                Cell::Num(1.0),
                Cell::Bytes(vec![0xde, 1].into()),
                Cell::Str("1.50".into()),
            ),
            (
                Cell::Str("".into()),
                Cell::Num(2.0),
                Cell::Bytes(vec![0xde, 2].into()),
                Cell::Null,
            ),
        ]
    );
}

/// A write failure is classified by the server's own message, so that is what
/// has to reach the other side. Wrapping it in the context of the call that made
/// it would read fine and match none of the cases the storage layer looks for.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_failure_reports_the_message_the_server_gave() {
    let client = client();
    let nul = client
        .execute("SELECT $1::text", &[Param::Text("a\0b".to_string())])
        .await
        .expect_err("a NUL is not something a text column takes");
    let missing = client
        .execute("SELECT 1 FROM nothing_is_here", &[])
        .await
        .expect_err("the table does not exist");

    assert_eq!(
        (
            super::error::message_of(&nul),
            super::error::message_of(&missing),
        ),
        (
            "invalid byte sequence for encoding \"UTF8\": 0x00".to_string(),
            "relation \"nothing_is_here\" does not exist".to_string(),
        )
    );
}

/// An insert, an update and a delete all come back describing no columns at
/// all. Laying that out must give an empty result rather than divide the cells
/// it has none of into rows of width zero.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn a_statement_that_returns_no_columns_is_an_empty_result() {
    let client = client();
    client
        .batch("CREATE TEMPORARY TABLE no_columns (n int4)")
        .await
        .unwrap();
    let (rows, columns) = client
        .query("INSERT INTO no_columns VALUES (1)", &[])
        .await
        .unwrap();
    assert_eq!((rows.len(), columns.len()), (0, 0));
    super::rows::into_arena(&rows, &[]).unwrap();
}

/// A prepared statement carries the plan the server made for it, and the plan
/// describes the columns it returns. Change the table under it and executing it
/// again is refused with "cached plan must not change result type" — which
/// would arrive inside whatever transaction the caller was in and abort it.
#[tokio::test]
#[ignore = "needs a Postgres server"]
async fn forgetting_what_was_prepared_survives_the_table_changing_shape() {
    let client = client();
    client
        .batch(
            "DROP TABLE IF EXISTS stale_plan; \
             CREATE TABLE stale_plan (n int4)",
        )
        .await
        .unwrap();
    client.query("SELECT * FROM stale_plan", &[]).await.unwrap();

    client
        .batch("ALTER TABLE stale_plan ADD COLUMN extra text")
        .await
        .unwrap();
    // Either the columns the statement describes, or why it would not run.
    async fn outcome(client: &PgClient) -> String {
        match client.query("SELECT * FROM stale_plan", &[]).await {
            Ok((_, columns)) => columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>()
                .join(","),
            Err(error) => super::error::message_of(&error),
        }
    }

    let kept = outcome(&client).await;
    client.forget_prepared();
    let forgotten = outcome(&client).await;
    client.batch("DROP TABLE stale_plan").await.unwrap();

    assert_eq!(
        (kept, forgotten),
        (
            "cached plan must not change result type".to_string(),
            "n,extra".to_string()
        )
    );
}

/// Whether the server says the connection it is answering on is encrypted, or
/// why there was no connection to ask.
async fn encrypted(ssl: SslSetting, host: &str) -> String {
    let client = client_with(ssl, host);
    match client
        .query(
            "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
            &[],
        )
        .await
    {
        Ok((rows, _)) => match rows.first().map(|row| row.get::<_, bool>(0)) {
            Some(true) => "encrypted".to_string(),
            Some(false) => "plaintext".to_string(),
            None => "no row".to_string(),
        },
        Err(error) => format!("refused: {}", super::error::message_of(&error)),
    }
}

/// Every mode against a server that offers TLS, including the one that has to
/// check the certificate.
///
/// A hosted database is reached over TLS and nothing short of a handshake says
/// whether the trust store the addon carries can be reached at all — the
/// OpenSSL it links is vendored, and its idea of where the CAs live is
/// compiled in. The certificate names `localhost` and nothing else, so the same
/// server reached as 127.0.0.1 is what separates a mode that verifies from one
/// that only encrypts.
#[tokio::test]
#[ignore = "needs a Postgres server with TLS and a trusted certificate"]
async fn each_ssl_mode_connects_the_way_it_says() {
    let host = default_host();
    let refused = encrypted(SslSetting::Verify, "127.0.0.1").await;

    assert_eq!(
        (
            encrypted(SslSetting::Verify, &host).await,
            encrypted(SslSetting::NoVerify, &host).await,
            encrypted(SslSetting::PreferNoVerify, &host).await,
            encrypted(SslSetting::Disable, &host).await,
            encrypted(SslSetting::NoVerify, "127.0.0.1").await,
            // Refused, and saying enough for the refusal to be acted on.
            (
                refused.contains("certificate verify failed"),
                refused.contains("IP address mismatch"),
            ),
        ),
        (
            "encrypted".to_string(),
            "encrypted".to_string(),
            "encrypted".to_string(),
            "plaintext".to_string(),
            "encrypted".to_string(),
            (true, true),
        ),
        "{refused}"
    );
}
