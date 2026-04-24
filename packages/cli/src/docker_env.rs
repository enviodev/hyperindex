use anyhow::Context;
use bollard::models::{
    ContainerCreateBody, EndpointSettings, HealthConfig, HostConfig, Mount, MountTypeEnum,
    NetworkCreateRequest, NetworkingConfig, PortBinding, RestartPolicy, RestartPolicyNameEnum,
    VolumeCreateRequest,
};
use bollard::query_parameters::{
    CreateContainerOptionsBuilder, CreateImageOptionsBuilder, ListContainersOptionsBuilder,
    RemoveContainerOptionsBuilder, StopContainerOptionsBuilder,
};
use bollard::{Docker, API_DEFAULT_VERSION};
use dotenvy::{EnvLoader, EnvMap, EnvSequence};
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use sqlx::ConnectOptions;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::net::TcpStream;
use tokio::time::Duration;

const POSTGRES_IMAGE: &str = "postgres:18.3";
const HASURA_IMAGE: &str = "hasura/graphql-engine:v2.43.0";
const CLICKHOUSE_IMAGE: &str = "clickhouse/clickhouse-server:26.2.15.4";
const CONFIG_HASH_LABEL: &str = "dev.envio.config-hash";
const PROJECT_PATH_LABEL: &str = "dev.envio.project-path";
const PROJECT_NAME_LABEL: &str = "dev.envio.project-name";
const SOCKET_TIMEOUT: u64 = 120;

const PG_CONTAINER: &str = "envio-postgres";
const HASURA_CONTAINER: &str = "envio-hasura";
const CH_CONTAINER: &str = "envio-clickhouse";
const VOLUME: &str = "envio-postgres-data";
const CH_VOLUME: &str = "envio-clickhouse-data";
const NETWORK: &str = "envio-network";

/// Extra Docker socket locations that `connect_with_local_defaults()` may miss.
/// Notably, macOS Docker Desktop 4.x+ puts the socket under `~/.docker/run/`
/// and `/var/run/docker.sock` only exists if the user explicitly enables
/// "Allow the default Docker socket to be used" in Docker Desktop settings.
fn docker_socket_candidates() -> Vec<PathBuf> {
    let mut paths = Vec::new();

    if let Ok(home) = std::env::var("HOME") {
        // Docker Desktop 4.x+ (macOS / Linux Desktop)
        paths.push(PathBuf::from(&home).join(".docker/run/docker.sock"));
        // Older Docker Desktop (macOS)
        paths.push(PathBuf::from(&home).join(".docker/desktop/docker.sock"));
    }

    paths
}

fn podman_socket_candidates() -> Vec<PathBuf> {
    let mut paths = Vec::new();

    // Rootless: $XDG_RUNTIME_DIR/podman/podman.sock
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        paths.push(PathBuf::from(xdg).join("podman/podman.sock"));
    }

    // macOS Podman machine
    if let Ok(home) = std::env::var("HOME") {
        paths.push(PathBuf::from(&home).join(".local/share/containers/podman/machine/podman.sock"));
        paths.push(
            PathBuf::from(&home).join(".local/share/containers/podman/machine/qemu/podman.sock"),
        );
    }

    // Linux rootful
    paths.push(PathBuf::from("/run/podman/podman.sock"));

    paths
}

/// Strip `unix://` prefix from a URI to get a filesystem path.
fn socket_path_from_uri(uri: &str) -> &str {
    uri.strip_prefix("unix://").unwrap_or(uri)
}

/// Try connecting to a Docker-compatible socket, returning the client and a
/// human-readable label describing how the connection was made.
async fn try_socket(path: &str) -> Option<Docker> {
    let docker = Docker::connect_with_socket(path, SOCKET_TIMEOUT, API_DEFAULT_VERSION).ok()?;
    docker.ping().await.ok()?;
    Some(docker)
}

/// Connect to Docker or Podman, trying multiple strategies:
/// 1. `DOCKER_HOST` / default Docker socket
/// 2. Well-known Docker Desktop socket paths
/// 3. `CONTAINER_HOST` (Podman convention)
/// 4. Common Podman socket paths
async fn connect_docker() -> anyhow::Result<Docker> {
    // Try Docker defaults (respects DOCKER_HOST env var)
    if let Ok(docker) = Docker::connect_with_local_defaults() {
        if docker.ping().await.is_ok() {
            if let Ok(host) = std::env::var("DOCKER_HOST") {
                println!("Connected to Docker via DOCKER_HOST ({host})");
            } else {
                println!("Connected to Docker via default socket");
            }
            return Ok(docker);
        }
    }

    // Try well-known Docker Desktop socket paths (macOS, Linux Desktop)
    for path in docker_socket_candidates() {
        if path.exists() {
            if let Some(path_str) = path.to_str() {
                if let Some(docker) = try_socket(path_str).await {
                    println!("Connected to Docker via {path_str}");
                    return Ok(docker);
                }
            }
        }
    }

    // Try CONTAINER_HOST (Podman's equivalent of DOCKER_HOST)
    if let Ok(host) = std::env::var("CONTAINER_HOST") {
        let path = socket_path_from_uri(&host);
        if let Some(docker) = try_socket(path).await {
            println!("Connected to Podman via CONTAINER_HOST ({host})");
            return Ok(docker);
        }
    }

    // Try common Podman socket paths
    for path in podman_socket_candidates() {
        if path.exists() {
            if let Some(path_str) = path.to_str() {
                if let Some(docker) = try_socket(path_str).await {
                    println!("Connected to Podman via {path_str}");
                    return Ok(docker);
                }
            }
        }
    }

    // Build an actionable error with platform-specific hints.
    let hint = if cfg!(target_os = "macos") {
        "Hint: Open Docker Desktop, or run:\n  \
         export DOCKER_HOST=unix://$HOME/.docker/run/docker.sock"
    } else {
        "Hint: Start the Docker daemon:\n  \
         sudo systemctl start docker"
    };

    anyhow::bail!(
        "Failed connecting to Docker or Podman. Is the daemon running?\n\
         Checked: DOCKER_HOST, default Docker socket, ~/.docker/run/docker.sock, \
         CONTAINER_HOST, common Podman sockets.\n\n\
         {hint}"
    )
}

const DEFAULT_PG_HOST: &str = "localhost";
const DEFAULT_CH_URL: &str = "http://localhost:8123";

struct EnvConfig {
    /// None when the user hasn't set ENVIO_PG_HOST — that's our signal that
    /// they want the Dockerised Postgres and we'll point everything at
    /// DEFAULT_PG_HOST. Some(value) means "I manage this myself", which
    /// bypasses the container entirely regardless of what the value is
    /// (even "localhost").
    pg_host: Option<String>,
    pg_port: String,
    pg_password: String,
    pg_user: String,
    pg_database: String,
    hasura_enabled: bool,
    hasura_port: String,
    hasura_enable_console: String,
    hasura_admin_secret: String,
    /// Same presence-is-the-flag rule as pg_host: None → start our
    /// ClickHouse container at DEFAULT_CH_URL; Some(url) → user manages it.
    ch_host: Option<String>,
    ch_user: String,
    ch_password: String,
    ch_database: String,
}

/// Parsed view of `ENVIO_CLICKHOUSE_HOST`. Scheme-derived default port lets
/// users omit `:8123` on managed ClickHouse URLs like `https://…cloud`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ClickHouseUrl {
    scheme: String,
    host: String,
    port: u16,
}

impl ClickHouseUrl {
    fn parse(raw: &str) -> anyhow::Result<Self> {
        let url = reqwest::Url::parse(raw).with_context(|| {
            format!(
                "ENVIO_CLICKHOUSE_HOST={raw:?} is not a valid URL.\n\
                 Expected format: http://host:port (e.g. http://localhost:8123).\n\
                 Unset the variable to let the CLI start a local Docker container instead."
            )
        })?;
        let scheme = url.scheme().to_string();
        if scheme != "http" && scheme != "https" {
            anyhow::bail!(
                "ENVIO_CLICKHOUSE_HOST={raw:?} uses unsupported scheme {scheme:?}.\n\
                 Only http:// and https:// are supported."
            );
        }
        let host = url
            .host_str()
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "ENVIO_CLICKHOUSE_HOST={raw:?} has no hostname.\n\
                     Expected format: http://host:port (e.g. http://localhost:8123)."
                )
            })?
            .to_string();
        let port = url
            .port()
            .unwrap_or(if scheme == "https" { 443 } else { 8123 });
        Ok(Self { scheme, host, port })
    }
}

impl EnvConfig {
    fn from_project(project_root: &Path) -> Self {
        let dotenv = EnvLoader::with_path(project_root.join(".env"))
            .sequence(EnvSequence::InputOnly)
            .load()
            .ok();

        let var_opt = |name: &str| -> Option<String> {
            std::env::var(name)
                .ok()
                .or_else(|| dotenv.as_ref().and_then(|m: &EnvMap| m.var(name).ok()))
        };
        let var = |name: &str, default: &str| -> String {
            var_opt(name).unwrap_or_else(|| default.to_string())
        };

        Self {
            pg_host: var_opt("ENVIO_PG_HOST"),
            pg_port: var("ENVIO_PG_PORT", "5433"),
            pg_password: var("ENVIO_PG_PASSWORD", "testing"),
            pg_user: var("ENVIO_PG_USER", "postgres"),
            pg_database: var("ENVIO_PG_DATABASE", "envio-dev"),
            hasura_enabled: var("ENVIO_HASURA", "true") != "false",
            hasura_port: var("HASURA_EXTERNAL_PORT", "8080"),
            hasura_enable_console: var("HASURA_GRAPHQL_ENABLE_CONSOLE", "true"),
            hasura_admin_secret: var("HASURA_GRAPHQL_ADMIN_SECRET", "testing"),
            ch_host: var_opt("ENVIO_CLICKHOUSE_HOST"),
            ch_user: var("ENVIO_CLICKHOUSE_USERNAME", "default"),
            ch_password: var("ENVIO_CLICKHOUSE_PASSWORD", "testing"),
            ch_database: var("ENVIO_CLICKHOUSE_DATABASE", "envio_sink"),
        }
    }

