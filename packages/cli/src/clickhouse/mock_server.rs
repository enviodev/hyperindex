//! A stand-in ClickHouse over HTTP, for testing the parts of the sink that only
//! show up when the server misbehaves. It records every insert body it accepts,
//! and can be told to reject the first N inserts so the retry path runs for
//! real. Anything that is not an insert is counted and refused, because a sink
//! that takes its column types from the caller has no reason to ask.

use std::sync::{Arc, Mutex};

use tokio::net::{TcpListener, TcpStream};

use crate::mock_http;

/// Answers a statement — the SQL arrives in the request body — with the status
/// and body to send back.
pub type StatementFn = dyn Fn(&str) -> (u16, String) + Send + Sync;

#[derive(Default)]
struct State {
    /// Bodies of the inserts the server accepted, in arrival order.
    accepted: Vec<Vec<u8>>,
    /// How a statement — anything that is not an insert — is answered. `None`
    /// refuses it, which is what a sink taking its column types from the caller
    /// should never provoke.
    statements: Option<Arc<StatementFn>>,
    /// Statements the server was asked, in arrival order.
    statements_seen: Vec<String>,
    /// Inserts still to be rejected before the server starts accepting.
    reject_next: usize,
    /// The body a rejection carries, which is what tells the sink whether the
    /// rows are worth sending again.
    rejection: String,
    /// The status a rejection carries. Only what a proxy in front of ClickHouse
    /// answered is read from this; a body naming a code speaks for itself.
    rejection_status: u16,
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
    /// server starts accepting, carrying a memory limit — the error a batch is
    /// itself to blame for, so the sink retries it in halves.
    pub async fn start(reject_next: usize) -> Self {
        Self::rejecting_with(reject_next, "Code: 241. DB::Exception: mock rejection").await
    }

    /// Rejects with `rejection` as the body, for a test that turns on how the
    /// sink reads the server's verdict.
    pub async fn rejecting_with(reject_next: usize, rejection: &str) -> Self {
        Self::rejecting_with_status(reject_next, 500, rejection).await
    }

    /// Rejects with `status` and `rejection`, for a test about a proxy in front
    /// of ClickHouse: a body with no `Code:` in it leaves the status as the only
    /// thing the sink can read the verdict from.
    pub async fn rejecting_with_status(reject_next: usize, status: u16, rejection: &str) -> Self {
        Self::serving(State {
            reject_next,
            rejection: rejection.to_string(),
            rejection_status: status,
            ..Default::default()
        })
        .await
    }

    /// Answers statements with `statements` rather than refusing them, for the
    /// schema and recovery paths, which are made of them. Inserts are accepted.
    pub async fn answering_statements(statements: Arc<StatementFn>) -> Self {
        Self::serving(State {
            statements: Some(statements),
            ..Default::default()
        })
        .await
    }

    async fn serving(state: State) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let state = Arc::new(Mutex::new(state));

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

    /// The statements the server was asked, in arrival order.
    pub fn statements_seen(&self) -> Vec<String> {
        self.state.lock().unwrap().statements_seen.clone()
    }

    /// Request line and headers of every request the server handled.
    pub fn heads(&self) -> Vec<String> {
        self.state.lock().unwrap().heads.clone()
    }

    /// Decodes every accepted body as rows of one `String` column, one entry per
    /// insert — enough to tell not just which rows landed but how the retry
    /// split them. A body that is not that shape is a bug in the encoder under
    /// test, so it fails here rather than being reported as missing rows.
    pub fn accepted_batches(&self) -> Vec<Vec<String>> {
        self.accepted()
            .iter()
            .map(|body| {
                let mut rows = Vec::new();
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
                    rows.push(String::from_utf8(bytes).unwrap());
                    i = end;
                }
                rows
            })
            .collect()
    }

    /// Every row that landed, flattened across inserts in arrival order.
    pub fn accepted_strings(&self) -> Vec<String> {
        self.accepted_batches().into_iter().flatten().collect()
    }
}

async fn serve(mut stream: TcpStream, state: Arc<Mutex<State>>) -> std::io::Result<()> {
    let mut buffered: Vec<u8> = Vec::new();
    while let Some(request) = mock_http::read_request(&mut stream, &mut buffered).await? {
        state.lock().unwrap().heads.push(request.head);

        // The request target carries the query for an insert; a read query
        // arrives in the body instead.
        let (status, body) = if request.path.contains("INSERT") {
            let rejection = {
                let mut state = state.lock().unwrap();
                state.seen += 1;
                if state.reject_next > 0 {
                    state.reject_next -= 1;
                    Some((state.rejection_status, state.rejection.clone()))
                } else {
                    state.accepted.push(request.body);
                    None
                }
            };
            rejection.unwrap_or((200, String::new()))
        } else {
            let statement = String::from_utf8_lossy(&request.body).to_string();
            let answer = {
                let mut state = state.lock().unwrap();
                state.queries += 1;
                state.statements_seen.push(statement.clone());
                state.statements.clone()
            };
            match answer {
                Some(answer) => answer(&statement),
                None => (
                    400,
                    "the sink should not be querying the server".to_string(),
                ),
            }
        };
        mock_http::write_response(
            &mut stream,
            status,
            &[("Connection", "keep-alive")],
            body.as_bytes(),
        )
        .await?;
    }
    // Peer closed between requests.
    Ok(())
}
