//! The Postgres and ClickHouse servers the live tests run against, started
//! once per test process on free ports, in a directory of their own.
//!
//! Postgres comes from the binaries on `PATH`, or from where Debian and Ubuntu
//! install them. ClickHouse comes from `PATH`, or is downloaded once on Linux.

use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

pub(crate) const PASSWORD: &str = "testing";
const CLICKHOUSE_VERSION: &str = "26.2.15.4";

pub(crate) struct Postgres {
    pub port: u16,
}

/// Two replicas of one shard, sharing a Keeper. A test that doesn't replicate
/// uses the first alone.
pub(crate) struct ClickHouse {
    pub replicas: [String; 2],
}

pub(crate) fn postgres() -> &'static Postgres {
    static SERVER: OnceLock<Postgres> = OnceLock::new();
    SERVER.get_or_init(start_postgres)
}

pub(crate) fn clickhouse() -> &'static ClickHouse {
    static CLUSTER: OnceLock<ClickHouse> = OnceLock::new();
    CLUSTER.get_or_init(start_clickhouse)
}

fn start_postgres() -> Postgres {
    let bin = postgres_bin();
    let root = scratch_dir("postgres");
    let data = root.join("data");
    // Postgres refuses to run as root, so a root test process hands the
    // directory and the server to the `postgres` user.
    let root_user = is_root();
    let command = |program: &str| {
        if root_user {
            let mut command = Command::new("runuser");
            command
                .args(["-u", "postgres", "--"])
                .arg(bin.join(program));
            command
        } else {
            Command::new(bin.join(program))
        }
    };
    if root_user {
        succeed(Command::new("chown").arg("postgres").arg(&root));
    }
    succeed(command("initdb").arg("-D").arg(&data).args([
        "-U",
        "postgres",
        "--auth=trust",
        "--no-sync",
        "--no-locale",
        "-E",
        "UTF8",
    ]));

    let port = free_port();
    let log = root.join("server.log");
    spawn_logged(
        command("postgres")
            .arg("-D")
            .arg(&data)
            .args(["-p", &port.to_string(), "-k"])
            .arg(&root)
            .args([
                "-c",
                "listen_addresses=127.0.0.1",
                "-c",
                "fsync=off",
                "-c",
                "synchronous_commit=off",
                "-c",
                "full_page_writes=off",
            ]),
        &log,
    );
    // The postmaster's pid from its own file: under `runuser` the child
    // spawned is `runuser`, not the server.
    stop_with_this_process(
        &format!("kill -QUIT $(head -1 '{}/postmaster.pid')", data.display()),
        &root,
    );
    wait_for("Postgres", &log, || {
        Command::new(bin.join("pg_isready"))
            .args(["-q", "-h", "127.0.0.1", "-p", &port.to_string()])
            .status()
            .is_ok_and(|status| status.success())
    });
    Postgres { port }
}

fn postgres_bin() -> PathBuf {
    if let Some(initdb) = on_path("initdb") {
        return initdb.parent().unwrap().to_path_buf();
    }
    fs::read_dir("/usr/lib/postgresql")
        .into_iter()
        .flatten()
        .flatten()
        .map(|version| version.path().join("bin"))
        .filter(|bin| bin.join("initdb").exists())
        .max_by_key(|bin| {
            bin.parent()
                .and_then(|version| version.file_name()?.to_str()?.parse::<u32>().ok())
        })
        .expect("no Postgres server binaries: put `initdb` and `postgres` on PATH")
}