    /// External ⇔ the user set ENVIO_PG_HOST at all. Any value (even the
    /// literal "localhost") is treated as an explicit "I manage Postgres
    /// myself"; unset means we boot the Dockerised Postgres.
    fn pg_is_external(&self) -> bool {
        self.pg_host.is_some()
    }

    /// The host string to connect to — either the user-provided value when
    /// external, or DEFAULT_PG_HOST for our own container.
    fn pg_host_str(&self) -> &str {
        self.pg_host.as_deref().unwrap_or(DEFAULT_PG_HOST)
    }

    /// External ⇔ the user set ENVIO_CLICKHOUSE_HOST at all. Same rule as
    /// pg_is_external; unset means we boot the container at DEFAULT_CH_URL.
    fn ch_is_external(&self) -> bool {
        self.ch_host.is_some()
    }

    /// The raw URL string — either the user-provided value when external,
    /// or DEFAULT_CH_URL for our own container.
    fn ch_host_str(&self) -> &str {
        self.ch_host.as_deref().unwrap_or(DEFAULT_CH_URL)
    }

    /// Parse the effective URL (user's when external, default otherwise).
    /// The caller decides when to fail — we only parse if ClickHouse is
    /// actually selected, so users who never opt into ClickHouse can keep
    /// garbage in ENVIO_CLICKHOUSE_HOST.
    fn ch_url(&self) -> anyhow::Result<ClickHouseUrl> {
        ClickHouseUrl::parse(self.ch_host_str())
    }

    /// Per-service config hashes so that changing one service's config only
    /// recreates *that* container instead of all of them. Host fields are
    /// excluded: when external, no container is created; when local, the
    /// host is always the hardcoded default and can't vary.
    fn pg_config_hash(&self) -> String {
        let mut h = Sha256::new();
        h.update(&self.pg_port);
        h.update(&self.pg_password);
        h.update(&self.pg_user);
        h.update(&self.pg_database);
        format!("{:x}", h.finalize())
    }

    fn hasura_config_hash(&self) -> String {
        let mut h = Sha256::new();
        h.update(&self.pg_password);
        h.update(&self.pg_user);
        h.update(&self.pg_database);
        // HASURA_GRAPHQL_DATABASE_URL embeds the PG host + port, so toggling
        // ENVIO_PG_HOST (external ↔ managed) or changing the port changes
        // the container's baked-in DSN. Without these in the hash, drift
        // isn't detected and Hasura silently keeps pointing at the old DB.
        h.update(if self.pg_is_external() {
            "ext"
        } else {
            "local"
        });
        h.update(self.pg_host_str());
        h.update(&self.pg_port);
        h.update(&self.hasura_port);
        h.update(&self.hasura_enable_console);
        h.update(&self.hasura_admin_secret);
        format!("{:x}", h.finalize())
    }

    fn ch_config_hash(&self) -> String {
        let mut h = Sha256::new();
        h.update(&self.ch_user);
        h.update(&self.ch_password);
        h.update(&self.ch_database);
        format!("{:x}", h.finalize())
    }
}

/// Maximum time allowed for pulling a single image before we give up.
const IMAGE_PULL_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// How many times to retry a failed image pull before giving up.
const IMAGE_PULL_RETRIES: u32 = 3;

fn format_bytes(bytes: i64) -> String {
    const MB: i64 = 1_000_000;
    if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else {
        format!("{} kB", bytes / 1_000)
    }
}

async fn pull_image_once(docker: &Docker, image: &str) -> anyhow::Result<()> {
    let (repo, tag) = image.rsplit_once(':').unwrap_or((image, "latest"));

    let options = CreateImageOptionsBuilder::new()
        .from_image(repo)
        .tag(tag)
        .build();

    let mut stream = docker.create_image(Some(options), None, None);
    while let Some(result) = stream.next().await {
        let info = result.with_context(|| format!("Failed pulling image {image}"))?;
        if let Some(status) = &info.status {
            let progress = info
                .progress_detail
                .as_ref()
                .and_then(|d| match (d.current, d.total) {
                    (Some(cur), Some(tot)) if tot > 0 => {
                        Some(format!(" {}/{}", format_bytes(cur), format_bytes(tot)))
                    }
                    _ => None,
                })
                .unwrap_or_default();
            match &info.id {
                Some(id) => eprint!("\r  {id}: {status}{progress}  "),
                None => eprint!("\r  {status}{progress}  "),
            }
        }
    }
    eprintln!();
    Ok(())
}

async fn ensure_image(docker: &Docker, image: &str) -> anyhow::Result<()> {
    if docker.inspect_image(image).await.is_ok() {
        return Ok(());
    }

    println!("Pulling image {image}...");

    let mut last_err = None;
    for attempt in 1..=IMAGE_PULL_RETRIES {
        let result = tokio::time::timeout(IMAGE_PULL_TIMEOUT, pull_image_once(docker, image)).await;
        match result {
            Ok(Ok(())) => {
                println!("Pulled {image}");
                return Ok(());
            }
            Ok(Err(e)) => {
                last_err = Some(format!("{e:#}"));
                if attempt < IMAGE_PULL_RETRIES {
                    let delay = Duration::from_secs(2u64.pow(attempt));
                    eprintln!(
                        "\nPull attempt {attempt}/{IMAGE_PULL_RETRIES} failed: {e:#}\n\
                         Retrying in {}s...",
                        delay.as_secs()
                    );
                    tokio::time::sleep(delay).await;
                }
            }
            Err(_) => {
                last_err = Some(format!("Timed out after {}s", IMAGE_PULL_TIMEOUT.as_secs()));
                if attempt < IMAGE_PULL_RETRIES {
                    eprintln!(
                        "\nPull attempt {attempt}/{IMAGE_PULL_RETRIES} timed out.\n\
                         Retrying..."
                    );
                }
            }
        }
    }

    anyhow::bail!(
        "Failed to pull image {image} after {IMAGE_PULL_RETRIES} attempts.\n\
         Last error: {}\n\
         Check your network connection and Docker Hub rate limits.",
        last_err.unwrap_or_default()
    )
}

async fn ensure_network(docker: &Docker, name: &str) -> anyhow::Result<()> {
    // Fast path: if the network already exists, skip creation entirely.
    if docker
        .inspect_network(
            name,
            None::<bollard::query_parameters::InspectNetworkOptions>,
        )
        .await
        .is_ok()
    {
        return Ok(());
    }

    // Tolerate a 409 "already exists" race from parallel pipelines both missing
    // the inspect and then one losing the create.
    match docker
        .create_network(NetworkCreateRequest {
            name: name.to_string(),
            driver: Some("bridge".to_string()),
            ..Default::default()
        })
        .await
    {
        Ok(_) => Ok(()),
        Err(bollard::errors::Error::DockerResponseServerError {
            status_code: 409, ..
        }) => Ok(()),
        Err(e) => Err(e).with_context(|| format!("Failed creating network {name}")),
    }
}

async fn ensure_volume(docker: &Docker, name: &str) -> anyhow::Result<()> {
    if docker.inspect_volume(name).await.is_ok() {
        return Ok(());
    }

    docker
        .create_volume(VolumeCreateRequest {
            name: Some(name.to_string()),
            ..Default::default()
        })
        .await
        .with_context(|| format!("Failed creating volume {name}"))?;

    Ok(())
}

/// Returns true if container exists and is running.
async fn is_container_running(docker: &Docker, name: &str) -> bool {
    match docker.inspect_container(name, None).await {
        Ok(info) => info.state.and_then(|s| s.running).unwrap_or(false),
        Err(_) => false,
    }
}

/// Returns true if container exists (running or stopped).
async fn container_exists(docker: &Docker, name: &str) -> bool {
    docker.inspect_container(name, None).await.is_ok()
}

/// Try to connect to a TCP port to check if a service is already listening.
async fn is_service_reachable(host: &str, port: u16) -> bool {
    tokio::time::timeout(Duration::from_secs(2), TcpStream::connect((host, port)))
        .await
        .map(|r| r.is_ok())
        .unwrap_or(false)
}

/// Shared HTTP client for health probes, built once and reused across the
/// initial probe and subsequent wait loops. Avoids allocating a new
/// connection pool + TLS context on every tick.
fn build_probe_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .expect("failed to build HTTP client for health probes")
}

