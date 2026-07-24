//! Shared docker-container test helpers for tests that need a throwaway
//! Postgres (TLS handshake test in env_config.rs, robustness/chaos tests in
//! robustness_tests.rs). Callers skip (not fail) when docker isn't
//! available, matching CI/dev environments that don't have it.

use std::process::Command;

pub fn docker_available() -> bool {
    Command::new("docker")
        .arg("info")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Returns true when the caller should skip because docker is missing.
/// With ENVIO_REQUIRE_DOCKER=1 (set in CI) a missing docker is a hard
/// failure instead — otherwise every docker-gated test would silently pass
/// vacuously if docker ever vanished from the runners.
pub fn skip_without_docker() -> bool {
    if docker_available() {
        return false;
    }
    if std::env::var("ENVIO_REQUIRE_DOCKER").as_deref() == Ok("1") {
        panic!("docker is required (ENVIO_REQUIRE_DOCKER=1) but not available");
    }
    eprintln!("skipping: docker is not available");
    true
}

pub fn run(cmd: &mut Command) -> std::process::Output {
    let output = cmd.output().expect("failed to run docker");
    assert!(
        output.status.success(),
        "docker command failed: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

/// Picks a free TCP port by binding an ephemeral socket and immediately
/// releasing it -- used for docker `-p host:container` mappings that need a
/// fixed, predictable host port across container restarts (docker
/// re-allocates dynamic `-p 127.0.0.1::PORT` mappings on every restart, which
/// breaks tests that expect a stable address across a kill/start cycle).
pub fn free_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.local_addr().unwrap().port()
}

/// A unique-per-process-per-instant suffix for docker resource names
/// (containers, volumes) so concurrent test runs on the same machine never
/// collide.
pub fn unique_id() -> String {
    format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    )
}

/// A throwaway `postgres:16` container on a fixed host port, torn down on
/// drop. No TLS, no custom config -- for the TLS handshake test, see
/// env_config's own `TestTlsPostgres`, which needs a custom cert/config
/// mount this helper doesn't support.
pub struct TestPg {
    name: String,
    pub port: u16,
}

impl TestPg {
    pub fn start() -> TestPg {
        Self::start_on_port(free_port())
    }

    /// Like `start`, but on a caller-chosen port instead of one freshly
    /// picked here -- for tests that need to reserve the address before
    /// Postgres actually exists on it (startup-retry tests).
    pub fn start_on_port(port: u16) -> TestPg {
        let name = format!("envio-serve-test-pg-{}", unique_id());
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
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        panic!("test Postgres container did not become ready in time");
    }

    pub fn docker(&self, action: &str) {
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
