//! A stand-in ClickHouse over HTTP, for testing the parts of the sink that only
//! show up when the server misbehaves. It records every insert body it accepts,
//! and can be told to reject the first N inserts so the retry path runs for
//! real. Anything that is not an insert is counted and refused, because a sink
//! that takes its column types from the caller has no reason to ask.

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
    /// The body a rejection carries, which is what tells the sink whether the
    /// rows are worth sending again.
    rejection: String,
    /// Total inserts seen, accepted or not.
    seen: usize,
    /// Total read queries seen.
    queries: usize,
    /// Request line and headers of every request, in arrival order.
    heads: Vec<String>,
}

pub struct MockClickHouse {
    pub url: String,
    state: Arc<Mutex<State>>,
}

impl MockClickHouse {
    /// Serves until dropped. `reject_next` inserts fail with a 500 before the
    /// server starts accepting, carrying a keeper exception — an error the rows
    /// themselves are not to blame for, so the sink retries it.
    pub async fn start(reject_next: usize) -> Self {
        Self::rejecting_with(reject_next, "Code: 999. DB::Exception: mock rejection").await
    }

    /// Rejects with `rejection` as the body, for a test that turns on how the
    /// sink reads the server's verdict.
    pub async fn rejecting_with(reject_next: usize, rejection: &str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let state = Arc::new(Mutex::new(State {
            reject_next,
            rejection: rejection.to_string(),
            ..Default::default()
        }));

        let accept_state = state.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let state = accept_state.clone();
                tokio::spawn(async move {
                    // The sink pools connections, so one socket carries many
                    // requests; serve until the peer closes it.
                    let _ = serve(stream, state).await;
                });
            }
        });

        Self { url, state }
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
        }
    }

    pub fn accepted(&self) -> Vec<Vec<u8>> {
        self.state.lock().unwrap().accepted.clone()
    }

    pub fn inserts_seen(&self) -> usize {
        self.state.lock().unwrap().seen
    }

    /// Read queries the server was asked, which for a sink that takes its types
    /// from the caller should stay at zero.
    pub fn queries_seen(&self) -> usize {
        self.state.lock().unwrap().queries
    }

    /// Request line and headers of every request the server handled.
    pub fn heads(&self) -> Vec<String> {
        self.state.lock().unwrap().heads.clone()
    }

    /// Decodes every accepted body as rows of one `String` column, flattened in
    /// arrival order — enough to tell which rows landed and how often. A body
    /// that is not that shape is a bug in the encoder under test, so it fails
    /// here rather than being reported as missing rows.
    pub fn accepted_strings(&self) -> Vec<String> {
        let mut out = Vec::new();
        for body in self.accepted() {
            let mut i = 0usize;
            while i < body.len() {
                let (len, read) = super::row_binary::read_varint(&body[i..])
                    .expect("accepted body is not a String column");
                i += read;
                let end = i + len as usize;
                let bytes = body
                    .get(i..end)
                    .expect("accepted body ends mid-string")
                    .to_vec();
                out.push(String::from_utf8(bytes).unwrap());
                i = end;
            }
        }
        out
    }
}

async fn serve(mut stream: TcpStream, state: Arc<Mutex<State>>) -> std::io::Result<()> {
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

        // Whatever of the body already arrived with the headers, then the rest
        // straight off the socket.
        let buffered_bytes = buffered.len().min(content_length);
        let mut body: Vec<u8> = buffered.drain(..buffered_bytes).collect();
        body.resize(content_length, 0);
        stream.read_exact(&mut body[buffered_bytes..]).await?;

        state.lock().unwrap().heads.push(head.clone());

        // The request line carries the query for an insert; a read query arrives
        // in the body instead.
        let request_line = head.lines().next().unwrap_or_default().to_string();
        let is_insert = request_line.contains("INSERT");

        let response = if is_insert {
            let rejection = {
                let mut state = state.lock().unwrap();
                state.seen += 1;
                if state.reject_next > 0 {
                    state.reject_next -= 1;
                    Some(state.rejection.clone())
                } else {
                    state.accepted.push(body.clone());
                    None
                }
            };
            match rejection {
                Some(rejection) => http_response(500, &rejection),
                None => http_response(200, ""),
            }
        } else {
            state.lock().unwrap().queries += 1;
            http_response(400, "the sink should not be querying the server")
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