/// Check whether Hasura is reachable by hitting its healthz endpoint.
async fn is_hasura_healthy(client: &reqwest::Client, host: &str, port: u16) -> bool {
    let url = format!("http://{}:{}/hasura/healthz?strict=true", host, port);
    client
        .get(&url)
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// Check whether ClickHouse is reachable by hitting its `/ping` endpoint.
/// Uses the caller-provided scheme so that `https://` cloud ClickHouse
/// endpoints work without extra wiring.
async fn is_clickhouse_healthy(
    client: &reqwest::Client,
    scheme: &str,
    host: &str,
    port: u16,
) -> bool {
    let url = format!("{scheme}://{host}:{port}/ping");
    client
        .get(&url)
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

async fn stop_and_remove(docker: &Docker, name: &str) {
    if is_container_running(docker, name).await {
        let stop_opts = StopContainerOptionsBuilder::new().t(5).build();
        let _ = docker.stop_container(name, Some(stop_opts)).await;
    }
    if container_exists(docker, name).await {
        let rm_opts = RemoveContainerOptionsBuilder::new()
            .v(true)
            .force(true)
            .build();
        let _ = docker.remove_container(name, Some(rm_opts)).await;
    }
}

fn make_networking_config(net: &str) -> NetworkingConfig {
    let mut endpoints = HashMap::new();
    endpoints.insert(
        net.to_string(),
        EndpointSettings {
            ..Default::default()
        },
    );
    NetworkingConfig {
        endpoints_config: Some(endpoints),
    }
}

fn make_labels(
    config_hash: &str,
    project_root: &Path,
    indexer_name: &str,
) -> HashMap<String, String> {
    let mut labels = HashMap::new();
    labels.insert(CONFIG_HASH_LABEL.to_string(), config_hash.to_string());
    // Canonicalize so the label identifies the project on disk, not the
    // shell invocation. Without this, `envio dev` from `~/projects/foo`
    // labels the container "." and a second project also running from
    // its own root produces the same label — drift errors can't
    // disambiguate. Falls back to the raw path if canonicalize fails
    // (shouldn't happen for a live run, but don't make the label an error).
    let path = project_root
        .canonicalize()
        .unwrap_or_else(|_| project_root.to_path_buf());
    labels.insert(PROJECT_PATH_LABEL.to_string(), path.display().to_string());
    labels.insert(PROJECT_NAME_LABEL.to_string(), indexer_name.to_string());
    labels
}

/// Find the name of a running container that binds to `host_port`.
async fn find_port_conflict(docker: &Docker, host_port: u16) -> Option<String> {
    let options = ListContainersOptionsBuilder::default().build();
    let containers = docker.list_containers(Some(options)).await.ok()?;

    for container in containers {
        let uses_port = container
            .ports
            .as_deref()
            .unwrap_or_default()
            .iter()
            .any(|p| p.public_port == Some(host_port));

        if uses_port {
            let names = container.names.unwrap_or_default();
            return Some(
                names
                    .first()
                    .map(|n| n.trim_start_matches('/').to_string())
                    .or(container.id)
                    .unwrap_or_default(),
            );
        }
    }

    None
}

/// Build an actionable error for port conflicts, or None if the error is unrelated.
async fn port_conflict_error(
    docker: &Docker,
    name: &str,
    host_port: u16,
    err: &impl std::fmt::Display,
) -> Option<anyhow::Error> {
    let msg = err.to_string();
    if !msg.contains("address already in use") && !msg.contains("port is already allocated") {
        return None;
    }
    let hint = match find_port_conflict(docker, host_port).await {
        Some(c) => format!(
            "Port {host_port} is already in use by container \"{c}\".\n\
             Run: docker stop {c} && docker rm {c}"
        ),
        None => format!(
            "Port {host_port} is already in use by another process.\n\
             Run: lsof -ti :{host_port} | xargs kill"
        ),
    };
    Some(anyhow::anyhow!("Cannot start container {name}.\n{hint}"))
}

/// Start a container, translating port conflicts into actionable errors.
async fn start_container(docker: &Docker, name: &str, host_port: u16) -> anyhow::Result<()> {
    if let Err(e) = docker.start_container(name, None).await {
        if let Some(port_err) = port_conflict_error(docker, name, host_port, &e).await {
            return Err(port_err);
        }
        return Err(e).with_context(|| format!("Failed starting container {name}"));
    }
    Ok(())
}

/// Snapshot of a managed container that doesn't match the current config.
/// Carries enough context for the caller to render a service-specific error.
struct DriftInfo {
    project_name: Option<String>,
    project_path: Option<String>,
    env: HashMap<String, String>,
}

/// Inspect a named container and diff its stored config-hash against the
/// expected one. `Some(info)` means the caller must halt: the container was
/// built with different settings and silently recreating it would destroy
/// data the user (or another project) may still want.
async fn detect_drift(docker: &Docker, name: &str, expected_hash: &str) -> Option<DriftInfo> {
    let info = docker.inspect_container(name, None).await.ok()?;
    let cfg = info.config?;
    let labels = cfg.labels.unwrap_or_default();
    if labels.get(CONFIG_HASH_LABEL).map(String::as_str) == Some(expected_hash) {
        return None;
    }
    let project_name = labels.get(PROJECT_NAME_LABEL).cloned();
    let project_path = labels.get(PROJECT_PATH_LABEL).cloned();
    let env = cfg
        .env
        .unwrap_or_default()
        .into_iter()
        .filter_map(|s| {
            let (k, v) = s.split_once('=')?;
            Some((k.to_string(), v.to_string()))
        })
        .collect();
    Some(DriftInfo {
        project_name,
        project_path,
        env,
    })
}

/// Authenticated Postgres probe. `Ok(())` means the creds work against the
/// database at `host:port`; any other return is an auth / connection failure
/// suitable for display to the user.
async fn probe_pg_auth(
    host: &str,
    port: u16,
    user: &str,
    password: &str,
    database: &str,
) -> Result<(), sqlx::Error> {
    let opts = sqlx::postgres::PgConnectOptions::new()
        .host(host)
        .port(port)
        .username(user)
        .password(password)
        .database(database);
    use sqlx::Connection;
    opts.connect().await?.close().await?;
    Ok(())
}

/// Authenticated ClickHouse probe. Runs `SELECT 1` over HTTP with basic auth.
async fn probe_ch_auth(
    client: &reqwest::Client,
    scheme: &str,
    host: &str,
    port: u16,
    user: &str,
    password: &str,
) -> Result<(), String> {
    let url = format!("{scheme}://{host}:{port}/?query=SELECT+1");
    let resp = client
        .get(&url)
        .basic_auth(user, Some(password))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if resp.status().is_success() {
        return Ok(());
    }
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    Err(format!("HTTP {status}: {}", body.trim()))
}

/// Compare two strings for display. Returns a "want → found" fragment when
/// they differ, or an empty string when they match. Used by the drift error
/// formatters so matching values stay out of the way and differences pop.
fn diff_field(label: &str, want: &str, found: Option<&String>) -> String {
    match found {
        Some(v) if v == want => String::new(),
        Some(v) => format!("    {label}: {want:?} (existing: {v:?})\n"),
        None => format!("    {label}: {want:?} (existing: <unset>)\n"),
    }
}

/// Describe the existing container's owning project. Name is the human
/// handle from config.yaml ("erc20-indexer"); path is the absolute disk
/// location. Both labels may be absent on containers created before they
/// were introduced — degrade gracefully so the error is still usable.
fn owner_line(drift: &DriftInfo) -> String {
    match (&drift.project_name, &drift.project_path) {
        (Some(name), Some(path)) => format!("  Owned by: {name} ({path})\n"),
        (Some(name), None) => format!("  Owned by: {name}\n"),
        (None, Some(path)) => format!("  Owned by: {path}\n"),
        (None, None) => "  Owned by: unknown (container predates the project labels)\n".to_string(),
    }
}

fn format_pg_drift(env: &EnvConfig, port: u16, drift: &DriftInfo) -> String {
    let mut diff = String::new();
    diff.push_str(&diff_field(
        "ENVIO_PG_USER",
        &env.pg_user,
        drift.env.get("POSTGRES_USER"),
    ));
    diff.push_str(&diff_field(
        "ENVIO_PG_DATABASE",
        &env.pg_database,
        drift.env.get("POSTGRES_DB"),
    ));
    // Password is never echoed back; we only note whether it differs.
    let pw_note = match drift.env.get("POSTGRES_PASSWORD") {
        Some(v) if v == &env.pg_password => String::new(),
        _ => "    ENVIO_PG_PASSWORD: differs from existing container\n".to_string(),
    };
    diff.push_str(&pw_note);
    if diff.is_empty() {
        diff.push_str("    (port or other field)\n");
    }

    format!(
        "Docker container {PG_CONTAINER} is already running but was created with a \
         different configuration.\n\
         \n\
         {owner}  Differences:\n\
         {diff}\
         \n\
         The CLI won't silently recreate it — the data volume \"{VOLUME}\" is shared \
         across every project that uses envio-managed Postgres, and recreating would \
         drop tables the other project may still need.\n\
         \n\
         Choose one:\n\
         \n\
         1. Align this project's .env to match the running container, then re-run \
         `envio dev`.\n\
         \n\
         2. Stop the owning project's indexer and remove the container + data:\n\
               docker rm -f {PG_CONTAINER}\n\
               docker volume rm {VOLUME}\n\
            Then re-run `envio dev`. (Any other project using this container will \
         lose its data.)\n\
         \n\
         3. From the owning project, run `envio stop` to tear the stack down \
         cleanly, then re-run `envio dev` from this project.\n\
         \n\
         (Postgres is configured on port {port}.)",
        owner = owner_line(drift)
    )
}

/// Parse the user/database out of a `postgres://…` URL. Password and host
/// are intentionally dropped: password is never displayed, and host changes
/// don't carry actionable meaning in a drift message (the user controls
/// that via ENVIO_PG_HOST which lives outside the container).
fn parse_pg_url_user_db(url: &str) -> Option<(String, String)> {
    let parsed = reqwest::Url::parse(url).ok()?;
    let user = parsed.username().to_string();
    let db = parsed.path().trim_start_matches('/').to_string();
    if user.is_empty() && db.is_empty() {
        return None;
    }
    Some((user, db))
}

fn format_hasura_drift(env: &EnvConfig, port: u16, drift: &DriftInfo) -> String {
    let mut diff = String::new();

    // Hasura's PG creds live inside HASURA_GRAPHQL_DATABASE_URL rather than
    // as individual env vars, so parse user/db out of the URL for display.
    // Password differences are never echoed — flagged with a single note.
    if let Some(url) = drift.env.get("HASURA_GRAPHQL_DATABASE_URL") {
        if let Some((u_user, u_db)) = parse_pg_url_user_db(url) {
            diff.push_str(&diff_field("ENVIO_PG_USER", &env.pg_user, Some(&u_user)));
            diff.push_str(&diff_field(
                "ENVIO_PG_DATABASE",
                &env.pg_database,
                Some(&u_db),
            ));
            if !url.contains(&format!(":{}@", env.pg_password)) {
                diff.push_str("    ENVIO_PG_PASSWORD: differs from existing container\n");
            }
        }
    }
    diff.push_str(&diff_field(
        "HASURA_GRAPHQL_ENABLE_CONSOLE",
        &env.hasura_enable_console,
        drift.env.get("HASURA_GRAPHQL_ENABLE_CONSOLE"),
    ));
    let secret_note = match drift.env.get("HASURA_GRAPHQL_ADMIN_SECRET") {
        Some(v) if v == &env.hasura_admin_secret => String::new(),
        _ => "    HASURA_GRAPHQL_ADMIN_SECRET: differs from existing container\n".to_string(),
    };
    diff.push_str(&secret_note);
    if diff.is_empty() {
        // Port binding (HASURA_EXTERNAL_PORT) changes don't show up in the
        // container's env vars, so we can't enumerate them — the config hash
        // still catches the drift, we just can't point at a specific field.
        diff.push_str("    (port binding or other configuration field)\n");
    }

    format!(
        "Docker container {HASURA_CONTAINER} is already running but was created with \
         a different configuration.\n\
         \n\
         {owner}  Differences:\n\
         {diff}\
         \n\
         Choose one:\n\
         \n\
         1. Align this project's .env to match the running container, then re-run \
         `envio dev`.\n\
         \n\
         2. Remove the container (Hasura has no data volume — state lives in \
         Postgres):\n\
               docker rm -f {HASURA_CONTAINER}\n\
            Then re-run `envio dev`.\n\
         \n\
         3. From the owning project, run `envio stop`, then re-run `envio dev` here.\n\
         \n\
         (Hasura is configured on port {port}.)",
        owner = owner_line(drift)
    )
}

fn format_ch_drift(env: &EnvConfig, url: &ClickHouseUrl, drift: &DriftInfo) -> String {
    let mut diff = String::new();
    diff.push_str(&diff_field(
        "ENVIO_CLICKHOUSE_USERNAME",
        &env.ch_user,
        drift.env.get("CLICKHOUSE_USER"),
    ));
    diff.push_str(&diff_field(
        "ENVIO_CLICKHOUSE_DATABASE",
        &env.ch_database,
        drift.env.get("CLICKHOUSE_DB"),
    ));
    let pw_note = match drift.env.get("CLICKHOUSE_PASSWORD") {
        Some(v) if v == &env.ch_password => String::new(),
        _ => "    ENVIO_CLICKHOUSE_PASSWORD: differs from existing container\n".to_string(),
    };
    diff.push_str(&pw_note);
    if diff.is_empty() {
        diff.push_str("    (port or other field)\n");
    }

    format!(
        "Docker container {CH_CONTAINER} is already running but was created with a \
         different configuration.\n\
         \n\
         {owner}  Differences:\n\
         {diff}\
         \n\
         The CLI won't silently recreate it — the data volume \"{CH_VOLUME}\" is \
         shared across every project that uses envio-managed ClickHouse, and \
         recreating would drop the other project's tables.\n\
         \n\
         Choose one:\n\
         \n\
         1. Align this project's .env to match the running container, then re-run \
         `envio dev`.\n\
         \n\
         2. Remove the container and its data:\n\
               docker rm -f {CH_CONTAINER}\n\
               docker volume rm {CH_VOLUME}\n\
            Then re-run `envio dev`. (Any other project using this container will \
         lose its data.)\n\
         \n\
         3. From the owning project, run `envio stop`, then re-run `envio dev` here.\n\
         \n\
         (ClickHouse is configured on port {}.)",
        url.port,
        owner = owner_line(drift)
    )
}

fn format_pg_auth_error(env: &EnvConfig, port: u16, external: bool, err: &str) -> String {
    let source = if external {
        "ENVIO_PG_HOST is set"
    } else {
        "something is already listening on the default Postgres port and it isn't an envio-managed container"
    };
    let ext_fix = if external {
        "  - Verify ENVIO_PG_USER / ENVIO_PG_PASSWORD / ENVIO_PG_DATABASE match the \
         database you pointed ENVIO_PG_HOST at.\n  \
         - Unset ENVIO_PG_HOST to let the CLI start a local Docker container instead.\n"
    } else {
        "  - Update ENVIO_PG_USER / ENVIO_PG_PASSWORD / ENVIO_PG_DATABASE in .env to \
         match the running database.\n  \
         - Or stop the other process on this port and re-run so envio can start its \
         own container.\n"
    };
    format!(
        "Connected to Postgres at {host}:{port} ({source}), but authentication failed.\n\
         \n\
         Configured:\n\
             ENVIO_PG_USER={user}\n\
             ENVIO_PG_DATABASE={db}\n\
             (password hidden)\n\
         \n\
         Error: {err}\n\
         \n\
         Fix:\n{ext_fix}",
        host = env.pg_host_str(),
        user = env.pg_user,
        db = env.pg_database,
    )
}

fn format_ch_auth_error(env: &EnvConfig, url: &ClickHouseUrl, external: bool, err: &str) -> String {
    let source = if external {
        "ENVIO_CLICKHOUSE_HOST is set"
    } else {
        "something is already listening on the default ClickHouse port and it isn't an envio-managed container"
    };
    let ext_fix = if external {
        "  - Verify ENVIO_CLICKHOUSE_USERNAME / ENVIO_CLICKHOUSE_PASSWORD / \
         ENVIO_CLICKHOUSE_DATABASE match the server you pointed \
         ENVIO_CLICKHOUSE_HOST at.\n  \
         - Unset ENVIO_CLICKHOUSE_HOST to let the CLI start a local Docker container \
         instead.\n"
    } else {
        "  - Update ENVIO_CLICKHOUSE_USERNAME / ENVIO_CLICKHOUSE_PASSWORD / \
         ENVIO_CLICKHOUSE_DATABASE in .env to match the running server.\n  \
         - Or stop the other process on this port and re-run so envio can start its \
         own container.\n"
    };
    format!(
        "Connected to ClickHouse at {scheme}://{host}:{port} ({source}), but \
         authentication failed.\n\
         \n\
         Configured:\n\
             ENVIO_CLICKHOUSE_USERNAME={user}\n\
             ENVIO_CLICKHOUSE_DATABASE={db}\n\
             (password hidden)\n\
         \n\
         Error: {err}\n\
         \n\
         Fix:\n{ext_fix}",
        scheme = url.scheme,
        host = url.host,
        port = url.port,
        user = env.ch_user,
        db = env.ch_database,
    )
}

/// Ensure a managed container is created and running. Assumes the caller has
/// already run `detect_drift` — drift-handling is intentionally not inside
/// this function because the right remediation is service-specific and
/// silently stopping a container the user may still need is too destructive
/// to do without their confirmation.
async fn ensure_container(
    docker: &Docker,
    name: &str,
    host_port: u16,
    create_body: ContainerCreateBody,
) -> anyhow::Result<bool> {
    if container_exists(docker, name).await {
        if is_container_running(docker, name).await {
            return Ok(false);
        }
        start_container(docker, name, host_port).await?;
        println!("Started {name}");
        return Ok(false);
    }

    let options = CreateContainerOptionsBuilder::new().name(name).build();

    docker
        .create_container(Some(options), create_body)
        .await
        .with_context(|| format!("Failed creating container {name}"))?;

    if let Err(e) = start_container(docker, name, host_port).await {
        stop_and_remove(docker, name).await;
        return Err(e);
    }

    println!("Started {name}");
    Ok(true)
}

/// Caller-supplied parameters for `up()`. Bundles the project root (used to
/// locate `.env`) alongside feature flags like ClickHouse so that callers
/// only need to construct one value and the signature can grow without
/// touching every call site.
#[derive(Debug, Clone, Copy)]
pub struct UpOptions<'a> {
    pub project_root: &'a Path,
    /// The `name` field from config.yaml. Stored on managed containers so
    /// drift errors can name the owning indexer in human terms ("Owned by
    /// erc20-indexer") on top of the absolute path.
    pub indexer_name: &'a str,
    pub clickhouse: bool,
}

/// Return value from `up()` so callers know which services are active and
/// get any env vars the indexer subprocess must see (e.g. credentials for a
/// ClickHouse container we just booted).
pub struct UpResult {
    pub hasura_enabled: bool,
    pub clickhouse_enabled: bool,
    pub indexer_env: Vec<(String, String)>,
}

pub async fn up(opts: UpOptions<'_>) -> anyhow::Result<UpResult> {
    let env = EnvConfig::from_project(opts.project_root);
    let pg_host_port: u16 = env.pg_port.parse().with_context(|| {
        format!(
            "ENVIO_PG_PORT={:?} is not a valid port number. \
             Remove it from your .env / environment to use the default (5433).",
            env.pg_port
        )
    })?;
    let hasura_host_port: u16 = env.hasura_port.parse().with_context(|| {
        format!(
            "HASURA_EXTERNAL_PORT={:?} is not a valid port number. \
             Remove it from your .env / environment to use the default (8080).",
            env.hasura_port
        )
    })?;

    // Parse the ClickHouse URL only when the project actually opts into
    // ClickHouse — garbage in ENVIO_CLICKHOUSE_HOST shouldn't break users
    // who never turn ClickHouse on.
    let ch_url = if opts.clickhouse {
        Some(env.ch_url()?)
    } else {
        None
    };
    let ch_url_ref = ch_url.as_ref();
    let probe_client = build_probe_client();

    // Probe each service at the configured host. When external the env var
    // tells us where to look; when local the container publishes on 0.0.0.0
    // so "localhost" reaches it. Hasura is always our own container.
    let pg_probe_host = env.pg_host_str();
    let hasura_probe_host = "localhost";
    let pg_external = env.pg_is_external();
    let ch_external = env.ch_is_external();
    let (pg_alive, hasura_alive, ch_alive) = tokio::join!(
        is_service_reachable(pg_probe_host, pg_host_port),
        async {
            if !env.hasura_enabled {
                return false;
            }
            is_hasura_healthy(&probe_client, hasura_probe_host, hasura_host_port).await
        },
        async {
            match ch_url_ref {
                Some(u) => is_clickhouse_healthy(&probe_client, &u.scheme, &u.host, u.port).await,
                None => false,
            }
        }
    );

    // External + unreachable → bail with actionable guidance instead of
    // silently starting a Docker container the user didn't ask for.
    if pg_external && !pg_alive {
        anyhow::bail!(
            "Postgres is not reachable at {host}:{port} (from ENVIO_PG_HOST).\n\
             \n\
             Possible fixes:\n\
             - Verify the host is running and accepts connections on that port.\n\
             - Unset ENVIO_PG_HOST to let the CLI start a local Docker container instead.",
            host = env.pg_host_str(),
            port = pg_host_port
        );
    }
    if let Some(url) = ch_url_ref {
        if ch_external && !ch_alive {
            anyhow::bail!(
                "ClickHouse is not reachable at {scheme}://{host}:{port}/ping \
                 (from ENVIO_CLICKHOUSE_HOST={raw:?}).\n\
                 \n\
                 Possible fixes:\n\
                 - Verify ClickHouse is running and the /ping endpoint responds.\n\
                 - Check that the URL scheme, host, and port are correct.\n\
                 - Unset ENVIO_CLICKHOUSE_HOST to let the CLI start a local Docker container instead.",
                raw = env.ch_host_str(),
                scheme = url.scheme,
                host = url.host,
                port = url.port
            );
        }
    }

    let pg_hash = env.pg_config_hash();
    let hasura_hash = env.hasura_config_hash();
    let ch_hash = env.ch_config_hash();

    // Connect to Docker eagerly if the project might want us to touch any
    // container. We need the handle for the drift preflight below *before*
    // we know whether the pipelines will run, and the cost of a connect
    // probe is negligible compared to the clarity it unlocks.
    let might_manage = !pg_external || env.hasura_enabled || (opts.clickhouse && !ch_external);
    let docker: Option<Docker> = if might_manage {
        Some(connect_docker().await?)
    } else {
        None
    };

    // A service is "ours" when we'd normally manage it AND a container by
    // our well-known name already exists. Ownership decides the preflight
    // path: ours → drift check; not-ours-but-alive → auth probe.
    let (pg_ours, hasura_ours, ch_ours) = match docker.as_ref() {
        Some(d) => tokio::join!(
            async { !pg_external && container_exists(d, PG_CONTAINER).await },
            async { env.hasura_enabled && container_exists(d, HASURA_CONTAINER).await },
            async { opts.clickhouse && !ch_external && container_exists(d, CH_CONTAINER).await },
        ),
        None => (false, false, false),
    };

    // Drift preflight — halt with an actionable error before any pipeline
    // touches the container. Never auto-recreate: the data volume is shared
    // across projects and silently dropping another project's data is too
    // destructive to do without the user's confirmation.
    if let Some(d) = docker.as_ref() {
        if pg_ours {
            if let Some(drift) = detect_drift(d, PG_CONTAINER, &pg_hash).await {
                anyhow::bail!("{}", format_pg_drift(&env, pg_host_port, &drift));
            }
        }
        if hasura_ours {
            if let Some(drift) = detect_drift(d, HASURA_CONTAINER, &hasura_hash).await {
                anyhow::bail!("{}", format_hasura_drift(&env, hasura_host_port, &drift));
            }
        }
        if ch_ours {
            if let Some(drift) = detect_drift(d, CH_CONTAINER, &ch_hash).await {
                let url = ch_url_ref.expect("ch_ours implies ch_url_ref is Some");
                anyhow::bail!("{}", format_ch_drift(&env, url, &drift));
            }
        }
    }

    // Auth preflight for services we won't manage: external (ENVIO_*_HOST
    // set) or foreign (port is taken but the listener isn't our container).
    // Catches the "service is up but creds don't match" case that used to
    // surface only once the indexer subprocess failed to connect.
    if pg_alive && (pg_external || !pg_ours) {
        if let Err(e) = probe_pg_auth(
            pg_probe_host,
            pg_host_port,
            &env.pg_user,
            &env.pg_password,
            &env.pg_database,
        )
        .await
        {
            anyhow::bail!(
                "{}",
                format_pg_auth_error(&env, pg_host_port, pg_external, &e.to_string())
            );
        }
    }
    if let Some(url) = ch_url_ref {
        if ch_alive && (ch_external || !ch_ours) {
            if let Err(e) = probe_ch_auth(
                &probe_client,
                &url.scheme,
                &url.host,
                url.port,
                &env.ch_user,
                &env.ch_password,
            )
            .await
            {
                anyhow::bail!("{}", format_ch_auth_error(&env, url, ch_external, &e));
            }
        }
    }

    let need_pg = !pg_external && !pg_alive;
    let need_hasura = env.hasura_enabled && !hasura_alive;
    let need_ch = opts.clickhouse && !ch_external && !ch_alive;

    if pg_external {
        println!(
            "Using your Postgres at {}:{} (from ENVIO_PG_HOST)",
            env.pg_host_str(),
            pg_host_port
        );
    } else if pg_alive {
        println!("Using Postgres already running on port {pg_host_port}");
    }
    if env.hasura_enabled && hasura_alive {
        println!("Using Hasura already running on port {hasura_host_port}");
    }
    if !env.hasura_enabled {
        println!("Hasura disabled (ENVIO_HASURA=false)");
    }
    if let Some(url) = ch_url_ref {
        if ch_external {
            println!(
                "Using your ClickHouse at {} (from ENVIO_CLICKHOUSE_HOST)",
                env.ch_host_str()
            );
        } else if ch_alive {
            println!("Using ClickHouse already running on port {}", url.port);
        }
    }

    // Build the env vars we need to pass to the indexer subprocess. When
    // ClickHouse is selected, the runtime requires all four variables set —
    // we pass them unconditionally so that both the managed-container case
    // (runtime sees our container creds) and the external case (runtime
    // sees the user-provided URL as-is) work without the user having to
    // duplicate values into .env.
    let indexer_env = if opts.clickhouse {
        vec![
            (
                "ENVIO_CLICKHOUSE_HOST".to_string(),
                env.ch_host_str().to_string(),
            ),
            ("ENVIO_CLICKHOUSE_USERNAME".to_string(), env.ch_user.clone()),
            (
                "ENVIO_CLICKHOUSE_PASSWORD".to_string(),
                env.ch_password.clone(),
            ),
            (
                "ENVIO_CLICKHOUSE_DATABASE".to_string(),
                env.ch_database.clone(),
            ),
        ]
    } else {
        Vec::new()
    };

    // If all services are already running, nothing to do.
    if !need_pg && !need_hasura && !need_ch {
        return Ok(UpResult {
            hasura_enabled: env.hasura_enabled,
            clickhouse_enabled: opts.clickhouse,
            indexer_env,
        });
    }

    // At least one pipeline will run, and the preflight above already
    // opened a Docker handle (might_manage is true whenever any need_* is).
    let docker = docker.expect("need_* implies might_manage which implies Docker is connected");

    // Run full pipelines for each container in parallel:
    // pull image → create infra → ensure container.
    // Network is shared so both pipelines may race to create it; ensure_network
    // handles the "already exists" case, so the loser is a harmless no-op.
    let pg_pipeline = async {
        if !need_pg {
            return Ok::<(), anyhow::Error>(());
        }
        // Image pull, network, and volume are all independent.
        let (img_res, net_res, vol_res) = tokio::join!(
            ensure_image(&docker, POSTGRES_IMAGE),
            ensure_network(&docker, NETWORK),
            ensure_volume(&docker, VOLUME),
        );
        img_res?;
        net_res?;
        vol_res?;

        let pg_port_bindings = {
            let mut map = HashMap::new();
            map.insert(
                "5432/tcp".to_string(),
                Some(vec![PortBinding {
                    host_ip: Some("0.0.0.0".to_string()),
                    host_port: Some(env.pg_port.clone()),
                }]),
            );
            map
        };

        let pg_body = ContainerCreateBody {
            image: Some(POSTGRES_IMAGE.to_string()),
            labels: Some(make_labels(&pg_hash, opts.project_root, opts.indexer_name)),
            env: Some(vec![
                format!("POSTGRES_PASSWORD={}", env.pg_password),
                format!("POSTGRES_USER={}", env.pg_user),
                format!("POSTGRES_DB={}", env.pg_database),
            ]),
            host_config: Some(HostConfig {
                port_bindings: Some(pg_port_bindings),
                mounts: Some(vec![Mount {
                    target: Some("/var/lib/postgresql".to_string()),
                    source: Some(VOLUME.to_string()),
                    typ: Some(MountTypeEnum::VOLUME),
                    ..Default::default()
                }]),
                restart_policy: Some(RestartPolicy {
                    name: Some(RestartPolicyNameEnum::ALWAYS),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            networking_config: Some(make_networking_config(NETWORK)),
            ..Default::default()
        };

        ensure_container(&docker, PG_CONTAINER, pg_host_port, pg_body).await?;
        Ok(())
    };

    let hasura_pipeline = async {
        if !need_hasura {
            return Ok::<(), anyhow::Error>(());
        }
        // Image pull and network creation are independent.
        let (img_res, net_res) = tokio::join!(
            ensure_image(&docker, HASURA_IMAGE),
            ensure_network(&docker, NETWORK),
        );
        img_res?;
        net_res?;

        let hasura_port_bindings = {
            let mut map = HashMap::new();
            map.insert(
                "8080/tcp".to_string(),
                Some(vec![PortBinding {
                    host_ip: Some("0.0.0.0".to_string()),
                    host_port: Some(env.hasura_port.clone()),
                }]),
            );
            map
        };

        // When Postgres runs in our own container, Hasura reaches it via the
        // shared Docker network using the container name on the internal port.
        // When Postgres is externally-managed, point Hasura at the user-
        // supplied host/port — the user is responsible for ensuring that
        // address is routable from the Hasura container.
        let (db_host, db_port) = if pg_external {
            (env.pg_host_str(), pg_host_port)
        } else {
            (PG_CONTAINER, 5432u16)
        };
        let db_url = format!(
            "postgres://{}:{}@{}:{}/{}",
            env.pg_user, env.pg_password, db_host, db_port, env.pg_database
        );

        let hasura_body = ContainerCreateBody {
            image: Some(HASURA_IMAGE.to_string()),
            labels: Some(make_labels(
                &hasura_hash,
                opts.project_root,
                opts.indexer_name,
            )),
            user: Some("1001:1001".to_string()),
            env: Some(vec![
                format!("HASURA_GRAPHQL_DATABASE_URL={db_url}"),
                format!(
                    "HASURA_GRAPHQL_ENABLE_CONSOLE={}",
                    env.hasura_enable_console
                ),
                "HASURA_GRAPHQL_ENABLED_LOG_TYPES=startup, http-log, webhook-log, websocket-log, \
                 query-log"
                    .to_string(),
                "HASURA_GRAPHQL_NO_OF_RETRIES=10".to_string(),
                format!("HASURA_GRAPHQL_ADMIN_SECRET={}", env.hasura_admin_secret),
                "HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES=true".to_string(),
                "PORT=8080".to_string(),
                "HASURA_GRAPHQL_UNAUTHORIZED_ROLE=public".to_string(),
            ]),
            exposed_ports: Some(vec!["8080/tcp".to_string()]),
            healthcheck: Some(HealthConfig {
                test: Some(vec![
                    "CMD-SHELL".to_string(),
                    "timeout 1s bash -c ':> /dev/tcp/127.0.0.1/8080' || exit 1".to_string(),
                ]),
                interval: Some(5_000_000_000),
                timeout: Some(2_000_000_000),
                retries: Some(50),
                start_period: Some(5_000_000_000),
                start_interval: None,
            }),
            host_config: Some(HostConfig {
                port_bindings: Some(hasura_port_bindings),
                restart_policy: Some(RestartPolicy {
                    name: Some(RestartPolicyNameEnum::ALWAYS),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            networking_config: Some(make_networking_config(NETWORK)),
            ..Default::default()
        };

        ensure_container(&docker, HASURA_CONTAINER, hasura_host_port, hasura_body).await?;
        Ok(())
    };

    // ClickHouse pipeline — only entered when ch_url was parsed (opts.clickhouse),
    // so the `if let` always matches when need_ch is true. No expect() needed.
    let clickhouse_pipeline = async {
        let Some(url) = ch_url_ref else {
            return Ok::<(), anyhow::Error>(());
        };
        if !need_ch {
            return Ok(());
        }
        let (img_res, net_res, vol_res) = tokio::join!(
            ensure_image(&docker, CLICKHOUSE_IMAGE),
            ensure_network(&docker, NETWORK),
            ensure_volume(&docker, CH_VOLUME),
        );
        img_res?;
        net_res?;
        vol_res?;

        let ch_port_bindings = {
            let mut map = HashMap::new();
            map.insert(
                "8123/tcp".to_string(),
                Some(vec![PortBinding {
                    host_ip: Some("0.0.0.0".to_string()),
                    host_port: Some(url.port.to_string()),
                }]),
            );
            map
        };

        let ch_body = ContainerCreateBody {
            image: Some(CLICKHOUSE_IMAGE.to_string()),
            labels: Some(make_labels(&ch_hash, opts.project_root, opts.indexer_name)),
            env: Some(vec![
                format!("CLICKHOUSE_USER={}", env.ch_user),
                format!("CLICKHOUSE_PASSWORD={}", env.ch_password),
                format!("CLICKHOUSE_DB={}", env.ch_database),
            ]),
            host_config: Some(HostConfig {
                port_bindings: Some(ch_port_bindings),
                mounts: Some(vec![Mount {
                    target: Some("/var/lib/clickhouse".to_string()),
                    source: Some(CH_VOLUME.to_string()),
                    typ: Some(MountTypeEnum::VOLUME),
                    ..Default::default()
                }]),
                restart_policy: Some(RestartPolicy {
                    name: Some(RestartPolicyNameEnum::ALWAYS),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            networking_config: Some(make_networking_config(NETWORK)),
            ..Default::default()
        };

        ensure_container(&docker, CH_CONTAINER, url.port, ch_body).await?;
        Ok(())
    };

    let (pg_res, hasura_res, ch_res) =
        tokio::join!(pg_pipeline, hasura_pipeline, clickhouse_pipeline);
    pg_res?;
    hasura_res?;
    ch_res?;

    // Wait for services to become healthy before handing control back.
    let wait_pg = async {
        if !need_pg {
            return Ok::<(), anyhow::Error>(());
        }
        eprint!("Waiting for Postgres...");
        let start = std::time::Instant::now();
        loop {
            if is_service_reachable(pg_probe_host, pg_host_port).await {
                eprintln!(" ready ({:.1}s)", start.elapsed().as_secs_f64());
                return Ok(());
            }
            if start.elapsed() > Duration::from_secs(60) {
                eprintln!();
                anyhow::bail!(
                    "Postgres did not become reachable on port {pg_host_port} within 60 s.\n\
                     \n\
                     Try:\n\
                     - docker logs {PG_CONTAINER}\n\
                     - docker ps -a | grep {PG_CONTAINER}\n\
                     - Ensure nothing else is using port {pg_host_port}."
                );
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
            eprint!(".");
        }
    };

    let wait_hasura = async {
        if !need_hasura {
            return Ok::<(), anyhow::Error>(());
        }
        eprint!("Waiting for Hasura...");
        let start = std::time::Instant::now();
        loop {
            if is_hasura_healthy(&probe_client, hasura_probe_host, hasura_host_port).await {
                eprintln!(" ready ({:.1}s)", start.elapsed().as_secs_f64());
                return Ok(());
            }
            if start.elapsed() > Duration::from_secs(120) {
                eprintln!();
                anyhow::bail!(
                    "Hasura did not become healthy on port {hasura_host_port} within 120 s.\n\
                     \n\
                     Try:\n\
                     - docker logs {HASURA_CONTAINER}\n\
                     - Verify Postgres is running (Hasura depends on it).\n\
                     - Ensure nothing else is using port {hasura_host_port}."
                );
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
            eprint!(".");
        }
    };

    let wait_ch = async {
        let Some(url) = ch_url_ref else {
            return Ok::<(), anyhow::Error>(());
        };
        if !need_ch {
            return Ok(());
        }
        eprint!("Waiting for ClickHouse...");
        let start = std::time::Instant::now();
        loop {
            if is_clickhouse_healthy(&probe_client, &url.scheme, &url.host, url.port).await {
                eprintln!(" ready ({:.1}s)", start.elapsed().as_secs_f64());
                return Ok(());
            }
            if start.elapsed() > Duration::from_secs(60) {
                eprintln!();
                anyhow::bail!(
                    "ClickHouse did not become healthy on port {port} within 60 s.\n\
                     \n\
                     Try:\n\
                     - docker logs {CH_CONTAINER}\n\
                     - docker ps -a | grep {CH_CONTAINER}\n\
                     - Ensure nothing else is using port {port}.",
                    port = url.port
                );
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
            eprint!(".");
        }
    };

    tokio::try_join!(wait_pg, wait_hasura, wait_ch)?;

    Ok(UpResult {
        hasura_enabled: env.hasura_enabled,
        clickhouse_enabled: opts.clickhouse,
        indexer_env,
    })
}

pub async fn down() -> anyhow::Result<()> {
    let docker = connect_docker().await?;

    println!("Stopping containers...");

    tokio::join!(
        stop_and_remove(&docker, HASURA_CONTAINER),
        stop_and_remove(&docker, PG_CONTAINER),
        stop_and_remove(&docker, CH_CONTAINER),
    );

    // Volumes / network may not exist if the user never ran `up` or only
    // used a subset of services. Probe first so missing resources don't
    // produce spurious errors.
    let pg_vol_exists = docker.inspect_volume(VOLUME).await.is_ok();
    let ch_vol_exists = docker.inspect_volume(CH_VOLUME).await.is_ok();

    async fn remove_volume_if_exists(
        docker: &Docker,
        name: &str,
        exists: bool,
    ) -> anyhow::Result<()> {
        if exists {
            docker
                .remove_volume(name, None::<bollard::query_parameters::RemoveVolumeOptions>)
                .await
                .with_context(|| format!("Failed to remove volume {name}"))?;
        }
        Ok(())
    }

    // 404 = network already gone (e.g. `up()` short-circuited when all
    // services were reachable externally, so `ensure_network` never ran).
    // Treat it as success — mirrors the 409 tolerance in `ensure_network`.
    async fn remove_network_tolerant(docker: &Docker, name: &str) -> anyhow::Result<()> {
        match docker.remove_network(name).await {
            Ok(_) => Ok(()),
            Err(bollard::errors::Error::DockerResponseServerError {
                status_code: 404, ..
            }) => Ok(()),
            Err(e) => Err(e).with_context(|| format!("Failed to remove network {name}")),
        }
    }

    let (pg_vol_res, ch_vol_res, net_res) = tokio::join!(
        remove_volume_if_exists(&docker, VOLUME, pg_vol_exists),
        remove_volume_if_exists(&docker, CH_VOLUME, ch_vol_exists),
        remove_network_tolerant(&docker, NETWORK),
    );

    let mut failed = false;
    if let Err(e) = pg_vol_res {
        eprintln!("{e:#}");
        failed = true;
    }
    if let Err(e) = ch_vol_res {
        eprintln!("{e:#}");
        failed = true;
    }
    if let Err(e) = net_res {
        eprintln!("{e:#}");
        failed = true;
    }

    if failed {
        anyhow::bail!("Environment cleanup finished with errors (see above)");
    }

    println!("Environment cleaned up");

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_env() -> EnvConfig {
        EnvConfig {
            pg_host: None,
            pg_port: "5433".into(),
            pg_password: "testing".into(),
            pg_user: "postgres".into(),
            pg_database: "envio-dev".into(),
            hasura_enabled: true,
            hasura_port: "8080".into(),
            hasura_enable_console: "true".into(),
            hasura_admin_secret: "testing".into(),
            ch_host: None,
            ch_user: "default".into(),
            ch_password: "testing".into(),
            ch_database: "envio_sink".into(),
        }
    }

    #[test]
    fn per_service_hashes_are_deterministic() {
        let d = default_env();
        assert_eq!(
            (
                d.pg_config_hash(),
                d.hasura_config_hash(),
                d.ch_config_hash()
            ),
            (
                default_env().pg_config_hash(),
                default_env().hasura_config_hash(),
                default_env().ch_config_hash()
            )
        );
    }

    #[test]
    fn pg_hash_changes_on_pg_port() {
        let env2 = EnvConfig {
            pg_port: "5434".into(),
            ..default_env()
        };
        assert_ne!(default_env().pg_config_hash(), env2.pg_config_hash());
    }

    #[test]
    fn ch_hash_independent_from_pg() {
        // Changing a PG field must not change the ClickHouse hash.
        let env2 = EnvConfig {
            pg_password: "new_password".into(),
            ..default_env()
        };
        assert_eq!(default_env().ch_config_hash(), env2.ch_config_hash());
        assert_ne!(default_env().pg_config_hash(), env2.pg_config_hash());
    }

    #[test]
    fn hasura_hash_changes_on_pg_password() {
        // Hasura's DB URL embeds PG creds, so PG password change is drift.
        let env2 = EnvConfig {
            pg_password: "new_password".into(),
            ..default_env()
        };
        assert_ne!(
            default_env().hasura_config_hash(),
            env2.hasura_config_hash()
        );
    }

    #[test]
    fn pg_is_external_iff_env_var_set() {
        assert!(!default_env().pg_is_external());
        // Any value — even "localhost" — counts as external when explicitly set.
        let values = ["localhost", "127.0.0.1", "db.example.com"];
        let results: Vec<bool> = values
            .iter()
            .map(|h| {
                EnvConfig {
                    pg_host: Some((*h).into()),
                    ..default_env()
                }
                .pg_is_external()
            })
            .collect();
        assert_eq!(results, vec![true, true, true]);
    }

    #[test]
    fn pg_host_str_returns_default_when_unset() {
        assert_eq!(default_env().pg_host_str(), DEFAULT_PG_HOST);
        let ext = EnvConfig {
            pg_host: Some("db.example.com".into()),
            ..default_env()
        };
        assert_eq!(ext.pg_host_str(), "db.example.com");
    }

    #[test]
    fn ch_hash_changes_on_ch_password() {
        let env2 = EnvConfig {
            ch_password: "secret".into(),
            ..default_env()
        };
        assert_ne!(default_env().ch_config_hash(), env2.ch_config_hash());
    }

    #[test]
    fn ch_is_external_iff_env_var_set() {
        assert!(!default_env().ch_is_external());
        let values = [
            "http://localhost:8123",
            "http://127.0.0.1:8123",
            "https://ch.cloud.example.com",
        ];
        let results: Vec<bool> = values
            .iter()
            .map(|h| {
                EnvConfig {
                    ch_host: Some((*h).into()),
                    ..default_env()
                }
                .ch_is_external()
            })
            .collect();
        assert_eq!(results, vec![true, true, true]);
    }

    #[test]
    fn ch_host_str_returns_default_when_unset() {
        assert_eq!(default_env().ch_host_str(), DEFAULT_CH_URL);
        let ext = EnvConfig {
            ch_host: Some("http://10.0.0.5:9000".into()),
            ..default_env()
        };
        assert_eq!(ext.ch_host_str(), "http://10.0.0.5:9000");
    }

    #[test]
    fn ch_url_parses_host_port_scheme() {
        let cases = [
            ("http://localhost:8123", ("http", "localhost", 8123u16)),
            (
                "https://ch.example.com",
                ("https", "ch.example.com", 443u16),
            ),
            ("http://ch.example.com", ("http", "ch.example.com", 8123u16)),
            ("http://10.0.0.5:9000", ("http", "10.0.0.5", 9000u16)),
        ];
        let parsed: Vec<(String, String, u16)> = cases
            .iter()
            .map(|(raw, _)| {
                let u = ClickHouseUrl::parse(raw).unwrap();
                (u.scheme, u.host, u.port)
            })
            .collect();
        let expected: Vec<(String, String, u16)> = cases
            .iter()
            .map(|(_, (s, h, p))| ((*s).to_string(), (*h).to_string(), *p))
            .collect();
        assert_eq!(parsed, expected);
    }

    #[test]
    fn ch_url_rejects_invalid() {
        let cases = [
            "not-a-url",
            "ftp://ch.example.com",
            "http://",
            "clickhouse:8123",
        ];
        let results: Vec<bool> = cases
            .iter()
            .map(|raw| ClickHouseUrl::parse(raw).is_err())
            .collect();
        assert_eq!(results, vec![true, true, true, true]);
    }

    #[test]
    fn up_options_copies_values() {
        // Smoke test that UpOptions threads all fields and is Copy so
        // callers don't need to clone before passing in.
        let root = Path::new("/tmp/project");
        let a = UpOptions {
            project_root: root,
            indexer_name: "my-indexer",
            clickhouse: true,
        };
        let b = a;
        assert_eq!(
            (
                a.project_root,
                a.indexer_name,
                a.clickhouse,
                b.project_root,
                b.indexer_name,
                b.clickhouse
            ),
            (root, "my-indexer", true, root, "my-indexer", true)
        );
    }

    #[test]
    fn labels_record_config_hash_path_and_name() {
        // Path doesn't exist → canonicalize falls back to the raw input, so
        // the label reads exactly what was passed. Good enough for the shape
        // assertion; canonicalization itself has a separate test below.
        let labels = make_labels(
            "abc123",
            Path::new("/nonexistent/path/for-test"),
            "erc20-indexer",
        );
        assert_eq!(
            (
                labels.get(CONFIG_HASH_LABEL).map(String::as_str),
                labels.get(PROJECT_PATH_LABEL).map(String::as_str),
                labels.get(PROJECT_NAME_LABEL).map(String::as_str),
            ),
            (
                Some("abc123"),
                Some("/nonexistent/path/for-test"),
                Some("erc20-indexer"),
            )
        );
    }

    #[test]
    fn labels_canonicalize_project_path() {
        // Invocation-independent label: `envio dev` from within a project
        // with relative path "." must produce the same absolute path as
        // `envio dev -d /abs/path`. Otherwise two projects both end up
        // labeled "." and drift errors can't disambiguate them.
        let dir = tempdir::TempDir::new("envio-labels-test").expect("tempdir");
        let abs = dir.path().canonicalize().expect("canonicalize tempdir");
        // Enter the dir so "." resolves to it.
        let prev = std::env::current_dir().expect("cwd");
        std::env::set_current_dir(&abs).expect("chdir");
        let labels_dot = make_labels("h", Path::new("."), "x");
        std::env::set_current_dir(prev).expect("restore cwd");
        let labels_abs = make_labels("h", &abs, "x");
        assert_eq!(
            labels_dot.get(PROJECT_PATH_LABEL),
            labels_abs.get(PROJECT_PATH_LABEL)
        );
    }

    fn ch_drift_fixture(ch_user: &str, ch_db: &str, ch_password: &str) -> DriftInfo {
        let mut env = HashMap::new();
        env.insert("CLICKHOUSE_USER".to_string(), ch_user.to_string());
        env.insert("CLICKHOUSE_DB".to_string(), ch_db.to_string());
        env.insert("CLICKHOUSE_PASSWORD".to_string(), ch_password.to_string());
        DriftInfo {
            project_name: Some("other-indexer".to_string()),
            project_path: Some("/path/to/other-project".to_string()),
            env,
        }
    }

    #[test]
    fn ch_drift_error_is_actionable() {
        // Password mismatch → the error must point at password (without echoing
        // either value), name both projects (so the user sees whose data is at
        // stake), and include the docker rm command.
        let env = default_env();
        let url = ClickHouseUrl::parse("http://localhost:8123").unwrap();
        let drift = ch_drift_fixture("default", "envio_sink", "old-password");
        let msg = format_ch_drift(&env, &url, &drift);
        let checks = [
            msg.contains("envio-clickhouse"),
            msg.contains("/path/to/other-project"),
            msg.contains("ENVIO_CLICKHOUSE_PASSWORD: differs"),
            msg.contains("docker rm -f envio-clickhouse"),
            msg.contains("docker volume rm envio-clickhouse-data"),
            msg.contains("envio stop"),
            !msg.contains(&env.ch_password),
            !msg.contains("old-password"),
        ];
        assert_eq!(checks, [true; 8]);
    }

    #[test]
    fn ch_drift_error_shows_user_and_database_diffs() {
        // Username / database are not secrets, so both the wanted and existing
        // values are shown side-by-side for easy alignment.
        let env = default_env();
        let url = ClickHouseUrl::parse("http://localhost:8123").unwrap();
        let drift = ch_drift_fixture("analytics", "other_db", "testing");
        let msg = format_ch_drift(&env, &url, &drift);
        let checks = [
            msg.contains("ENVIO_CLICKHOUSE_USERNAME"),
            msg.contains("\"default\""),
            msg.contains("\"analytics\""),
            msg.contains("ENVIO_CLICKHOUSE_DATABASE"),
            msg.contains("\"envio_sink\""),
            msg.contains("\"other_db\""),
            // Password matches, so no password note.
            !msg.contains("ENVIO_CLICKHOUSE_PASSWORD: differs"),
        ];
        assert_eq!(checks, [true; 7]);
    }

    #[test]
    fn ch_drift_error_handles_missing_project_label() {
        // Containers created before the labels existed have neither name
        // nor path. The error still works — it just can't name the owner.
        let env = default_env();
        let url = ClickHouseUrl::parse("http://localhost:8123").unwrap();
        let drift = DriftInfo {
            project_name: None,
            project_path: None,
            env: HashMap::new(),
        };
        let msg = format_ch_drift(&env, &url, &drift);
        assert!(
            msg.contains("unknown (container predates the project labels)"),
            "missing-project case should say so, got: {msg}"
        );
    }

    #[test]
    fn owner_line_renders_name_and_path() {
        // Both labels present → name first, path in parens. This is the
        // primary case for containers created by current builds.
        let drift = DriftInfo {
            project_name: Some("erc20-indexer".to_string()),
            project_path: Some("/home/dmitry/projects/erc20".to_string()),
            env: HashMap::new(),
        };
        assert_eq!(
            owner_line(&drift),
            "  Owned by: erc20-indexer (/home/dmitry/projects/erc20)\n"
        );
    }

    #[test]
    fn owner_line_handles_partial_labels() {
        // One label missing (old container + partial upgrade) → render
        // whichever is present without an empty paren or "None" artifact.
        let name_only = DriftInfo {
            project_name: Some("foo".to_string()),
            project_path: None,
            env: HashMap::new(),
        };
        let path_only = DriftInfo {
            project_name: None,
            project_path: Some("/bar".to_string()),
            env: HashMap::new(),
        };
        assert_eq!(
            (owner_line(&name_only), owner_line(&path_only)),
            (
                "  Owned by: foo\n".to_string(),
                "  Owned by: /bar\n".to_string()
            )
        );
    }

    #[test]
    fn pg_drift_error_is_actionable() {
        let env = default_env();
        let mut ex = HashMap::new();
        ex.insert("POSTGRES_USER".to_string(), "postgres".to_string());
        ex.insert("POSTGRES_DB".to_string(), "other-db".to_string());
        ex.insert("POSTGRES_PASSWORD".to_string(), "other-pw".to_string());
        let drift = DriftInfo {
            project_name: Some("alice-indexer".to_string()),
            project_path: Some("/home/alice/other".to_string()),
            env: ex,
        };
        let msg = format_pg_drift(&env, 5433, &drift);
        let checks = [
            msg.contains("envio-postgres"),
            msg.contains("alice-indexer"),
            msg.contains("/home/alice/other"),
            msg.contains("ENVIO_PG_DATABASE"),
            msg.contains("\"envio-dev\""),
            msg.contains("\"other-db\""),
            msg.contains("ENVIO_PG_PASSWORD: differs"),
            msg.contains("docker rm -f envio-postgres"),
            msg.contains("docker volume rm envio-postgres-data"),
            !msg.contains("other-pw"),
            !msg.contains(&env.pg_password),
        ];
        assert_eq!(checks, [true; 11]);
    }

    #[test]
    fn pg_auth_error_external_vs_foreign_paths_differ() {
        let env = default_env();
        let external = format_pg_auth_error(&env, 5433, true, "password authentication failed");
        let foreign = format_pg_auth_error(&env, 5433, false, "password authentication failed");

        let external_checks = [
            external.contains("ENVIO_PG_HOST is set"),
            external.contains("Unset ENVIO_PG_HOST"),
            external.contains("password authentication failed"),
            external.contains("(password hidden)"),
            !external.contains(&env.pg_password),
        ];
        let foreign_checks = [
            foreign.contains("something is already listening"),
            foreign.contains("match the running database"),
            foreign.contains("password authentication failed"),
            !foreign.contains("ENVIO_PG_HOST is set"),
        ];
        assert_eq!((external_checks, foreign_checks), ([true; 5], [true; 4]));
    }

    #[test]
    fn ch_auth_error_external_vs_foreign_paths_differ() {
        let env = default_env();
        let url = ClickHouseUrl::parse("http://localhost:8123").unwrap();
        let external = format_ch_auth_error(&env, &url, true, "HTTP 516: auth failed");
        let foreign = format_ch_auth_error(&env, &url, false, "HTTP 516: auth failed");

        let external_checks = [
            external.contains("ENVIO_CLICKHOUSE_HOST is set"),
            external.contains("Unset ENVIO_CLICKHOUSE_HOST"),
            external.contains("HTTP 516"),
            !external.contains(&env.ch_password),
        ];
        let foreign_checks = [
            foreign.contains("something is already listening"),
            foreign.contains("match the running server"),
            !foreign.contains("ENVIO_CLICKHOUSE_HOST is set"),
        ];
        assert_eq!((external_checks, foreign_checks), ([true; 4], [true; 3]));
    }

    #[test]
    fn hasura_hash_changes_on_pg_external_toggle_and_port() {
        // HASURA_GRAPHQL_DATABASE_URL embeds the PG host and port, so both
        // flipping ENVIO_PG_HOST on/off and changing ENVIO_PG_PORT must
        // force a Hasura recreate. These used to silently slip past the
        // drift check, leaving Hasura pointed at the wrong DB.
        let base = default_env();
        let toggled = EnvConfig {
            pg_host: Some("localhost".into()),
            ..default_env()
        };
        let reported = EnvConfig {
            pg_port: "5434".into(),
            ..default_env()
        };
        assert_ne!(base.hasura_config_hash(), toggled.hasura_config_hash());
        assert_ne!(base.hasura_config_hash(), reported.hasura_config_hash());
    }

    fn hasura_drift_fixture(database_url: &str, admin_secret: &str) -> DriftInfo {
        let mut env = HashMap::new();
        env.insert(
            "HASURA_GRAPHQL_DATABASE_URL".to_string(),
            database_url.to_string(),
        );
        env.insert(
            "HASURA_GRAPHQL_ENABLE_CONSOLE".to_string(),
            "true".to_string(),
        );
        env.insert(
            "HASURA_GRAPHQL_ADMIN_SECRET".to_string(),
            admin_secret.to_string(),
        );
        DriftInfo {
            project_name: Some("alice-indexer".to_string()),
            project_path: Some("/home/alice/indexer".to_string()),
            env,
        }
    }

    #[test]
    fn hasura_drift_error_surfaces_embedded_pg_creds() {
        // Previously this formatter compared HASURA_EXTERNAL_PORT (host
        // binding) against the container's PORT env var (hardcoded 8080),
        // so every diff said "8080 (existing: 8080)". Now the PG creds
        // baked into DATABASE_URL are what get diffed.
        let env = default_env();
        let drift = hasura_drift_fixture(
            "postgres://postgres:old-pw@envio-postgres:5432/old-db",
            "testing",
        );
        let msg = format_hasura_drift(&env, 8080, &drift);
        let checks = [
            msg.contains("envio-hasura"),
            msg.contains("/home/alice/indexer"),
            msg.contains("ENVIO_PG_DATABASE"),
            msg.contains("\"envio-dev\""),
            msg.contains("\"old-db\""),
            msg.contains("ENVIO_PG_PASSWORD: differs"),
            !msg.contains("HASURA_EXTERNAL_PORT"),
            !msg.contains("old-pw"),
            !msg.contains(&env.pg_password),
            msg.contains("docker rm -f envio-hasura"),
        ];
        assert_eq!(checks, [true; 10]);
    }

    #[test]
    fn hasura_drift_error_flags_admin_secret_without_echoing() {
        let env = default_env();
        let drift = hasura_drift_fixture(
            "postgres://postgres:testing@envio-postgres:5432/envio-dev",
            "different-secret",
        );
        let msg = format_hasura_drift(&env, 8080, &drift);
        let checks = [
            msg.contains("HASURA_GRAPHQL_ADMIN_SECRET: differs"),
            !msg.contains("different-secret"),
            !msg.contains(&env.hasura_admin_secret),
            // PG creds match, so no PG password note.
            !msg.contains("ENVIO_PG_PASSWORD: differs"),
        ];
        assert_eq!(checks, [true; 4]);
    }

    #[test]
    fn hasura_drift_error_falls_back_when_only_port_binding_drifted() {
        // HASURA_EXTERNAL_PORT changes don't appear in the container env —
        // they live in port bindings. The formatter can't enumerate the
        // specific field; assert we at least don't claim something bogus.
        let env = default_env();
        let drift = hasura_drift_fixture(
            "postgres://postgres:testing@envio-postgres:5432/envio-dev",
            "testing",
        );
        let msg = format_hasura_drift(&env, 8080, &drift);
        assert!(
            msg.contains("port binding or other configuration field"),
            "no-visible-diff case should use the fallback, got: {msg}"
        );
    }
}