fn start_clickhouse() -> ClickHouse {
    let binary = clickhouse_binary();
    let root = scratch_dir("clickhouse");
    let [keeper, raft] = [free_port(), free_port()];
    let replicas = ["a", "b"].map(|name| (name, free_port(), free_port(), free_port()));

    fs::write(
        root.join("users.xml"),
        format!(
            "<clickhouse>
    <profiles><default/></profiles>
    <quotas><default/></quotas>
    <users>
        <default>
            <password>{PASSWORD}</password>
            <networks><ip>::/0</ip></networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
</clickhouse>"
        ),
    )
    .unwrap();
    let shard = replicas
        .iter()
        .map(|(_, _, tcp, _)| {
            format!(
                "<replica><host>127.0.0.1</host><port>{tcp}</port>\
                 <user>default</user><password>{PASSWORD}</password></replica>"
            )
        })
        .collect::<String>();

    let mut pids = Vec::new();
    for (index, (name, http, tcp, interserver)) in replicas.iter().enumerate() {
        let dir = root.join(name);
        for sub in [
            "data",
            "tmp",
            "user_files",
            "keeper/log",
            "keeper/snapshots",
        ] {
            fs::create_dir_all(dir.join(sub)).unwrap();
        }
        let dir = dir.display();
        // The first replica runs the Keeper both use.
        let keeper_server = if index == 0 {
            format!(
                "<keeper_server>
        <tcp_port>{keeper}</tcp_port>
        <server_id>1</server_id>
        <log_storage_path>{dir}/keeper/log</log_storage_path>
        <snapshot_storage_path>{dir}/keeper/snapshots</snapshot_storage_path>
        <raft_configuration>
            <server><id>1</id><hostname>127.0.0.1</hostname><port>{raft}</port></server>
        </raft_configuration>
    </keeper_server>"
            )
        } else {
            String::new()
        };
        let config = format!(
            "<clickhouse>
    <logger><level>warning</level><log>{dir}/server.log</log><errorlog>{dir}/error.log</errorlog></logger>
    <http_port>{http}</http_port>
    <tcp_port>{tcp}</tcp_port>
    <interserver_http_port>{interserver}</interserver_http_port>
    <interserver_http_host>127.0.0.1</interserver_http_host>
    <listen_host>127.0.0.1</listen_host>
    <path>{dir}/data/</path>
    <tmp_path>{dir}/tmp/</tmp_path>
    <user_files_path>{dir}/user_files/</user_files_path>
    <user_directories><users_xml><path>{root}/users.xml</path></users_xml></user_directories>
    <mark_cache_size>134217728</mark_cache_size>
    <max_server_memory_usage_to_ram_ratio>0.2</max_server_memory_usage_to_ram_ratio>
    <macros><cluster>envio</cluster><shard>01</shard><replica>{name}</replica></macros>
    {keeper_server}
    <zookeeper><node><host>127.0.0.1</host><port>{keeper}</port></node></zookeeper>
    <distributed_ddl><path>/clickhouse/task_queue/ddl</path></distributed_ddl>
    <remote_servers><envio><shard><internal_replication>true</internal_replication>{shard}</shard></envio></remote_servers>
</clickhouse>",
            root = root.display(),
        );
        let config_path = format!("{dir}/config.xml");
        fs::write(&config_path, config).unwrap();
        pids.push(spawn_logged(
            Command::new(&binary)
                .arg("server")
                .arg(format!("--config-file={config_path}")),
            Path::new(&format!("{dir}/stdout.log")),
        ));
    }
    stop_with_this_process(&format!("kill -9 {}", pids.join(" ")), &root);

    let urls = replicas.map(|(_, http, _, _)| format!("http://127.0.0.1:{http}"));
    for ((name, ..), url) in replicas.iter().zip(&urls) {
        // Answering isn't enough: replicated DDL also needs Keeper to have
        // elected itself, which it does a moment after the servers come up.
        wait_for("ClickHouse", &root.join(name).join("error.log"), || {
            Command::new("curl")
                .args(["-sf", "-u", &format!("default:{PASSWORD}"), url])
                .args([
                    "--data-binary",
                    "SELECT count() FROM system.zookeeper WHERE path = '/'",
                ])
                .stdout(Stdio::null())
                .status()
                .is_ok_and(|status| status.success())
        });
    }
    ClickHouse { replicas: urls }
}

fn clickhouse_binary() -> PathBuf {
    if let Some(binary) = on_path("clickhouse") {
        return binary;
    }
    let arch = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => "amd64",
        ("linux", "aarch64") => "arm64",
        _ => panic!("no ClickHouse binary: put `clickhouse` on PATH"),
    };
    let dir = std::env::temp_dir().join(format!("envio-clickhouse-{CLICKHOUSE_VERSION}"));
    let binary = dir.join(format!(
        "clickhouse-common-static-{CLICKHOUSE_VERSION}/usr/bin/clickhouse"
    ));
    if !binary.exists() {
        // Unpacked beside the final directory and renamed into place, so a test
        // process killed mid-download leaves nothing that looks finished.
        let partial = scratch_dir("clickhouse-download");
        succeed(Command::new("sh").arg("-c").arg(format!(
            "curl -fsSL https://packages.clickhouse.com/tgz/stable/\
             clickhouse-common-static-{CLICKHOUSE_VERSION}-{arch}.tgz | tar -xz -C '{partial}' \
             || {{ rm -rf '{partial}'; exit 1; }}",
            partial = partial.display()
        )));
        // A sibling process may have finished first; either copy is the same.
        let _ = fs::rename(&partial, &dir);
        let _ = fs::remove_dir_all(&partial);
    }
    binary
}

fn on_path(program: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(program))
        .find(|path| path.is_file())
}

fn is_root() -> bool {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() == 0 }
}

fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("envio-live-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .and_then(|listener| listener.local_addr())
        .unwrap()
        .port()
}

fn succeed(command: &mut Command) {
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "{command:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// Starts a server and answers its pid.
fn spawn_logged(command: &mut Command, log: &Path) -> String {
    let log = fs::File::create(log).unwrap();
    command
        .stdin(Stdio::null())
        .stdout(log.try_clone().unwrap())
        .stderr(log)
        .spawn()
        .unwrap_or_else(|error| panic!("{command:?} didn't start: {error}"))
        .id()
        .to_string()
}

/// The servers outlive any test, so a watcher outside this process stops them
/// once it is gone, however it ends. It is never waited on: it has to outlive
/// this process.
#[allow(clippy::zombie_processes)]
fn stop_with_this_process(stop: &str, root: &Path) {
    Command::new("sh")
        .arg("-c")
        .arg(format!(
            "while kill -0 {pid} 2>/dev/null; do sleep 1; done; {stop}; sleep 1; rm -rf '{root}'",
            pid = std::process::id(),
            root = root.display(),
        ))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
}

fn wait_for(server: &str, log: &Path, ready: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !ready() {
        if Instant::now() > deadline {
            panic!(
                "{server} didn't come up:\n{}",
                fs::read_to_string(log).unwrap_or_default()
            );
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
