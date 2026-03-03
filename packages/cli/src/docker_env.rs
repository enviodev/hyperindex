use crate::config_parsing::human_config::Storage;
use anyhow::Context;
use bollard::models::{
    ContainerCreateBody, EndpointSettings, HealthConfig, HostConfig, Mount, MountTypeEnum,
    NetworkCreateRequest, NetworkingConfig, PortBinding, RestartPolicy, RestartPolicyNameEnum,
    VolumeCreateRequest,
};
use bollard::query_parameters::{
    CreateContainerOptionsBuilder, CreateImageOptionsBuilder, ListContainersOptionsBuilder,
    LogsOptionsBuilder, RemoveContainerOptionsBuilder, StopContainerOptionsBuilder,
};
use bollard::{Docker, API_DEFAULT_VERSION};
use dotenvy::{EnvLoader, EnvMap, EnvSequence};
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::net::TcpStream;
use tokio::time::Duration;

const POSTGRES_IMAGE: &str = "postgres:18.3";
const HASURA_IMAGE: &str = "hasura/graphql-engine:v2.43.0";
const CLICKHOUSE_IMAGE: &str = "clickhouse:26.1.3";
const CLICKHOUSE_CONNECTOR_IMAGE: &str = "hasura/clickhouse-data-connector:v2.43.0";
const CONFIG_HASH_LABEL: &str = "dev.envio.config-hash";
const SOCKET_TIMEOUT: u64 = 120;

const PG_CONTAINER: &str = "envio-postgres";
const HASURA_CONTAINER: &str = "envio-hasura";
const CLICKHOUSE_CONTAINER: &str = "envio-clickhouse";
const CLICKHOUSE_CONNECTOR_CONTAINER: &str = "envio-clickhouse-connector";
const VOLUME: &str = "envio-postgres-data";
const CLICKHOUSE_VOLUME: &str = "envio-clickhouse-data";
const NETWORK: &str = "envio-network";

