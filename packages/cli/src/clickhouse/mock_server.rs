//! A stand-in ClickHouse over HTTP, for testing the parts of the sink that only
//! show up when the server misbehaves. It answers the `system.columns` lookup
//! from a fixed schema, records every insert body it accepts, and can be told to
//! reject the first N inserts so the retry path runs for real.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

#[derive(Default)]
struct State {
    /// Bodies of the inserts the server accepted, in arrival order.
    accepted: Vec<Vec<u8>>,
    /// Inserts still to be rejected before the server starts accepting.
    reject_next: usize,
    /// Read queries still to be rejected — the `system.columns` lookup.
    reject_next_queries: usize,
    /// Total inserts seen, accepted or not.
    seen: usize,
}

pub struct MockClickHouse {
    pub url: String,
    state: Arc<Mutex<State>>,
    /// Column name and type text, as `system.columns` would report them.
    columns: Vec<(String, String)>,
}

impl MockClickHouse {
    /// Serves until dropped. `reject_next` inserts fail with a 500 before the
    /// server starts accepting.
    pub async fn start(columns: &[(&str, &str)], reject_next: usize) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let state = Arc::new(Mutex::new(State {
            reject_next,
            ..Default::default()
        }));
        let columns: Vec<(String, String)> = columns
            .iter()
            .map(|(name, ty)| (name.to_string(), ty.to_string()))
            .collect();

        let accept_state = state.clone();
        let accept_columns = columns.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let state = accept_state.clone();
                let columns = accept_columns.clone();
                tokio::spawn(async move {
                    // The sink pools connections, so one socket carries many
                    // requests; serve until the peer closes it.
                    let _ = serve(stream, state, columns).await;
                });
            }
        });

        Self {
            url,
            state,
            columns,
        }
    }

    /// Accepts connections and reads whatever is sent, but never answers —
    /// a server or load balancer that black-holes an established connection.
    /// Nothing short of a client-side timeout ends a request against this.
    pub async fn start_unresponsive() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let mut held = Vec::new();
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                // Holding the stream keeps the connection open rather than
                // closing it, which the client would see as a failure.
                held.push(stream);
            }
        });
        Self {
            url,
            state: Arc::new(Mutex::new(State::default())),
            columns: Vec::new(),
        }
    }

    pub fn accepted(&self) -> Vec<Vec<u8>> {
        self.state.lock().unwrap().accepted.clone()
    }

    /// Fails the next `count` read queries before answering the schema lookup.
    pub fn reject_next_queries(&self, count: usize) {
        self.state.lock().unwrap().reject_next_queries = count;
    }

    pub fn inserts_seen(&self) -> usize {
        self.state.lock().unwrap().seen
    }

    /// Decodes every accepted body as rows of one `String` column, flattened in
    /// arrival order — enough to tell which rows landed and how often.
    pub fn accepted_strings(&self) -> Vec<String> {
        let mut out = Vec::new();
        for body in self.accepted() {
            let mut i = 0usize;
            while i < body.len() {
                let (len, read) = read_varint(&body[i..]);
                i += read;
                out.push(String::from_utf8(body[i..i + len].to_vec()).unwrap());
                i += len;
            }
        }
        out
    }

    pub fn column_types(&self) -> &[(String, String)] {
        &self.columns
    }
}

fn read_varint(bytes: &[u8]) -> (usize, usize) {
    let mut value = 0usize;
    let mut shift = 0u32;
    let mut read = 0usize;
    loop {
        let byte = bytes[read];
        value |= ((byte & 0x7F) as usize) << shift;
        read += 1;
        if byte & 0x80 == 0 {
            return (value, read);
        }
        shift += 7;
    }
}

async fn serve(
    mut stream: TcpStream,
    state: Arc<Mutex<State>>,
    columns: Vec<(String, String)>,
) -> std::io::Result<()> {
    let mut buffered: VecDeque<u8> = VecDeque::new();
    loop {
        let head = match read_until_headers(&mut stream, &mut buffered).await? {
            Some(head) => head,
            // Peer closed between requests.
            None => return Ok(()),
        };
        let content_length = head
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.trim()
                    .eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())?
            })
            .unwrap_or(0);

        let mut body = vec![0u8; content_length];
        for (i, slot) in body.iter_mut().enumerate() {
            *slot = match buffered.pop_front() {
                Some(byte) => byte,
                None => {
                    let mut chunk = vec![0u8; content_length - i];
                    stream.read_exact(&mut chunk).await?;
                    let mut iter = chunk.into_iter();
                    let first = iter.next().unwrap();
                    buffered.extend(iter);
                    first
                }
            };
        }

        // The request line carries the query for an insert; a read query arrives
        // in the body instead.
        let request_line = head.lines().next().unwrap_or_default().to_string();
        let is_insert = request_line.contains("INSERT") || request_line.contains("INSERT+INTO");

        let response = if is_insert {
            let reject = {
                let mut state = state.lock().unwrap();
                state.seen += 1;
                if state.reject_next > 0 {
                    state.reject_next -= 1;
                    true
                } else {
                    state.accepted.push(body.clone());
                    false
                }
            };
            if reject {
                http_response(500, "Code: 999. DB::Exception: mock rejection")
            } else {
                http_response(200, "")
            }
        } else {
            let reject = {
                let mut state = state.lock().unwrap();
                let reject = state.reject_next_queries > 0;
                state.reject_next_queries = state.reject_next_queries.saturating_sub(1);
                reject
            };
            if reject {
                http_response(500, "Code: 999. DB::Exception: mock query rejection")
            } else {
                let tsv = columns
                    .iter()
                    .map(|(name, ty)| format!("{name}\t{ty}"))
                    .collect::<Vec<_>>()
                    .join("\n");
                http_response(200, &format!("{tsv}\n"))
            }
        };
        stream.write_all(&response).await?;
        stream.flush().await?;
    }
}

/// Reads up to and including the blank line ending the headers. `None` when the
/// peer closed before sending anything.
async fn read_until_headers(
    stream: &mut TcpStream,
    buffered: &mut VecDeque<u8>,
) -> std::io::Result<Option<String>> {
    let mut head: Vec<u8> = Vec::new();
    loop {
        while let Some(byte) = buffered.pop_front() {
            head.push(byte);
            if head.ends_with(b"\r\n\r\n") {
                return Ok(Some(String::from_utf8_lossy(&head).to_string()));
            }
        }
        let mut chunk = [0u8; 4096];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Ok(if head.is_empty() {
                None
            } else {
                Some(String::from_utf8_lossy(&head).to_string())
            });
        }
        buffered.extend(&chunk[..read]);
    }
}

fn http_response(status: u16, body: &str) -> Vec<u8> {
    let reason = if status == 200 { "OK" } else { "Internal" };
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}
