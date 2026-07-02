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
//! - the shutdown signal actually stops the server.

use super::env_config::ServeEnv;
use super::model::ServerModel;
use super::project_schema::ProjectSchema;
use super::test_support::{docker_available, free_port, TestPg};
use super::{http, pg_catalog, ServeState};
use crate::project_paths::ParsedProjectPaths;
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::time::{Duration, Instant};

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
        startup_retry_budget_ms: 60_000,
        healthz_timeout_ms: 2_000,
        ws_ping_interval_ms: 15_000,
        max_concurrent_requests: 64,
        request_timeout_ms: 130_000,
        rate_limit_per_sec: None,
    }
}

struct TestServer {
    port: u16,
    pool: deadpool_postgres::Pool,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    handle: tokio::task::JoinHandle<anyhow::Result<()>>,
}

/// Applies the differential fixture schema/seed to the pool's Postgres,
/// retrying the connection while the container is still coming up. Panics
/// if it can't get a connection at all within the retry budget.
async fn apply_fixture(pool: &deadpool_postgres::Pool) {
    let fixture_dir = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../e2e-tests/fixtures/differential"
    );
    for _ in 0..20 {
        let Ok(client) = pool.get().await else {
            tokio::time::sleep(Duration::from_millis(500)).await;
            continue;
        };
        for file in ["schema.sql", "seed.sql"] {
            let sql = std::fs::read_to_string(format!("{fixture_dir}/{file}")).unwrap();
            client.batch_execute(&sql).await.expect("fixture applies");
        }
        return;
    }
    panic!("could not reach the test Postgres to apply fixtures");
}