fn podman_socket_candidates() -> Vec<PathBuf> {
    let mut paths = Vec::new();

    // Rootless: $XDG_RUNTIME_DIR/podman/podman.sock
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        paths.push(PathBuf::from(xdg).join("podman/podman.sock"));
    }

    // macOS Podman machine
    if let Ok(home) = std::env::var("HOME") {
        paths.push(
            PathBuf::from(&home).join(".local/share/containers/podman/machine/podman.sock"),
        );
        paths.push(
            PathBuf::from(&home)
                .join(".local/share/containers/podman/machine/qemu/podman.sock"),
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

/// Connect to Docker or Podman, trying multiple strategies:
/// 1. `DOCKER_HOST` / default Docker socket
/// 2. `CONTAINER_HOST` (Podman convention)
/// 3. Common Podman socket paths
async fn connect_docker() -> anyhow::Result<Docker> {
    // Try Docker defaults (respects DOCKER_HOST env var)
    if let Ok(docker) = Docker::connect_with_local_defaults() {
        if docker.ping().await.is_ok() {
            return Ok(docker);
        }
    }

    // Try CONTAINER_HOST (Podman's equivalent of DOCKER_HOST)
    if let Ok(host) = std::env::var("CONTAINER_HOST") {
        let path = socket_path_from_uri(&host);
        if let Ok(docker) =
            Docker::connect_with_socket(path, SOCKET_TIMEOUT, API_DEFAULT_VERSION)
        {
            if docker.ping().await.is_ok() {
                return Ok(docker);
            }
        }
    }

    // Try common Podman socket paths
    for path in podman_socket_candidates() {
        if path.exists() {
            if let Some(path_str) = path.to_str() {
                if let Ok(docker) =
                    Docker::connect_with_socket(path_str, SOCKET_TIMEOUT, API_DEFAULT_VERSION)
                {
                    if docker.ping().await.is_ok() {
                        return Ok(docker);
                    }
                }
            }
        }
    }

    anyhow::bail!(
        "Failed connecting to Docker or Podman. Is the daemon running?\n\
         Checked: DOCKER_HOST, default Docker socket, CONTAINER_HOST, common Podman sockets."
    )
}

struct EnvConfig {
    pg_host: String,
    pg_port: String,
    pg_password: String,
    pg_user: String,
    pg_database: String,
    hasura_enabled: bool,
    hasura_port: String,
    hasura_enable_console: String,
    hasura_admin_secret: String,
    clickhouse_port: String,
    clickhouse_user: String,
    clickhouse_password: String,
    clickhouse_database: String,
    clickhouse_connector_port: String,
}

impl EnvConfig {
    fn from_project(project_root: &Path, indexer_name: &str) -> Self {
        let dotenv = EnvLoader::with_path(project_root.join(".env"))
            .sequence(EnvSequence::InputOnly)
            .load()
            .ok();

        let var = |name: &str, default: &str| -> String {
            std::env::var(name).unwrap_or_else(|_| {
                dotenv
                    .as_ref()
                    .and_then(|m: &EnvMap| m.var(name).ok())
                    .unwrap_or_else(|| default.to_string())
            })
        };

        let ch_database_default = format!("envio_{}", sanitize_for_db_name(indexer_name));

        Self {
            pg_host: var("ENVIO_PG_HOST", "localhost"),
            pg_port: var("ENVIO_PG_PORT", "5433"),
            pg_password: var("ENVIO_PG_PASSWORD", "testing"),
            pg_user: var("ENVIO_PG_USER", "postgres"),
            pg_database: var("ENVIO_PG_DATABASE", "envio-dev"),
            hasura_enabled: var("ENVIO_HASURA", "true") != "false",
            hasura_port: var("HASURA_EXTERNAL_PORT", "8080"),
            hasura_enable_console: var("HASURA_GRAPHQL_ENABLE_CONSOLE", "true"),
            hasura_admin_secret: var("HASURA_GRAPHQL_ADMIN_SECRET", "testing"),
            clickhouse_port: var("ENVIO_CLICKHOUSE_PORT", "8123"),
            clickhouse_user: var("ENVIO_CLICKHOUSE_USERNAME", "default"),
            clickhouse_password: var("ENVIO_CLICKHOUSE_PASSWORD", ""),
            clickhouse_database: var("ENVIO_CLICKHOUSE_DATABASE", &ch_database_default),
            clickhouse_connector_port: var("ENVIO_CLICKHOUSE_CONNECTOR_PORT", "8081"),
        }
    }

    /// Deterministic hash of all config values used to detect drift.
    fn config_hash(&self) -> String {
        let mut hasher = Sha256::new();
        hasher.update(&self.pg_port);
        hasher.update(&self.pg_password);
        hasher.update(&self.pg_user);
        hasher.update(&self.pg_database);
        hasher.update(&self.hasura_port);
        hasher.update(&self.hasura_enable_console);
        hasher.update(&self.hasura_admin_secret);
        hasher.update(&self.clickhouse_port);
        hasher.update(&self.clickhouse_user);
        hasher.update(&self.clickhouse_password);
        hasher.update(&self.clickhouse_database);
        hasher.update(&self.clickhouse_connector_port);
        // Bump this version when container create configs change to force
        // recreation of existing containers with stale settings.
        hasher.update("config_v2");
        format!("{:x}", hasher.finalize())
    }
}

async fn ensure_image(docker: &Docker, image: &str) -> anyhow::Result<()> {
    if docker.inspect_image(image).await.is_ok() {
        return Ok(());
    }

    println!("Pulling image {image}...");
    let (repo, tag) = image.rsplit_once(':').unwrap_or((image, "latest"));

    let options = CreateImageOptionsBuilder::new()
        .from_image(repo)
        .tag(tag)
        .build();

    let mut stream = docker.create_image(Some(options), None, None);
    while let Some(result) = stream.next().await {
        let info = result.with_context(|| format!("Failed pulling image {image}"))?;
        if let (Some(status), id) = (info.status, &info.id) {
            match id {
                Some(id) => eprint!("\r  {id}: {status}  "),
                None => eprint!("\r  {status}  "),
            }
        }
    }
    eprintln!();
    println!("Pulled {image}");

    Ok(())
}

async fn ensure_network(docker: &Docker, name: &str) -> anyhow::Result<()> {
    // Fast path: if the network already exists, skip creation entirely.
    if docker
        .inspect_network(name, None::<bollard::query_parameters::InspectNetworkOptions>)
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

/// Returns the config-hash label from a running container, if it exists.
async fn get_container_config_hash(docker: &Docker, name: &str) -> Option<String> {
    docker
        .inspect_container(name, None)
        .await
        .ok()
        .and_then(|info| info.config)
        .and_then(|cfg| cfg.labels)
        .and_then(|labels| labels.get(CONFIG_HASH_LABEL).cloned())
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

/// Check whether an HTTP endpoint returns a success status.
async fn is_http_healthy(url: &str) -> bool {
    try_http_healthy(url).await.unwrap_or(false)
}

/// Try an HTTP GET and return Ok(true) if 2xx, Ok(false) if non-2xx, or the
/// reqwest error so callers can log the reason (connection refused, timeout, …).
async fn try_http_healthy(url: &str) -> Result<bool, reqwest::Error> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()?;
    let resp = client.get(url).send().await?;
    Ok(resp.status().is_success())
}

/// Poll an HTTP endpoint until it returns a success status.
async fn wait_for_http_healthy(url: &str, service_name: &str) -> anyhow::Result<()> {
    let max_attempts = 30;
    let interval = Duration::from_secs(2);
    for attempt in 1..=max_attempts {
        match try_http_healthy(url).await {
            Ok(true) => return Ok(()),
            Ok(false) => {
                println!(
                    "Waiting for {service_name} to become ready ({attempt}/{max_attempts}) \
                     [non-success status]..."
                );
            }
            Err(e) => {
                // Show the actual error every 5th attempt to aid debugging
                // without flooding the output.
                if attempt % 5 == 1 || attempt == max_attempts {
                    println!(
                        "Waiting for {service_name} to become ready ({attempt}/{max_attempts}) \
                         [{e}]..."
                    );
                } else {
                    println!(
                        "Waiting for {service_name} to become ready ({attempt}/{max_attempts})..."
                    );
                }
            }
        }
        if attempt < max_attempts {
            tokio::time::sleep(interval).await;
        }
    }
    anyhow::bail!("{service_name} did not become healthy after {max_attempts} attempts at {url}")
}

/// Sanitize an indexer name into a valid ClickHouse database identifier.
/// Replaces non-alphanumeric characters with underscores and ensures it
/// doesn't start with a digit.
fn sanitize_for_db_name(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
        .collect();
    // Ensure it doesn't start with a digit
    if sanitized.starts_with(|c: char| c.is_ascii_digit()) {
        format!("_{sanitized}")
    } else if sanitized.is_empty() {
        "indexer".to_string()
    } else {
        sanitized
    }
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

fn make_labels(config_hash: &str) -> HashMap<String, String> {
    let mut labels = HashMap::new();
    labels.insert(CONFIG_HASH_LABEL.to_string(), config_hash.to_string());
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
async fn start_container(
    docker: &Docker,
    name: &str,
    host_port: u16,
) -> anyhow::Result<()> {
    if let Err(e) = docker.start_container(name, None).await {
        if let Some(port_err) = port_conflict_error(docker, name, host_port, &e).await {
            return Err(port_err);
        }
        return Err(e).with_context(|| format!("Failed starting container {name}"));
    }
    Ok(())
}

/// Ensure a container is running with the expected config. Returns true if a
/// fresh container was created, false if an existing one was reused.
async fn ensure_container(
    docker: &Docker,
    name: &str,
    config_hash: &str,
    host_port: u16,
    create_body: ContainerCreateBody,
) -> anyhow::Result<bool> {
    if container_exists(docker, name).await {
        let existing_hash = get_container_config_hash(docker, name).await;
        let drift = existing_hash.as_deref() != Some(config_hash);

        if drift {
            println!("Configuration changed for {name}, recreating...");
            stop_and_remove(docker, name).await;
        } else if is_container_running(docker, name).await {
            return Ok(false);
        } else {
            start_container(docker, name, host_port).await?;
            println!("Started {name}");
            return Ok(false);
        }
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

/// Fetch the last N lines of container logs for diagnostics.
async fn get_container_logs(docker: &Docker, name: &str, tail: usize) -> String {
    let options = LogsOptionsBuilder::default()
        .stdout(true)
        .stderr(true)
        .tail(tail.to_string().as_str())
        .build();

    let mut stream = docker.logs(name, Some(options));
    let mut output = String::new();
    while let Some(Ok(chunk)) = stream.next().await {
        output.push_str(&chunk.to_string());
    }
    output
}

/// Return value from `up()` so callers know whether Hasura is active.
pub struct UpResult {
    pub hasura_enabled: bool,
}

pub async fn up(project_root: &Path, storage: &Storage, indexer_name: &str) -> anyhow::Result<UpResult> {
    let env = EnvConfig::from_project(project_root, indexer_name);
    let use_clickhouse = matches!(storage, Storage::Clickhouse);
    let pg_host_port: u16 = env.pg_port.parse().context("ENVIO_PG_PORT is not a valid port")?;
    let hasura_host_port: u16 = env
        .hasura_port
        .parse()
        .context("HASURA_EXTERNAL_PORT is not a valid port")?;
    let ch_host_port: u16 = env
        .clickhouse_port
        .parse()
        .context("ENVIO_CLICKHOUSE_PORT is not a valid port")?;
    let ch_connector_host_port: u16 = env
        .clickhouse_connector_port
        .parse()
        .context("ENVIO_CLICKHOUSE_CONNECTOR_PORT is not a valid port")?;

    // ClickHouse connector agent is needed when both ClickHouse storage and Hasura are enabled
    let use_ch_connector = use_clickhouse && env.hasura_enabled;

    // Probe services in parallel to see if they are already running.
    let pg_host = env.pg_host.clone();
    let (pg_alive, hasura_alive, ch_alive, ch_connector_alive) = tokio::join!(
        is_service_reachable(&pg_host, pg_host_port),
        async {
            if !env.hasura_enabled {
                return false;
            }
            let url = format!("http://{}:{}/hasura/healthz?strict=true", pg_host, hasura_host_port);
            is_http_healthy(&url).await
        },
        async {
            if !use_clickhouse {
                return false;
            }
            let url = format!("http://{}:{}/ping", pg_host, ch_host_port);
            is_http_healthy(&url).await
        },
        async {
            if !use_ch_connector {
                return false;
            }
            let url = format!("http://{}:{}/health", pg_host, ch_connector_host_port);
            is_http_healthy(&url).await
        }
    );

    let need_pg = !pg_alive;
    let need_hasura = env.hasura_enabled && !hasura_alive;
    let need_clickhouse = use_clickhouse && !ch_alive;
    let need_ch_connector = use_ch_connector && !ch_connector_alive;

    if pg_alive {
        println!("Postgres already reachable on port {pg_host_port}, skipping container");
    }
    if env.hasura_enabled && hasura_alive {
        println!("Hasura already healthy on port {hasura_host_port}, skipping container");
    }
    if !env.hasura_enabled {
        println!("Hasura disabled (ENVIO_HASURA=false), skipping");
    }
    if use_clickhouse && ch_alive {
        println!("ClickHouse already reachable on port {ch_host_port}, skipping container");
    }
    if use_ch_connector && ch_connector_alive {
        println!("ClickHouse connector already healthy on port {ch_connector_host_port}, skipping container");
    }

    // If all needed services are already running, nothing to do.
    if !need_pg && !need_hasura && !need_clickhouse && !need_ch_connector {
        return Ok(UpResult {
            hasura_enabled: env.hasura_enabled,
        });
    }

    // We need Docker for at least one container.
    let docker = connect_docker().await?;
    let config_hash = env.config_hash();

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
            labels: Some(make_labels(&config_hash)),
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

        ensure_container(&docker, PG_CONTAINER, &config_hash, pg_host_port, pg_body).await?;
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

        let db_url = format!(
            "postgres://{}:{}@{}:5432/{}",
            env.pg_user, env.pg_password, PG_CONTAINER, env.pg_database
        );

        let mut hasura_env = vec![
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
        ];

        // When ClickHouse storage is used, register the ClickHouse data connector agent
        // so Hasura can expose ClickHouse views via GraphQL
        if use_clickhouse {
            hasura_env.push(format!(
                r#"HASURA_GRAPHQL_METADATA_DEFAULTS={{"backend_configs":{{"dataconnector":{{"clickhouse":{{"uri":"http://{}:8080"}}}}}}}}"#,
                CLICKHOUSE_CONNECTOR_CONTAINER
            ));
        }

        let hasura_body = ContainerCreateBody {
            image: Some(HASURA_IMAGE.to_string()),
            labels: Some(make_labels(&config_hash)),
            user: Some("1001:1001".to_string()),
            env: Some(hasura_env),
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

        ensure_container(
            &docker,
            HASURA_CONTAINER,
            &config_hash,
            hasura_host_port,
            hasura_body,
        )
        .await?;
        Ok(())
    };

    let clickhouse_pipeline = async {
        if !need_clickhouse {
            return Ok::<(), anyhow::Error>(());
        }
        // Image pull, network, and volume are all independent.
        let (img_res, net_res, vol_res) = tokio::join!(
            ensure_image(&docker, CLICKHOUSE_IMAGE),
            ensure_network(&docker, NETWORK),
            ensure_volume(&docker, CLICKHOUSE_VOLUME),
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
                    host_port: Some(env.clickhouse_port.clone()),
                }]),
            );
            map
        };

        let mut ch_env = vec![
            format!("CLICKHOUSE_DB={}", env.clickhouse_database),
            format!("CLICKHOUSE_USER={}", env.clickhouse_user),
        ];
        if !env.clickhouse_password.is_empty() {
            ch_env.push(format!("CLICKHOUSE_PASSWORD={}", env.clickhouse_password));
        } else {
            ch_env.push("CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1".to_string());
        }

        let ch_body = ContainerCreateBody {
            image: Some(CLICKHOUSE_IMAGE.to_string()),
            labels: Some(make_labels(&config_hash)),
            env: Some(ch_env),
            host_config: Some(HostConfig {
                port_bindings: Some(ch_port_bindings),
                mounts: Some(vec![Mount {
                    target: Some("/var/lib/clickhouse".to_string()),
                    source: Some(CLICKHOUSE_VOLUME.to_string()),
                    typ: Some(MountTypeEnum::VOLUME),
                    ..Default::default()
                }]),
                restart_policy: Some(RestartPolicy {
                    name: Some(RestartPolicyNameEnum::ALWAYS),
                    ..Default::default()
                }),
                // ClickHouse needs ulimits for production-like performance
                ulimits: Some(vec![
                    bollard::models::ResourcesUlimits {
                        name: Some("nofile".to_string()),
                        soft: Some(262144),
                        hard: Some(262144),
                    },
                ]),
                ..Default::default()
            }),
            networking_config: Some(make_networking_config(NETWORK)),
            ..Default::default()
        };

        ensure_container(&docker, CLICKHOUSE_CONTAINER, &config_hash, ch_host_port, ch_body)
            .await?;

        // Wait for ClickHouse HTTP interface to become healthy
        let ping_url = format!("http://localhost:{}/ping", env.clickhouse_port);
        wait_for_http_healthy(&ping_url, "ClickHouse").await?;
        Ok(())
    };

    let ch_connector_pipeline = async {
        if !need_ch_connector {
            return Ok::<(), anyhow::Error>(());
        }
        let (img_res, net_res) = tokio::join!(
            ensure_image(&docker, CLICKHOUSE_CONNECTOR_IMAGE),
            ensure_network(&docker, NETWORK),
        );
        img_res?;
        net_res?;

        let connector_port_bindings = {
            let mut map = HashMap::new();
            map.insert(
                "8080/tcp".to_string(),
                Some(vec![PortBinding {
                    host_ip: Some("0.0.0.0".to_string()),
                    host_port: Some(env.clickhouse_connector_port.clone()),
                }]),
            );
            map
        };

        let connector_body = ContainerCreateBody {
            image: Some(CLICKHOUSE_CONNECTOR_IMAGE.to_string()),
            labels: Some(make_labels(&config_hash)),
            // The connector image lacks an EXPOSE directive, so we must
            // declare the port here for Docker to honour the port binding.
            exposed_ports: Some(vec!["8080/tcp".to_string()]),
            // No Docker healthcheck: the connector image is a minimal Alpine/scratch
            // build without bash or curl. We poll /health from the host instead.
            host_config: Some(HostConfig {
                port_bindings: Some(connector_port_bindings),
                restart_policy: Some(RestartPolicy {
                    name: Some(RestartPolicyNameEnum::ALWAYS),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            networking_config: Some(make_networking_config(NETWORK)),
            ..Default::default()
        };

        ensure_container(
            &docker,
            CLICKHOUSE_CONNECTOR_CONTAINER,
            &config_hash,
            ch_connector_host_port,
            connector_body,
        )
        .await?;

        // Brief pause to let the container start, then verify it's still running.
        // The connector is a statically-linked Rust binary that starts in <1s,
        // so if it's already exited, something is fundamentally wrong.
        tokio::time::sleep(Duration::from_secs(2)).await;
        if !is_container_running(&docker, CLICKHOUSE_CONNECTOR_CONTAINER).await {
            let logs = get_container_logs(&docker, CLICKHOUSE_CONNECTOR_CONTAINER, 30).await;
            anyhow::bail!(
                "Container {CLICKHOUSE_CONNECTOR_CONTAINER} exited immediately after starting.\n\
                 Image: {CLICKHOUSE_CONNECTOR_IMAGE}\n\
                 Logs:\n{logs}\n\
                 Run: docker logs {CLICKHOUSE_CONNECTOR_CONTAINER}"
            );
        }

        // Wait for connector agent health endpoint
        let health_url = format!(
            "http://localhost:{}/health",
            env.clickhouse_connector_port
        );
        wait_for_http_healthy(&health_url, "ClickHouse connector agent").await?;
        Ok(())
    };

    let (pg_res, hasura_res, ch_res, ch_connector_res) =
        tokio::join!(pg_pipeline, hasura_pipeline, clickhouse_pipeline, ch_connector_pipeline);
    pg_res?;
    hasura_res?;
    ch_res?;
    ch_connector_res?;

    Ok(UpResult {
        hasura_enabled: env.hasura_enabled,
    })
}

pub async fn down() -> anyhow::Result<()> {
    let docker = connect_docker().await?;

    println!("Stopping containers...");

    tokio::join!(
        stop_and_remove(&docker, HASURA_CONTAINER),
        stop_and_remove(&docker, PG_CONTAINER),
        stop_and_remove(&docker, CLICKHOUSE_CONTAINER),
        stop_and_remove(&docker, CLICKHOUSE_CONNECTOR_CONTAINER),
    );

    let (vol_res, ch_vol_res, net_res) = tokio::join!(
        docker.remove_volume(VOLUME, None::<bollard::query_parameters::RemoveVolumeOptions>),
        docker.remove_volume(
            CLICKHOUSE_VOLUME,
            None::<bollard::query_parameters::RemoveVolumeOptions>
        ),
        docker.remove_network(NETWORK),
    );

    let mut failed = false;
    if let Err(e) = vol_res {
        eprintln!("Failed to remove volume {VOLUME}: {e}");
        failed = true;
    }
    if let Err(e) = ch_vol_res {
        // Only warn if the volume existed (not an error if it was never created)
        let msg = e.to_string();
        if !msg.contains("No such volume") && !msg.contains("not found") {
            eprintln!("Failed to remove volume {CLICKHOUSE_VOLUME}: {e}");
            failed = true;
        }
    }
    if let Err(e) = net_res {
        eprintln!("Failed to remove network {NETWORK}: {e}");
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

    #[test]
    fn config_hash_deterministic() {
        let env1 = EnvConfig {
            pg_host: "localhost".into(),
            pg_port: "5433".into(),
            pg_password: "testing".into(),
            pg_user: "postgres".into(),
            pg_database: "envio-dev".into(),
            hasura_enabled: true,
            hasura_port: "8080".into(),
            hasura_enable_console: "true".into(),
            hasura_admin_secret: "testing".into(),
            clickhouse_port: "8123".into(),
            clickhouse_user: "default".into(),
            clickhouse_password: "".into(),
            clickhouse_database: "envio".into(),
            clickhouse_connector_port: "8081".into(),
        };
        let env2 = EnvConfig {
            pg_host: "localhost".into(),
            pg_port: "5433".into(),
            pg_password: "testing".into(),
            pg_user: "postgres".into(),
            pg_database: "envio-dev".into(),
            hasura_enabled: true,
            hasura_port: "8080".into(),
            hasura_enable_console: "true".into(),
            hasura_admin_secret: "testing".into(),
            clickhouse_port: "8123".into(),
            clickhouse_user: "default".into(),
            clickhouse_password: "".into(),
            clickhouse_database: "envio".into(),
            clickhouse_connector_port: "8081".into(),
        };
        assert_eq!(env1.config_hash(), env2.config_hash());
    }

    #[test]
    fn config_hash_changes_on_diff() {
        let env1 = EnvConfig {
            pg_host: "localhost".into(),
            pg_port: "5433".into(),
            pg_password: "testing".into(),
            pg_user: "postgres".into(),
            pg_database: "envio-dev".into(),
            hasura_enabled: true,
            hasura_port: "8080".into(),
            hasura_enable_console: "true".into(),
            hasura_admin_secret: "testing".into(),
            clickhouse_port: "8123".into(),
            clickhouse_user: "default".into(),
            clickhouse_password: "".into(),
            clickhouse_database: "envio".into(),
            clickhouse_connector_port: "8081".into(),
        };
        let env2 = EnvConfig {
            pg_host: "localhost".into(),
            pg_port: "5434".into(),
            pg_password: "testing".into(),
            pg_user: "postgres".into(),
            pg_database: "envio-dev".into(),
            hasura_enabled: true,
            hasura_port: "8080".into(),
            hasura_enable_console: "true".into(),
            hasura_admin_secret: "testing".into(),
            clickhouse_port: "8123".into(),
            clickhouse_user: "default".into(),
            clickhouse_password: "".into(),
            clickhouse_database: "envio".into(),
            clickhouse_connector_port: "8081".into(),
        };
        assert_ne!(env1.config_hash(), env2.config_hash());
    }

    #[test]
    fn sanitize_simple_name() {
        assert_eq!(sanitize_for_db_name("my_indexer"), "my_indexer");
    }

    #[test]
    fn sanitize_dashes_and_spaces() {
        assert_eq!(sanitize_for_db_name("my-cool indexer"), "my_cool_indexer");
    }

    #[test]
    fn sanitize_special_chars() {
        assert_eq!(sanitize_for_db_name("app@v2.0!"), "app_v2_0_");
    }

    #[test]
    fn sanitize_leading_digit() {
        assert_eq!(sanitize_for_db_name("123abc"), "_123abc");
    }

    #[test]
    fn sanitize_empty() {
        assert_eq!(sanitize_for_db_name(""), "indexer");
    }
}
