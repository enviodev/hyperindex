//! Failure-mode regression tests: each pins a production behavior against
//! a throwaway Postgres container (skipped when docker isn't available,
//! like env_config's TLS test).
//!
//! Pinned behaviors:
//! - a Postgres outage produces fast, clean GraphQL errors and a failing
//!   /healthz, and the server self-heals without a restart;
//! - recreating a table mid-flight does not poison the prepared-statement
//!   cache (guaranteed by the `(...)::text AS "root"` output shape — every
//!   statement's outer row type is a single text column, so schema changes
//!   never change a cached plan's result type);
//! - a frozen (SIGSTOP'd) Postgres cannot hang requests beyond the
//!   client-side query timeout;
//! - the shutdown signal actually stops the server;
//! - a null `arguments` on an aggregate bool_exp predicate is a validation
//!   error for every op except `count` (whose `arguments` list is genuinely
//!   nullable), instead of reaching SQL generation and producing invalid
//!   syntax like `bool_and(*)`.

use super::env_config::ServeEnv;
use super::model::ServerModel;
use super::project_schema::ProjectSchema;
use super::{http, pg_catalog, ServeState};
use crate::project_paths::ParsedProjectPaths;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn docker_available() -> bool {
    Command::new("docker")
        .arg("info")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn run(cmd: &mut Command) -> std::process::Output {
    let output = cmd.output().expect("failed to run docker");
    assert!(
        output.status.success(),
        "docker command failed: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

/// A throwaway `postgres:16` container, torn down on drop.
struct TestPg {
    name: String,
    port: u16,
}

impl TestPg {
    fn start() -> TestPg {
        let name = format!(
            "envio-robust-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        // A fixed host port, picked by binding an ephemeral socket first:
        // docker re-allocates `-p 127.0.0.1::5432`-style dynamic ports on
        // every container restart, which would make the kill/start
        // recovery test fail for the wrong reason (a real Postgres comes
        // back at the same address).
        let port = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            listener.local_addr().unwrap().port()
        };
        run(Command::new("docker").args([
            "run",
            "-d",
            "--name",
            &name,
            "-e",
            "POSTGRES_PASSWORD=testing",
            "-e",
            "POSTGRES_USER=postgres",
            "-e",
            "POSTGRES_DB=envio-dev",
            "-p",
            &format!("127.0.0.1:{port}:5432"),
            "postgres:16",
        ]));

        for _ in 0..60 {
            let ready = Command::new("docker")
                .args(["exec", &name, "pg_isready", "-U", "postgres"])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
            if ready {
                return TestPg { name, port };
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        panic!("test Postgres container did not become ready in time");
    }

    fn docker(&self, action: &str) {
        run(Command::new("docker").args([action, &self.name]));
    }
}

impl Drop for TestPg {
    fn drop(&mut self) {
        let _ = Command::new("docker")
            .args(["rm", "-f", &self.name])
            .output();
    }
}

fn test_env(pg_port: u16) -> ServeEnv {
    ServeEnv {
        pg_host: "localhost".to_string(),
        pg_port,
        pg_user: "postgres".to_string(),
        pg_password: "testing".to_string(),
        pg_database: "envio-dev".to_string(),
        pg_schema: "public".to_string(),
        pg_ssl: false,
        admin_secret: "testing".to_string(),
        response_limit: None,
        aggregate_entities: vec![],
        query_timeout_ms: Some(120_000),
        pool_wait_timeout_ms: Some(15_000),
        connect_timeout_ms: Some(5_000),
        pool_max_size: 8,
    }
}

struct TestServer {
    port: u16,
    pool: deadpool_postgres::Pool,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    handle: tokio::task::JoinHandle<anyhow::Result<()>>,
}

/// Applies the differential fixture (plus optional test-local extra DDL) to
/// the container and boots the server in-process on an ephemeral port,
/// exactly as `serve::run` wires it minus the OS signal handler.
async fn boot(
    env: ServeEnv,
    query_timeout: Option<Duration>,
    extra_sql: Option<&str>,
) -> TestServer {
    let pool = env.make_pg_pool().expect("pool");

    let fixture_dir = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../e2e-tests/fixtures/differential"
    );
    let mut applied = false;
    for _ in 0..20 {
        let Ok(client) = pool.get().await else {
            tokio::time::sleep(Duration::from_millis(500)).await;
            continue;
        };
        for file in ["schema.sql", "seed.sql"] {
            let sql = std::fs::read_to_string(format!("{fixture_dir}/{file}")).unwrap();
            client.batch_execute(&sql).await.expect("fixture applies");
        }
        if let Some(sql) = extra_sql {
            client
                .batch_execute(sql)
                .await
                .expect("extra fixture SQL applies");
        }
        applied = true;
        break;
    }
    assert!(
        applied,
        "could not reach the test Postgres to apply fixtures"
    );

    let project_root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../scenarios/test_codegen");
    let paths = ParsedProjectPaths::new(project_root, "config.yaml").unwrap();
    let project_schema = ProjectSchema::load(&paths, &env).unwrap();
    let catalog = pg_catalog::introspect(&pool, &env.pg_schema).await.unwrap();
    let model = ServerModel::build(project_schema, catalog, &env).unwrap();

    let state = Arc::new(ServeState {
        model,
        pool: pool.clone(),
        admin_secret: env.admin_secret.clone(),
        query_timeout,
    });

    let port = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let handle = tokio::spawn(http::serve(state, "127.0.0.1", port, async move {
        let _ = rx.await;
    }));

    let client = reqwest::Client::new();
    for _ in 0..40 {
        if let Ok(res) = client
            .get(format!("http://127.0.0.1:{port}/healthz"))
            .timeout(Duration::from_secs(3))
            .send()
            .await
        {
            if res.status().as_u16() == 200 {
                return TestServer {
                    port,
                    pool,
                    shutdown: Some(tx),
                    handle,
                };
            }
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    panic!("in-process envio serve did not become healthy");
}

impl TestServer {
    async fn graphql(&self, query: &str, timeout: Duration) -> (u16, serde_json::Value) {
        let res = reqwest::Client::new()
            .post(format!("http://127.0.0.1:{}/v1/graphql", self.port))
            .header("content-type", "application/json")
            .body(serde_json::json!({ "query": query }).to_string())
            .timeout(timeout)
            .send()
            .await
            .expect("request should get an HTTP response");
        let status = res.status().as_u16();
        let body: serde_json::Value = res.json().await.expect("JSON body");
        (status, body)
    }

    async fn healthz(&self) -> u16 {
        reqwest::Client::new()
            .get(format!("http://127.0.0.1:{}/healthz", self.port))
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map(|r| r.status().as_u16())
            .unwrap_or(0)
    }
}

fn db_error_body(message: &str, code: &str) -> serde_json::Value {
    serde_json::json!({
        "errors": [{
            "message": message,
            "extensions": { "path": "$", "code": code }
        }]
    })
}

const SIMPLE_QUERY: &str = "{ SimpleEntity(order_by: {id: asc}, limit: 1) { id } }";

#[tokio::test(flavor = "multi_thread")]
async fn postgres_outage_errors_cleanly_and_recovers_without_restart() {
    if !docker_available() {
        eprintln!("skipping: docker is not available");
        return;
    }
    let pg = TestPg::start();
    let server = boot(test_env(pg.port), Some(Duration::from_secs(20)), None).await;

    let (status, body) = server.graphql(SIMPLE_QUERY, Duration::from_secs(10)).await;
    assert_eq!(
        (
            status,
            body["data"]["SimpleEntity"].is_array(),
            server.healthz().await
        ),
        (200, true, 200)
    );

    pg.docker("kill");

    // Requests during the outage: fast, clean GraphQL error — not a hang,
    // not a connection reset.
    let started = Instant::now();
    let (status, body) = server.graphql(SIMPLE_QUERY, Duration::from_secs(30)).await;
    assert_eq!(
        (
            status,
            body,
            started.elapsed() < Duration::from_secs(25),
            server.healthz().await
        ),
        (
            200,
            db_error_body("database query error", "postgres-error"),
            true,
            500
        )
    );

    pg.docker("start");

    // Self-heals with no server restart: the pool discards dead
    // connections and dials fresh ones.
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let (status, body) = server.graphql(SIMPLE_QUERY, Duration::from_secs(10)).await;
        if status == 200 && body["data"]["SimpleEntity"].is_array() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "server did not recover after Postgres came back: {status} {body}"
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert_eq!(server.healthz().await, 200);
}

#[tokio::test(flavor = "multi_thread")]
async fn table_recreate_does_not_poison_statement_cache() {
    if !docker_available() {
        eprintln!("skipping: docker is not available");
        return;
    }
    let pg = TestPg::start();
    let server = boot(test_env(pg.port), Some(Duration::from_secs(20)), None).await;

    let query = "{ SimpleEntity(order_by: {id: asc}) { id value } }";
    for _ in 0..3 {
        let (status, _) = server.graphql(query, Duration::from_secs(10)).await;
        assert_eq!(status, 200);
    }

    // Full re-migration while statements are cached: new relation OID,
    // same shape. This is what an indexer redeploy does under a running
    // serve process.
    let client = server.pool.get().await.unwrap();
    client
        .batch_execute(
            r#"
            DROP TABLE public."SimpleEntity" CASCADE;
            CREATE TABLE public."SimpleEntity" (id text NOT NULL, value text NOT NULL);
            ALTER TABLE ONLY public."SimpleEntity" ADD CONSTRAINT "SimpleEntity_pkey" PRIMARY KEY (id);
            INSERT INTO public."SimpleEntity" (id, value) VALUES ('after-recreate', 'v');
            "#,
        )
        .await
        .unwrap();
    drop(client);

    // Every pooled connection (not just one) must keep working; hit the
    // endpoint several times to cycle through them.
    for _ in 0..5 {
        let (status, body) = server.graphql(query, Duration::from_secs(10)).await;
        assert_eq!(
            (status, body),
            (
                200,
                serde_json::json!({"data": {"SimpleEntity": [{"id": "after-recreate", "value": "v"}]}})
            )
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn frozen_postgres_is_bounded_by_the_client_query_timeout() {
    if !docker_available() {
        eprintln!("skipping: docker is not available");
        return;
    }
    let pg = TestPg::start();
    // Short client-side timeout; the server-side statement_timeout can't
    // fire because Postgres is frozen, so this is the only bound.
    let server = boot(test_env(pg.port), Some(Duration::from_secs(3)), None).await;

    let (status, _) = server.graphql(SIMPLE_QUERY, Duration::from_secs(10)).await;
    assert_eq!(status, 200);

    pg.docker("pause");
    let started = Instant::now();
    let (status, body) = server.graphql(SIMPLE_QUERY, Duration::from_secs(30)).await;
    let elapsed = started.elapsed();
    pg.docker("unpause");

    assert_eq!(
        (
            status,
            body,
            elapsed > Duration::from_secs(2) && elapsed < Duration::from_secs(15)
        ),
        (
            200,
            db_error_body("database query timeout", "unexpected"),
            true
        )
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn shutdown_signal_stops_the_server() {
    if !docker_available() {
        eprintln!("skipping: docker is not available");
        return;
    }
    let pg = TestPg::start();
    let mut server = boot(test_env(pg.port), Some(Duration::from_secs(20)), None).await;

    let (status, _) = server.graphql(SIMPLE_QUERY, Duration::from_secs(10)).await;
    assert_eq!(status, 200);

    server.shutdown.take().unwrap().send(()).unwrap();
    let serve_result = tokio::time::timeout(Duration::from_secs(15), &mut server.handle)
        .await
        .expect("server should stop within the drain timeout")
        .expect("serve task should not panic");
    let new_request = reqwest::Client::new()
        .get(format!("http://127.0.0.1:{}/healthz", server.port))
        .timeout(Duration::from_secs(2))
        .send()
        .await;
    assert_eq!(
        (serve_result.is_ok(), new_request.is_err()),
        (true, true),
        "server should exit cleanly and stop accepting connections"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn aggregate_bool_exp_null_arguments_errors_cleanly() {
    if !docker_available() {
        eprintln!("skipping: docker is not available");
        return;
    }
    let pg = TestPg::start();
    let mut env = test_env(pg.port);
    // Exposes Token_aggregate_bool_exp (incl. bool_and/bool_or, once Token
    // has a boolean column) on NftCollection_bool_exp.tokens_aggregate for
    // the public role, mirroring aggregations_enabled's `table.public_aggregations`
    // check in gql/schema_build.rs.
    env.aggregate_entities = vec!["Token".to_string()];
    let server = boot(
        env,
        Some(Duration::from_secs(20)),
        Some(r#"ALTER TABLE public."Token" ADD COLUMN is_special boolean NOT NULL DEFAULT false;"#),
    )
    .await;

    // Omitting `arguments` entirely means count(*): confirmed live against
    // Hasura 2.43.0 on this exact fixture (this data shape and row set is
    // its real recorded response, not a guess).
    let (status, body) = server
        .graphql(
            "{ NftCollection(where: {tokens_aggregate: {count: {predicate: {_gte: 0}}}}) { id } }",
            Duration::from_secs(10),
        )
        .await;
    assert_eq!(
        (status, body),
        (
            200,
            serde_json::json!({"data": {"NftCollection": [
                {"id": "coll-1"}, {"id": "coll-2"}, {"id": "coll-3"}
            ]}})
        )
    );

    // An explicit `arguments: null` is a validation error even for count,
    // whose `arguments` is a nullable *list* type — Hasura rejects the null
    // literal itself rather than treating it as an omitted key. Wording and
    // path confirmed live against Hasura 2.43.0 on this exact query.
    let (status, body) = server
        .graphql(
            "{ NftCollection(where: {tokens_aggregate: {count: {arguments: null, predicate: {_gte: 0}}}}) { id } }",
            Duration::from_secs(10),
        )
        .await;
    assert_eq!(
        (status, body),
        (
            200,
            serde_json::json!({"errors": [{
                "message": "expected a list, but found null",
                "extensions": {
                    "path": "$.selectionSet.NftCollection.args.where.tokens_aggregate.count.arguments",
                    "code": "validation-failed"
                }
            }]})
        )
    );

    // bool_and/bool_or's `arguments` is a single non-null column enum: a
    // null literal must be rejected as a validation error up front, not
    // passed through to SQL generation as `bool_and(*)` (invalid syntax —
    // only count(*) accepts the bare-`*` form). Wording and path confirmed
    // live against Hasura 2.43.0 on this exact query.
    let (status, body) = server
        .graphql(
            "{ NftCollection(where: {tokens_aggregate: {bool_and: {arguments: null, predicate: {_eq: true}}}}) { id } }",
            Duration::from_secs(10),
        )
        .await;
    assert_eq!(
        (status, body),
        (
            200,
            serde_json::json!({"errors": [{
                "message": "expected an enum value for type 'Token_select_column_Token_aggregate_bool_exp_bool_and_arguments_columns', but found null",
                "extensions": {
                    "path": "$.selectionSet.NftCollection.args.where.tokens_aggregate.bool_and.arguments",
                    "code": "validation-failed"
                }
            }]})
        )
    );
}
