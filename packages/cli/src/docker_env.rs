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
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::net::TcpStream;
use tokio::time::Duration;

const POSTGRES_IMAGE: &str = "postgres:18.3";
const HASURA_IMAGE: &str = "hasura/graphql-engine:v2.43.0";
const CONFIG_HASH_LABEL: &str = "dev.envio.config-hash";
const SOCKET_TIMEOUT: u64 = 120;

const PG_CONTAINER: &str = "envio-postgres";
const HASURA_CONTAINER: &str = "envio-hasura";
const VOLUME: &str = "envio-postgres-data";
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
}

impl EnvConfig {
    fn from_project(project_root: &Path) -> Self {
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
        format!("{:x}", hasher.finalize())
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

/// Check whether Hasura is reachable by hitting its healthz endpoint.
async fn is_hasura_healthy(host: &str, port: u16) -> bool {
    let url = format!("http://{}:{}/hasura/healthz?strict=true", host, port);
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build();
    match client {
        Ok(c) => c
            .get(&url)
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false),
        Err(_) => false,
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
async fn start_container(docker: &Docker, name: &str, host_port: u16) -> anyhow::Result<()> {
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

/// Return value from `up()` so callers know whether Hasura is active.
pub struct UpResult {
    pub hasura_enabled: bool,
}

pub async fn up(project_root: &Path) -> anyhow::Result<UpResult> {
    let env = EnvConfig::from_project(project_root);
    let pg_host_port: u16 = env
        .pg_port
        .parse()
        .context("ENVIO_PG_PORT is not a valid port")?;
    let hasura_host_port: u16 = env
        .hasura_port
        .parse()
        .context("HASURA_EXTERNAL_PORT is not a valid port")?;

    // Probe locally-published ports to see if containers are already running.
    // Always check localhost since Docker publishes on 0.0.0.0, regardless of
    // what ENVIO_PG_HOST is set to (that controls where the runtime connects).
    let probe_host = "localhost";
    let (pg_alive, hasura_alive) =
        tokio::join!(is_service_reachable(probe_host, pg_host_port), async {
            if !env.hasura_enabled {
                return false;
            }
            is_hasura_healthy(probe_host, hasura_host_port).await
        });

    let need_pg = !pg_alive;
    let need_hasura = env.hasura_enabled && !hasura_alive;

    if pg_alive {
        println!("Postgres already reachable on port {pg_host_port}, skipping container");
    }
    if env.hasura_enabled && hasura_alive {
        println!("Hasura already healthy on port {hasura_host_port}, skipping container");
    }
    if !env.hasura_enabled {
        println!("Hasura disabled (ENVIO_HASURA=false), skipping");
    }

    // If both services are already running, nothing to do.
    if !need_pg && !need_hasura {
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

        let hasura_body = ContainerCreateBody {
            image: Some(HASURA_IMAGE.to_string()),
            labels: Some(make_labels(&config_hash)),
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

    let (pg_res, hasura_res) = tokio::join!(pg_pipeline, hasura_pipeline);
    pg_res?;
    hasura_res?;

    // Wait for services to become healthy before handing control back.
    let wait_pg = async {
        if !need_pg {
            return Ok::<(), anyhow::Error>(());
        }
        eprint!("Waiting for Postgres...");
        let start = std::time::Instant::now();
        loop {
            if is_service_reachable(probe_host, pg_host_port).await {
                eprintln!(" ready ({:.1}s)", start.elapsed().as_secs_f64());
                return Ok(());
            }
            if start.elapsed() > Duration::from_secs(60) {
                eprintln!();
                anyhow::bail!(
                    "Postgres did not become reachable on port {pg_host_port} within 60s"
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
            if is_hasura_healthy(probe_host, hasura_host_port).await {
                eprintln!(" ready ({:.1}s)", start.elapsed().as_secs_f64());
                return Ok(());
            }
            if start.elapsed() > Duration::from_secs(120) {
                eprintln!();
                anyhow::bail!(
                    "Hasura did not become healthy on port {hasura_host_port} within 120s.\n\
                     Check container logs: docker logs {HASURA_CONTAINER}"
                );
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
            eprint!(".");
        }
    };

    tokio::try_join!(wait_pg, wait_hasura)?;

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
    );

    let (vol_res, net_res) = tokio::join!(
        docker.remove_volume(
            VOLUME,
            None::<bollard::query_parameters::RemoveVolumeOptions>
        ),
        docker.remove_network(NETWORK),
    );

    let mut failed = false;
    if let Err(e) = vol_res {
        eprintln!("Failed to remove volume {VOLUME}: {e}");
        failed = true;
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
        };
        assert_ne!(env1.config_hash(), env2.config_hash());
    }
}
