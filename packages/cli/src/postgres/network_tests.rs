//! A server that goes silent: every packet between it and the indexer dropped
//! without a reset, as a failover that removes the old primary, or a NAT that
//! forgets the connection, does.
//!
//! Needs root, to drop packets with iptables, so it stays out of CI's live
//! run. Run with `cargo test --lib postgres::network -- --ignored` as root,
//! which starts its own server.

use std::process::Command;
use std::time::{Duration, Instant};

use super::client::{Keepalive, PgClient, PgConnectionOptions, SslSetting};
use super::error::is_connection_lost;
use crate::test_servers;

fn client_with(keepalive: Keepalive) -> PgClient {
    PgClient::connect(PgConnectionOptions {
        host: "127.0.0.1".to_string(),
        port: test_servers::postgres().port,
        user: "postgres".to_string(),
        password: test_servers::PASSWORD.to_string(),
        database: "postgres".to_string(),
        ssl: SslSetting::Disable,
        max_connections: 1,
        application_name: Some("envio-network-test".to_string()),
        extra_ca_file: None,
        connect_timeout: Duration::from_secs(5),
        keepalive,
    })
    .expect("the pool is built from a static configuration")
}

/// Drops every packet between the server's port and one client's, both ways,
/// for as long as it is held.
struct Silence {
    rules: Vec<[String; 2]>,
}

impl Silence {
    fn between(server_port: u16, client_port: u16) -> Self {
        let rules = vec![
            [server_port.to_string(), client_port.to_string()],
            [client_port.to_string(), server_port.to_string()],
        ];
        for [from, to] in &rules {
            iptables("-I", from, to);
        }
        Self { rules }
    }
}

impl Drop for Silence {
    fn drop(&mut self) {
        for [from, to] in &self.rules {
            iptables("-D", from, to);
        }
    }
}

fn iptables(action: &str, from: &str, to: &str) {
    let status = Command::new("iptables")
        .args([action, "INPUT", "-p", "tcp", "--sport", from, "--dport", to])
        .args(["-j", "DROP"])
        .status()
        .expect("iptables runs");
    assert!(status.success(), "iptables {action} for {from} -> {to}");
}

async fn client_port(client: &PgClient) -> u16 {
    let (rows, _) = client
        .query(
            "SELECT client_port FROM pg_stat_activity WHERE pid = pg_backend_pid()",
            &[],
        )
        .await
        .unwrap();
    rows.first().expect("one row").get::<_, i32>(0) as u16
}

/// The statement went out and was received; its answer never comes. TCP has
/// nothing left to resend, so only keepalive probes can find the server gone,
/// and they give up after `idle` plus `retries` times `interval`.
#[tokio::test]
#[ignore = "needs root, to drop packets with iptables"]
async fn a_statement_whose_server_goes_silent_fails_once_probes_go_unanswered() {
    let client = client_with(Keepalive {
        idle: Duration::from_secs(1),
        interval: Duration::from_secs(1),
        retries: 2,
    });
    let port = client_port(&client).await;
    let started = Instant::now();

    let waiting = tokio::time::timeout(
        Duration::from_secs(20),
        client.query("SELECT pg_sleep(60)", &[]),
    );
    let silencing = async {
        // Real time: the statement has to be on the server before the network
        // goes quiet, or it is the resend that waits, not the answer.
        tokio::time::sleep(Duration::from_millis(500)).await;
        Silence::between(test_servers::postgres().port, port)
    };
    let (outcome, silence) = futures_util::future::join(waiting, silencing).await;
    let elapsed = started.elapsed();
    drop(silence);

    let outcome = match outcome {
        Ok(Err(error)) if is_connection_lost(&error) => "connection lost".to_string(),
        Ok(Err(error)) => format!("failed otherwise: {error:#}"),
        Ok(Ok(_)) => "answered".to_string(),
        Err(_) => "still waiting after 20 s".to_string(),
    };
    assert_eq!(
        (outcome.as_str(), elapsed < Duration::from_secs(10)),
        ("connection lost", true),
        "after {elapsed:?}"
    );
}
