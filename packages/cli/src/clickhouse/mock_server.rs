use std::sync::{Arc, Mutex};

use tokio::net::{TcpListener, TcpStream};

use crate::mock_http;

pub type StatementFn = dyn Fn(&str) -> (u16, String) + Send + Sync;

#[derive(Default)]
struct State {
    accepted: Vec<Vec<u8>>,
    statements: Option<Arc<StatementFn>>,
    statements_seen: Vec<String>,
    reject_next: usize,
    /// Inserts still to be accepted and then failed. The body is recorded as
    /// landed — the server took the rows — but the client is told it did not.
    accept_then_error: usize,
    rejection: String,
    rejection_status: u16,
    seen: usize,
    queries: usize,
    heads: Vec<String>,
}

pub struct MockClickHouse {
    pub url: String,
    state: Arc<Mutex<State>>,
}

impl MockClickHouse {
    pub async fn start(reject_next: usize) -> Self {
        Self::rejecting_with(reject_next, "Code: 241. DB::Exception: mock rejection").await
    }

    pub async fn rejecting_with(reject_next: usize, rejection: &str) -> Self {
        Self::rejecting_with_status(reject_next, 500, rejection).await
    }

    pub async fn rejecting_with_status(reject_next: usize, status: u16, rejection: &str) -> Self {
        Self::serving(State {
            reject_next,
            rejection: rejection.to_string(),
            rejection_status: status,
            ..Default::default()
        })
        .await
    }

    /// Records the next `n` insert bodies as accepted, then answers them with
    /// `rejection`. The case a timeout or unknown-status error is: the server
    /// took the rows and the client was told it did not.
    pub async fn accepting_then_erroring(n: usize, rejection: &str) -> Self {
        Self::serving(State {
            accept_then_error: n,
            rejection: rejection.to_string(),
            rejection_status: 500,
            ..Default::default()
        })
        .await
    }

    pub async fn answering_statements(statements: Arc<StatementFn>) -> Self {
        Self::serving(State {
            statements: Some(statements),
            ..Default::default()
        })
        .await
    }

    async fn serving(state: State) -> Self {
        let state = Arc::new(Mutex::new(state));
        let accept_state = state.clone();
        let url = listening(move |stream| {
            let state = accept_state.clone();
            tokio::spawn(async move {
                let _ = serve(stream, state).await;
            });
        })
        .await;
        Self { url, state }
    }

    /// Accepts connections and reads whatever is sent, but never answers —
    /// a server or load balancer that black-holes an established connection.
    /// Nothing short of a client-side timeout ends a request against this.
    pub async fn start_unresponsive() -> Self {
        let mut held = Vec::new();
        let url = listening(move |stream| held.push(stream)).await;
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

    pub fn queries_seen(&self) -> usize {
        self.state.lock().unwrap().queries
    }

    pub fn statements_seen(&self) -> Vec<String> {
        self.state.lock().unwrap().statements_seen.clone()
    }

    pub fn heads(&self) -> Vec<String> {
        self.state.lock().unwrap().heads.clone()
    }

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

    pub fn accepted_strings(&self) -> Vec<String> {
        self.accepted_batches().into_iter().flatten().collect()
    }
}

/// Binds a port and hands every connection to `handle`, answering with the URL
/// the mock is reachable at.
async fn listening(mut handle: impl FnMut(TcpStream) + Send + 'static) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            handle(stream);
        }
    });
    url
}

async fn serve(mut stream: TcpStream, state: Arc<Mutex<State>>) -> std::io::Result<()> {
    let mut buffered: Vec<u8> = Vec::new();
    while let Some(request) = mock_http::read_request(&mut stream, &mut buffered).await? {
        state.lock().unwrap().heads.push(request.head);

        let (status, body) = if request.path.contains("INSERT") {
            let outcome = {
                let mut state = state.lock().unwrap();
                state.seen += 1;
                if state.reject_next > 0 {
                    state.reject_next -= 1;
                    Some((state.rejection_status, state.rejection.clone()))
                } else {
                    state.accepted.push(request.body);
                    if state.accept_then_error > 0 {
                        state.accept_then_error -= 1;
                        Some((state.rejection_status, state.rejection.clone()))
                    } else {
                        None
                    }
                }
            };
            outcome.unwrap_or((200, String::new()))
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
    Ok(())
}