/// Applies the differential fixture to the container and boots the server
/// in-process on an ephemeral port, exactly as `serve::run` wires it minus
/// the OS signal handler.
async fn boot(env: ServeEnv, query_timeout: Option<Duration>) -> TestServer {
    let pool = env.make_pg_pool().expect("pool");
    apply_fixture(&pool).await;

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
        healthz_timeout: Duration::from_millis(env.healthz_timeout_ms),
        ws_ping_interval: Duration::from_millis(env.ws_ping_interval_ms),
        max_concurrent_requests: env.max_concurrent_requests,
        request_timeout: Duration::from_millis(env.request_timeout_ms),
        rate_limit_per_sec: env.rate_limit_per_sec,
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
    let server = boot(test_env(pg.port), Some(Duration::from_secs(20))).await;

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
    let server = boot(test_env(pg.port), Some(Duration::from_secs(20))).await;

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
    let server = boot(test_env(pg.port), Some(Duration::from_secs(3))).await;

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
    let mut server = boot(test_env(pg.port), Some(Duration::from_secs(20))).await;

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

const SUBSCRIBE_QUERY: &str = "subscription { SimpleEntity(order_by: {id: asc}, limit: 1) { id } }";

#[tokio::test(flavor = "multi_thread")]
async fn black_holed_websocket_client_is_closed_within_30s() {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    use tokio_tungstenite::tungstenite::http::HeaderValue;
    use tokio_tungstenite::tungstenite::Message as TMessage;

    if !docker_available() {
        eprintln!("skipping: docker is not available");
        return;
    }
    let pg = TestPg::start();
    let mut env = test_env(pg.port);
    // Fast ping interval so "2x interval" is well inside the 30s accept
    // window without the test needing to wait near the production default.
    env.ws_ping_interval_ms = 3_000;
    let server = boot(env, Some(Duration::from_secs(20))).await;

    let mut request = format!("ws://127.0.0.1:{}/v1/graphql", server.port)
        .into_client_request()
        .unwrap();
    request.headers_mut().insert(
        "Sec-WebSocket-Protocol",
        HeaderValue::from_static("graphql-transport-ws"),
    );
    let (mut ws, _) = tokio_tungstenite::connect_async(request)
        .await
        .expect("websocket handshake");

    ws.send(TMessage::Text(
        serde_json::json!({"type": "connection_init"})
            .to_string()
            .into(),
    ))
    .await
    .unwrap();
    let ack = ws.next().await.expect("connection_ack frame").unwrap();
    assert!(
        matches!(ack, TMessage::Text(_)),
        "expected a text connection_ack frame, got {ack:?}"
    );

    ws.send(TMessage::Text(
        serde_json::json!({
            "id": "1",
            "type": "subscribe",
            "payload": { "query": SUBSCRIBE_QUERY }
        })
        .to_string()
        .into(),
    ))
    .await
    .unwrap();
    // Confirm the subscription's background poll loop actually started
    // before going quiet -- otherwise the test would trivially "pass" by
    // never having started anything to detect.
    let first = tokio::time::timeout(Duration::from_secs(5), ws.next())
        .await
        .expect("subscription should push an initial live-query result")
        .unwrap()
        .unwrap();
    assert!(matches!(first, TMessage::Text(_)));

    // Simulate a frozen/black-holed client: stop driving the stream
    // entirely for a while -- no `.next()` calls means no automatic pong
    // replies and no traffic of any kind, without tearing down the TCP
    // connection (a real black hole: the socket is fine, the peer just
    // never reads or writes). ws_ping_interval_ms=3s means the server
    // should give up by ~6s of silence; sleeping well past that before
    // touching the stream again proves detection happened on its own,
    // not because we kept polling and let tungstenite auto-pong for us.
    let started = Instant::now();
    tokio::time::sleep(Duration::from_secs(9)).await;

    // Resume reading (bounded) to observe the close the server should
    // already have sent while we were "frozen". By construction
    // (`run_connection`'s cleanup aborts every operation task on close),
    // that also stops the subscription's Postgres poll loop.
    let closed = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            match ws.next().await {
                Some(Ok(TMessage::Close(_))) | None => return true,
                Some(Ok(_)) => continue,
                Some(Err(_)) => return true,
            }
        }
    })
    .await
    .unwrap_or(false);

    assert_eq!(
        (closed, started.elapsed() < Duration::from_secs(30)),
        (true, true),
        "server should close a black-holed client's connection within 30s"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn serve_becomes_healthy_once_postgres_starts_within_the_retry_budget() {
    if !docker_available() {
        eprintln!("skipping: docker is not available");
        return;
    }
    // Reserve the address but do not start Postgres on it yet -- then start
    // it a few seconds in, exactly like a deploy that starts `envio serve`
    // before its Postgres dependency is ready.
    let port = free_port();
    let mut env = test_env(port);
    env.startup_retry_budget_ms = 30_000;

    let pg_task = tokio::task::spawn_blocking(move || {
        std::thread::sleep(Duration::from_secs(3));
        TestPg::start_on_port(port)
    });

    let pool = env.make_pg_pool().expect("pool");
    let started = Instant::now();
    // Proves the retry-then-recover behavior itself: `wait_for_pg` only
    // needs Postgres reachable, not migrated, so this can succeed against
    // an empty freshly-started container.
    super::wait_for_pg(&pool, &env.pg_schema, env.startup_retry_budget_ms)
        .await
        .expect("wait_for_pg should succeed once Postgres comes up within budget");
    let retry_elapsed = started.elapsed();

    // Schema readiness (migrations) is a separate deploy-ordering concern
    // from Postgres reachability -- apply it now, then introspect fresh so
    // the model actually has tables to serve.
    apply_fixture(&pool).await;
    let catalog = pg_catalog::introspect(&pool, &env.pg_schema).await.unwrap();

    let project_root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../scenarios/test_codegen");
    let paths = ParsedProjectPaths::new(project_root, "config.yaml").unwrap();
    let project_schema = ProjectSchema::load(&paths, &env).unwrap();
    let model = ServerModel::build(project_schema, catalog, &env).unwrap();
    let state = Arc::new(ServeState {
        model,
        pool: pool.clone(),
        admin_secret: env.admin_secret.clone(),
        query_timeout: Some(Duration::from_secs(20)),
        healthz_timeout: Duration::from_millis(env.healthz_timeout_ms),
        ws_ping_interval: Duration::from_millis(env.ws_ping_interval_ms),
        max_concurrent_requests: env.max_concurrent_requests,
        request_timeout: Duration::from_millis(env.request_timeout_ms),
        rate_limit_per_sec: env.rate_limit_per_sec,
    });

    let http_port = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let (_shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn(http::serve(state, "127.0.0.1", http_port, async move {
        let _ = shutdown_rx.await;
    }));

    let client = reqwest::Client::new();
    let mut healthy = false;
    for _ in 0..20 {
        if let Ok(res) = client
            .get(format!("http://127.0.0.1:{http_port}/healthz"))
            .timeout(Duration::from_secs(2))
            .send()
            .await
        {
            if res.status().as_u16() == 200 {
                healthy = true;
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    let _pg = pg_task.await.unwrap();

    assert_eq!(
        (retry_elapsed < Duration::from_secs(30), healthy),
        (true, true),
        "serve should recover once Postgres starts within the retry budget and become healthy"
    );
}
