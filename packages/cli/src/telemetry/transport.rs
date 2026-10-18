use std::path::Path;
use std::process::{Child, Command, Stdio};

const ENDPOINT_VAR: &str = "ENVIO_TELEMETRY_ENDPOINT";
const PAYLOAD_VAR: &str = "ENVIO_TELEMETRY_PAYLOAD";

/// Carried into the sender so it reaches the network the way the user's own
/// Node.js would. Everything else, `NODE_OPTIONS` included, stays behind.
const PASSTHROUGH_VARS: &[&str] = &[
    "HTTPS_PROXY",
    "https_proxy",
    "HTTP_PROXY",
    "http_proxy",
    "NO_PROXY",
    "no_proxy",
    "NODE_USE_ENV_PROXY",
    "NODE_EXTRA_CA_CERTS",
];

/// Posts the payload with a 2s timeout and one retry, on a network error or a
/// 5xx. Runs in its own Node.js process so the command that produced the
/// payload can exit without waiting on the network.
const SENDER_SCRIPT: &str = r#"
const url = process.env.ENVIO_TELEMETRY_ENDPOINT;
const body = process.env.ENVIO_TELEMETRY_PAYLOAD;
const post = () =>
  fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
    signal: AbortSignal.timeout(2000),
  }).then((res) => {
    if (res.status >= 500) throw new Error(String(res.status));
  });
post()
  .catch(() => new Promise((resolve) => setTimeout(resolve, 250)).then(post))
  .catch(() => {})
  .finally(() => process.exit(0));
"#;

/// Starts the sender and returns at once; nothing here waits on the network.
/// The child gets its own process group, so the Ctrl-C that ends `envio dev`
/// doesn't take an in-flight send with it, and outlives this process if it
/// exits first. All failures are silent.
pub fn send_detached(endpoint: &str, payload: &str) {
    if let Ok(node) = std::env::current_exe() {
        send_detached_with(&node, endpoint, payload);
    }
}

fn send_detached_with(node: &Path, endpoint: &str, payload: &str) {
    if let Ok(mut child) = spawn_sender(node, endpoint, payload) {
        // Reaped off-thread so a long-running indexer doesn't collect zombies.
        let _ = std::thread::Builder::new()
            .name("envio-telemetry-reaper".to_string())
            .spawn(move || {
                let _ = child.wait();
            });
    }
}

/// `node` is the JS runtime the addon is loaded into: `current_exe()` in
/// production, since this code runs inside it.
fn spawn_sender(node: &Path, endpoint: &str, payload: &str) -> std::io::Result<Child> {
    let mut command = Command::new(node);
    command
        .arg("-e")
        .arg(SENDER_SCRIPT)
        .env_clear()
        .env(ENDPOINT_VAR, endpoint)
        .env(PAYLOAD_VAR, payload)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for name in PASSTHROUGH_VARS {
        if let Ok(value) = std::env::var(name) {
            command.env(name, value);
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    command.spawn()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    /// The Node.js on PATH, as an absolute path: production hands the sender
    /// one too, and the sender clears PATH from its environment.
    fn node() -> std::path::PathBuf {
        std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
            .map(|dir| dir.join("node"))
            .find(|candidate| candidate.is_file())
            .expect("these tests run the sender under Node.js, which should be on PATH")
    }

    fn wait_with_deadline(child: &mut Child, deadline: Duration) -> Option<Duration> {
        let started = Instant::now();
        while started.elapsed() < deadline {
            if child
                .try_wait()
                .expect("child should be waitable")
                .is_some()
            {
                return Some(started.elapsed());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = child.kill();
        None
    }

    /// Accepts connections and answers each with `respond`, recording every
    /// request it read.
    fn serve(respond: Option<&'static str>) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/v1/hyperindex", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let seen = requests.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let seen = seen.clone();
                std::thread::spawn(move || {
                    let mut buf = vec![0u8; 16 * 1024];
                    let mut read = 0;
                    stream
                        .set_read_timeout(Some(Duration::from_millis(500)))
                        .unwrap();
                    while let Ok(n) = stream.read(&mut buf[read..]) {
                        if n == 0 {
                            break;
                        }
                        read += n;
                        let text = String::from_utf8_lossy(&buf[..read]);
                        if let Some((head, body)) = text.split_once("\r\n\r\n") {
                            let length = head
                                .lines()
                                .find_map(|l| {
                                    l.to_lowercase()
                                        .strip_prefix("content-length: ")
                                        .map(|v| v.trim().parse::<usize>().unwrap_or(0))
                                })
                                .unwrap_or(0);
                            if body.len() >= length {
                                break;
                            }
                        }
                    }
                    seen.lock()
                        .unwrap()
                        .push(String::from_utf8_lossy(&buf[..read]).into_owned());
                    match respond {
                        Some(status) => {
                            let _ = stream.write_all(
                                format!("HTTP/1.1 {status}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                                    .as_bytes(),
                            );
                        }
                        // Holds the connection open without ever answering.
                        None => std::thread::sleep(Duration::from_secs(30)),
                    }
                });
            }
        });
        (url, requests)
    }

    #[test]
    fn send_detached_returns_without_waiting_on_the_network() {
        // A non-routable address: a blocking send would hang here until its
        // timeout.
        let started = Instant::now();
        send_detached_with(&node(), "http://10.255.255.1:9/v1/hyperindex", "{}");
        assert!(
            started.elapsed() < Duration::from_millis(500),
            "send_detached blocked for {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn sender_posts_the_payload_once_on_success() {
        let (url, requests) = serve(Some("204 No Content"));
        let mut child = spawn_sender(&node(), &url, r#"{"schema_version":1}"#).unwrap();
        let finished = wait_with_deadline(&mut child, Duration::from_secs(10));
        let requests = requests.lock().unwrap().clone();
        assert_eq!(
            (
                finished.is_some(),
                requests.len(),
                requests.first().map(|r| (
                    r.starts_with("POST /v1/hyperindex "),
                    r.ends_with(r#"{"schema_version":1}"#)
                )),
            ),
            (true, 1, Some((true, true)))
        );
    }

    #[test]
    fn sender_retries_once_on_a_server_error() {
        let (url, requests) = serve(Some("503 Service Unavailable"));
        let mut child = spawn_sender(&node(), &url, "{}").unwrap();
        let finished = wait_with_deadline(&mut child, Duration::from_secs(10));
        assert_eq!(
            (finished.is_some(), requests.lock().unwrap().len()),
            (true, 2)
        );
    }

    #[test]
    fn sender_gives_up_on_a_silent_server_after_two_timed_out_attempts() {
        let (url, requests) = serve(None);
        let mut child = spawn_sender(&node(), &url, "{}").unwrap();
        let finished = wait_with_deadline(&mut child, Duration::from_secs(10));
        // Two 2s attempts and the pause between them, plus Node.js start-up.
        assert_eq!(
            (
                finished.is_some_and(|took| took < Duration::from_secs(7)),
                requests.lock().unwrap().len(),
            ),
            (true, 2)
        );
    }
}
