//! The HTTP interface to one ClickHouse database: statements, reads and the
//! retried insert every write goes through.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;

use super::row_binary::EncodedRows;

const MAX_RETRIES: u32 = 8;

/// `@clickhouse/client`'s `request_timeout` default, which the JS insert path
/// ran under. Without it a peer that accepts a connection and then goes silent
/// — a black-holed socket through a load balancer sends neither RST nor FIN —
/// leaves the request hanging forever, and with it the whole write batch.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// What a schema, maintenance statement or read gets instead. `DROP DATABASE
/// ... SYNC` and the resume trim's `ALTER ... DELETE ... mutations_sync` both
/// run for as long as the data takes, so holding them to the insert deadline
/// would fail a restart on a large history table — the one case the trim
/// exists for.
const STATEMENT_TIMEOUT: Duration = Duration::from_secs(600);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Probes an idle pooled socket so a connection dropped by a NAT or proxy is
/// discovered before a batch is handed to it.
const TCP_KEEPALIVE: Duration = Duration::from_secs(30);
/// How long a pooled socket may sit idle before the client drops it. Deliberately
/// under ClickHouse's own `keep_alive_timeout` (3s on older servers, 10s by
/// default), which is the deadline that matters: past it the server closes the
/// socket, and a batch dispatched onto one already carrying a FIN fails with
/// `connection closed before message completed`. `@clickhouse/client` set its
/// `idle_socket_ttl` to 2.5s for the same reason.
const POOL_IDLE_TIMEOUT: Duration = Duration::from_millis(2_500);
const MAX_RETRY_DELAY: Duration = Duration::from_millis(1_000);
/// How long one batch may spend on the whole retry ladder. Halving turns a
/// failure into two more attempts, so a range that keeps failing costs
/// exponentially many requests — cheap when each is refused in milliseconds,
/// hours when each one first has to reach [`REQUEST_TIMEOUT`] against a peer
/// that accepts the connection and then goes silent. `retries` bounds how deep
/// a single range may go; this bounds what the batch as a whole may cost.
const RETRY_BUDGET: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy)]
pub struct Tuning {
    pub retries: u32,
    pub statement_timeout: Duration,
    pub max_retry_delay: Duration,
    pub request_timeout: Duration,
    pub retry_budget: Duration,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            retries: MAX_RETRIES,
            max_retry_delay: MAX_RETRY_DELAY,
            request_timeout: REQUEST_TIMEOUT,
            statement_timeout: STATEMENT_TIMEOUT,
            retry_budget: RETRY_BUDGET,
        }
    }
}

impl Tuning {
    fn delay(&self, retries_left: u32) -> Duration {
        if self.retries < 2 {
            return Duration::ZERO;
        }
        let span = self.max_retry_delay.as_millis() as u64;
        Duration::from_millis(
            (span / 10
                + (span - span / 10) * u64::from(self.retries - retries_left)
                    / u64::from(self.retries - 1))
            .min(span),
        )
    }
}

pub type Warn = Arc<dyn Fn(&str) + Send + Sync>;

pub struct Connection {
    pub url: String,
    pub username: String,
    pub password: String,
    pub database: String,
}

pub struct Client {
    http: reqwest::Client,
    url: String,
    username: String,
    password: String,
    pub database: String,
    tuning: Tuning,
    pub warn: Warn,
    /// The node that answered the first request. Every later answer has to come
    /// from it: the write order is only the read order on the node that took
    /// the writes, so an address that starts balancing across replicas is an
    /// error, not a slower path.
    served_by: Mutex<Option<String>>,
}

impl Client {
    pub fn new(connection: Connection, tuning: Tuning, warn: Warn) -> Result<Self> {
        let http = reqwest::Client::builder()
            .pool_idle_timeout(POOL_IDLE_TIMEOUT)
            .pool_max_idle_per_host(8)
            .timeout(tuning.request_timeout)
            .connect_timeout(CONNECT_TIMEOUT)
            .tcp_keepalive(TCP_KEEPALIVE)
            // reqwest picks up HTTP_PROXY/HTTPS_PROXY by default; Node's http
            // client never did, so honouring them here would silently start
            // routing a deployment's inserts through a proxy that nothing asked
            // to be in the path.
            .no_proxy()
            .build()
            .context("Failed building HTTP client")?;
        Ok(Self {
            http,
            url: connection.url.trim_end_matches('/').to_string(),
            username: connection.username,
            password: connection.password,
            database: connection.database,
            tuning,
            warn,
            served_by: Mutex::new(None),
        })
    }

    /// Runs a statement and returns the server's answer as text.
    pub async fn statement(&self, query: String) -> Result<String> {
        let body = self.post(query).await?;
        Ok(String::from_utf8_lossy(&body).into_owned())
    }

    /// Runs a read and returns the server's answer as it arrived, for a format
    /// that is not text.
    pub async fn read(&self, query: String) -> Result<Bytes> {
        self.post(query).await
    }

    /// Sends `body` as the data `query` takes, once.
    pub async fn send(&self, query: &str, body: Bytes) -> Result<()> {
        let request = self
            .http
            .post(&self.url)
            .timeout(self.tuning.statement_timeout)
            .query(&[("query", query), ("async_insert", "0")])
            .basic_auth(&self.username, Some(&self.password))
            .body(body);
        self.answer(request).await.map(|_| ())
    }

    async fn post(&self, query: String) -> Result<Bytes> {
        // Held until the query has finished, so one that fails after its first
        // rows would have been sent answers with an error status instead.
        let request = self
            .http
            .post(&self.url)
            .timeout(self.tuning.statement_timeout)
            .query(&[("wait_end_of_query", "1")])
            .basic_auth(&self.username, Some(&self.password))
            .body(query);
        self.answer(request).await
    }

    async fn answer(&self, request: reqwest::RequestBuilder) -> Result<Bytes> {
        let response = request.send().await.context("ClickHouse request failed")?;
        self.check_served_by(&response)?;
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await.unwrap_or_default();
            bail!("ClickHouse returned {status}: {text}");
        }
        response
            .bytes()
            .await
            .context("ClickHouse's answer broke off before its end")
    }

    /// ClickHouse names the node that answered in every response. The first
    /// one is the node this run is pinned to; an answer from any other means
    /// the address in front is balancing, and the next read could land on a
    /// replica still fetching what was just written. A response without the
    /// header (a proxy that strips it) leaves the pin unchecked.
    fn check_served_by(&self, response: &reqwest::Response) -> Result<()> {
        let Some(node) = response
            .headers()
            .get("X-ClickHouse-Server-Display-Name")
            .and_then(|value| value.to_str().ok())
        else {
            return Ok(());
        };
        let mut served_by = self.served_by.lock().unwrap();
        match served_by.as_deref() {
            None => {
                *served_by = Some(node.to_string());
                Ok(())
            }
            Some(pinned) if pinned == node => Ok(()),
            Some(pinned) => bail!(
                "ClickHouse answered from node \"{node}\" after earlier answers came from \
                 \"{pinned}\". The indexer has to read and write one replica: point \
                 ENVIO_CLICKHOUSE_HOST at a single node rather than a load balancer."
            ),
        }
    }

    /// Sends rows with `query`, retrying what a resend can fix — whole, or
    /// halved where the batch's size is what failed.
    pub async fn insert(&self, table: &str, query: &str, encoded: &EncodedRows) -> Result<()> {
        self.insert_retrying(table, query, encoded, true).await
    }

    /// Sends rows that only mean anything all together, retrying them whole
    /// whatever failed.
    pub async fn insert_whole(
        &self,
        table: &str,
        query: &str,
        encoded: &EncodedRows,
    ) -> Result<()> {
        self.insert_retrying(table, query, encoded, false).await
    }

    async fn insert_retrying(
        &self,
        table: &str,
        query: &str,
        encoded: &EncodedRows,
        may_halve: bool,
    ) -> Result<()> {
        if encoded.rows() == 0 {
            return Ok(());
        }
        let mut failures = 0usize;
        let started = std::time::Instant::now();
        let mut pending = vec![(0usize, encoded.rows(), self.tuning.retries)];
        while let Some((start, end, retries)) = pending.pop() {
            match self.post_rows(query, encoded.slice(start, end)).await {
                Ok(()) => continue,
                Err(failure) => {
                    let spent = started.elapsed();
                    let out_of_budget = spent >= self.tuning.retry_budget;
                    if retries == 0
                        || out_of_budget
                        || matches!(failure.retry, Retry::Never | Retry::Ambiguous)
                    {
                        return Err(match (failures, out_of_budget) {
                            (0, _) => failure.error,
                            (n, false) => failure
                                .error
                                .context(format!("after {n} failed attempt(s)")),
                            (n, true) => failure.error.context(format!(
                                "after {n} failed attempt(s) over {spent:.1?}, which is all the \
                                 time one batch may spend retrying"
                            )),
                        });
                    }
                    failures += 1;
                    let rows = end - start;
                    (self.warn)(&format!(
                        "ClickHouse insert of {rows} row(s) into `{table}` failed, \
                         {retries} retries left: {:#}",
                        failure.error
                    ));
                    tokio::time::sleep(self.tuning.delay(retries)).await;
                    match failure.retry {
                        Retry::Halved if may_halve && rows > 1 => {
                            let mid = start + rows / 2;
                            pending.push((mid, end, retries - 1));
                            pending.push((start, mid, retries - 1));
                        }
                        _ => pending.push((start, end, retries - 1)),
                    }
                }
            }
        }
        Ok(())
    }

    async fn post_rows(&self, query: &str, body: Bytes) -> std::result::Result<(), InsertFailure> {
        // Synchronous whatever the server's profile says: an asynchronous
        // insert can be acknowledged before its rows are written, and a write
        // is only committed once every row it covers has landed. A token of its
        // own, so it is never deduplicated: a batch replayed after a resume
        // trimmed it is the same bytes as before, and an engine that
        // deduplicates (ClickHouse Cloud's does by default) would drop it while
        // answering success. The setting that turns deduplication off is named
        // differently across server versions; the token works on all of them.
        let token = insert_token();
        let request = self
            .http
            .post(&self.url)
            .query(&[
                ("query", query),
                ("database", &self.database),
                ("async_insert", "0"),
                ("insert_deduplication_token", &token),
            ])
            // Base64 of the credentials rather than the X-ClickHouse-User/Key
            // headers: a header value may only carry visible ASCII, so a password
            // with a non-ASCII character in it fails every request before it is
            // sent. `@clickhouse/client` authenticated this way too.
            .basic_auth(&self.username, Some(&self.password))
            .header("Content-Type", "application/octet-stream")
            .body(body);
        let response = match request.send().await {
            Ok(response) => response,
            Err(err) => {
                return Err(InsertFailure {
                    retry: retry_for_send_error(&err),
                    error: anyhow::Error::new(err).context("ClickHouse insert request failed"),
                });
            }
        };
        if let Err(error) = self.check_served_by(&response) {
            return Err(InsertFailure {
                retry: Retry::Never,
                error,
            });
        }
        let status = response.status();
        if status.is_success() {
            return Ok(());
        }
        let text = response.text().await.unwrap_or_default();
        Err(InsertFailure {
            retry: retry_for(status, &text),
            error: anyhow!("ClickHouse returned {status}: {text}"),
        })
    }
}

struct InsertFailure {
    error: anyhow::Error,
    retry: Retry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Retry {
    Never,
    SameRows,
    Halved,
    /// The server may already have the rows. Another send would double-write,
    /// so the batch fails and a restart trims back to the committed checkpoint.
    Ambiguous,
}

/// Conditions a smaller batch is answered differently by, because what ran out
/// was proportional to the batch's size. Resending is safe for a table in one
/// partition, where an insert commits a single part or none; an entity with its
/// own `partitionBy` writes a part per partition, and one of those already
/// committed would be sent again — the reads' `LIMIT 1 BY` reads past the
/// duplicate, a direct query of the history table does not.
/// A resend can leave the same rows in the history table twice: insert dedup is
/// off on purpose (see `Topology::settings`) so trim-then-replay recovery works.
/// Duplicates cost storage, not correctness — every read collapses them with
/// `LIMIT 1 BY`, and a resent row repeats the id, checkpoint id and values of
/// the one it duplicates. So a verdict answers whether sending again has a
/// mechanism to go differently, not whether the rows could already have landed:
/// a batch that outran a deadline or a memory limit fits once it is smaller.
const HALVED_ERROR_CODES: &[u32] = &[
    173, // CANNOT_ALLOCATE_MEMORY
    241, // MEMORY_LIMIT_EXCEEDED
    159, // TIMEOUT_EXCEEDED
    209, // SOCKET_TIMEOUT
];

/// Failures that say nothing about size or reachability, so a resend is only the
/// same request again for the same likely answer.
const AMBIGUOUS_ERROR_CODES: &[u32] = &[
    210, // NETWORK_ERROR
    319, // UNKNOWN_STATUS_OF_INSERT
];

/// Codes that say the deployment or the rows are what failed — a table that is
/// not there, credentials the server does not accept, a value it cannot read.
/// No retry of any size talks it out of one.
const NEVER_ERROR_CODES: &[u32] = &[
    6,   // CANNOT_PARSE_TEXT
    16,  // NO_SUCH_COLUMN_IN_TABLE
    27,  // CANNOT_PARSE_INPUT_ASSERTION_FAILED
    33,  // CANNOT_READ_ALL_DATA
    44,  // ILLEGAL_COLUMN
    47,  // UNKNOWN_IDENTIFIER
    53,  // TYPE_MISMATCH
    60,  // UNKNOWN_TABLE
    62,  // SYNTAX_ERROR
    81,  // UNKNOWN_DATABASE
    117, // INCORRECT_DATA
    192, // UNKNOWN_USER
    193, // WRONG_PASSWORD
    194, // REQUIRED_PASSWORD
    497, // ACCESS_DENIED
    516, // AUTHENTICATION_FAILED
];

/// A request that never reached the server carries no risk of a double write, so
/// it is resent whole. A timeout is resent smaller: the deadline is the one
/// thing a halved batch meets differently, whether it ran out mid-upload or
/// waiting on the server to finish. Anything else that failed after the body
/// went out leaves the same unknown as 319.
/// Unique to this insert among every process writing to the database.
fn insert_token() -> String {
    static STARTED: std::sync::OnceLock<u128> = std::sync::OnceLock::new();
    static SENT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let started = STARTED.get_or_init(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos())
    });
    format!(
        "envio-{}-{started}-{}",
        std::process::id(),
        SENT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    )
}

fn retry_for_send_error(err: &reqwest::Error) -> Retry {
    if err.is_connect() {
        Retry::SameRows
    } else if err.is_timeout() {
        Retry::Halved
    } else {
        Retry::Ambiguous
    }
}

/// A code nobody has classified is retried rather than surfaced: an overloaded
/// server has far more codes for saying so than this file can enumerate, and the
/// retry budget bounds what being wrong costs. Only the lists above,
/// and a 4xx the server never wrote, end a write on the first answer.
fn retry_for(status: reqwest::StatusCode, body: &str) -> Retry {
    match error_code(body) {
        Some(code) if HALVED_ERROR_CODES.contains(&code) => Retry::Halved,
        Some(code) if AMBIGUOUS_ERROR_CODES.contains(&code) => Retry::Ambiguous,
        Some(code) if NEVER_ERROR_CODES.contains(&code) => Retry::Never,
        Some(_) => Retry::SameRows,
        // Nothing in the body is ClickHouse's, so something in front of it
        // answered — a proxy or load balancer — and only its status says what.
        None => match status {
            // A body-size limit is the one proxy verdict a smaller batch meets
            // differently. Left unretried, a batch that outgrows the limit fails
            // the same way on every restart.
            reqwest::StatusCode::PAYLOAD_TOO_LARGE => Retry::Halved,
            // Rate limiting counts requests, so halving spends the budget
            // faster, and a 5xx from in front of ClickHouse is the same shape of
            // answer — an overloaded proxy, a refused upstream.
            reqwest::StatusCode::TOO_MANY_REQUESTS => Retry::SameRows,
            status if status.is_server_error() => Retry::SameRows,
            // Any other 4xx is the deployment's own configuration —
            // credentials, a route — which no smaller batch talks it out of.
            _ => Retry::Never,
        },
    }
}

/// The code out of a ClickHouse error body. A proxy in front of the server can
/// quote a `Code:` of its own, so the marker ClickHouse puts in every exception
/// it writes is what makes the number the server's own verdict rather than
/// someone else's.
pub fn error_code(body: &str) -> Option<u32> {
    if !body.contains("DB::Exception") {
        return None;
    }
    let digits: String = body
        .split_once("Code: ")?
        .1
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use crate::clickhouse::mock_server::MockClickHouse;

    pub struct TestClient {
        pub client: Client,
        warnings: Arc<Mutex<Vec<String>>>,
    }

    impl TestClient {
        pub fn warnings(&self) -> Vec<String> {
            self.warnings.lock().unwrap().clone()
        }
    }

    impl std::ops::Deref for TestClient {
        type Target = Client;
        fn deref(&self) -> &Client {
            &self.client
        }
    }

    pub fn connection(url: String) -> Connection {
        Connection {
            url,
            username: "default".to_string(),
            password: String::new(),
            database: "mock".to_string(),
        }
    }

    pub fn client_at(url: String, tuning: Tuning) -> TestClient {
        let warnings = Arc::new(Mutex::new(Vec::new()));
        let collected = warnings.clone();
        let client = Client::new(
            connection(url),
            tuning,
            Arc::new(move |message: &str| collected.lock().unwrap().push(message.to_string())),
        )
        .unwrap();
        TestClient { client, warnings }
    }

    pub fn client_for(server: &MockClickHouse, retries: u32) -> TestClient {
        client_at(
            server.url.clone(),
            Tuning {
                retries,
                max_retry_delay: Duration::ZERO,
                ..Tuning::default()
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use crate::clickhouse::mock_server::MockClickHouse;
    use pretty_assertions::assert_eq;

    /// Rows of a single `String` column, as RowBinary carries them.
    fn strings(values: &[&str]) -> EncodedRows {
        let mut body = Vec::new();
        let mut row_offsets = Vec::new();
        for value in values {
            row_offsets.push(body.len());
            body.push(value.len() as u8);
            body.extend_from_slice(value.as_bytes());
        }
        EncodedRows {
            body: body.into(),
            row_offsets,
        }
    }

    async fn insert(client: &Client, values: &[&str]) -> Result<()> {
        client
            .insert(
                "envio_checkpoints",
                "INSERT INTO `envio_checkpoints` (`id`) FORMAT RowBinary",
                &strings(values),
            )
            .await
    }

    fn reason(error: anyhow::Error) -> String {
        format!("{error:#}")
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_answer_from_a_second_node_fails_the_statement() {
        let server =
            MockClickHouse::answering_statements(Arc::new(|_: &str| (200, String::new()))).await;
        let client = client_for(&server, 4);
        server.serve_as("node-a");
        client.statement("SELECT 1".to_string()).await.unwrap();
        server.serve_as("node-b");

        let err = client.statement("SELECT 1".to_string()).await.unwrap_err();

        assert_eq!(reason(err).contains("answered from node \"node-b\""), true);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_insert_answered_by_a_second_node_fails_without_retrying() {
        let server = MockClickHouse::start(0).await;
        let client = client_for(&server, 4);
        server.serve_as("node-a");
        insert(&client, &["a"]).await.unwrap();
        server.serve_as("node-b");

        let err = insert(&client, &["b"]).await.unwrap_err();

        assert_eq!(
            (
                reason(err).contains("answered from node"),
                server.inserts_seen()
            ),
            (true, 2)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_rejected_insert_is_retried_as_halves_and_every_row_lands_once() {
        let server = MockClickHouse::start(1).await;
        let client = client_for(&server, 4);

        insert(&client, &["a", "b", "c", "d"]).await.unwrap();

        assert_eq!(
            (
                server.accepted_strings(),
                server.inserts_seen(),
                client.warnings().len()
            ),
            (
                vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ],
                3,
                1
            )
        );
    }

    // The chains' rows are the commit: half of them landing would move some
    // chains' frontiers and not the others'.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_insert_that_must_land_whole_is_retried_whole() {
        let server = MockClickHouse::start(1).await;
        let client = client_for(&server, 4);

        client
            .insert_whole(
                "envio_chains",
                "INSERT INTO `envio_chains` (`id`) FORMAT RowBinary",
                &strings(&["a", "b", "c", "d"]),
            )
            .await
            .unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (
                vec![vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ]],
                2
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_condition_the_batch_is_not_to_blame_for_is_retried_whole() {
        let server = MockClickHouse::rejecting_with(
            2,
            "Code: 242. DB::Exception: Table is in readonly mode",
        )
        .await;
        let client = client_for(&server, 4);

        insert(&client, &["a", "b", "c", "d"]).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (
                vec![vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ]],
                3
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_batch_too_large_for_a_proxy_is_retried_in_halves() {
        let server = MockClickHouse::rejecting_with_status(
            1,
            413,
            "<html>413 Request Entity Too Large</html>",
        )
        .await;
        let client = client_for(&server, 4);

        insert(&client, &["a", "b", "c", "d"]).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (
                vec![
                    vec!["a".to_string(), "b".to_string()],
                    vec!["c".to_string(), "d".to_string()]
                ],
                3
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_proxy_that_is_overloaded_is_retried_whole() {
        let server = MockClickHouse::rejecting_with_status(
            2,
            503,
            "<html>503 Service Temporarily Unavailable</html>",
        )
        .await;
        let client = client_for(&server, 4);

        insert(&client, &["a", "b", "c", "d"]).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (
                vec![vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ]],
                3
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_proxy_rejection_a_smaller_batch_cannot_answer_is_not_retried() {
        let server = MockClickHouse::rejecting_with_status(usize::MAX, 403, "Forbidden").await;
        let client = client_for(&server, 8);

        let err = reason(insert(&client, &["a", "b"]).await.unwrap_err());

        assert_eq!(
            (err.contains("403"), server.inserts_seen()),
            (true, 1),
            "expected a single attempt and the proxy's status, got: {err}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_single_row_is_retried_in_place_until_it_lands() {
        let server = MockClickHouse::start(2).await;
        let client = client_for(&server, 4);

        insert(&client, &["only"]).await.unwrap();

        assert_eq!(
            (server.accepted_strings(), server.inserts_seen()),
            (vec!["only".to_string()], 3)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_insert_that_never_succeeds_surfaces_the_error() {
        let server = MockClickHouse::start(usize::MAX).await;
        let client = client_for(&server, 2);

        let err = reason(insert(&client, &["a", "b"]).await.unwrap_err());

        assert_eq!(
            (err.contains("mock rejection"), server.accepted_strings()),
            (true, Vec::<String>::new()),
            "expected the server's message, got: {err}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_rejection_the_rows_are_to_blame_for_is_not_retried() {
        let server = MockClickHouse::rejecting_with(
            usize::MAX,
            "Code: 60. DB::Exception: Table mock.t does not exist",
        )
        .await;
        let client = client_for(&server, 8);

        let err = reason(insert(&client, &["a", "b", "c", "d"]).await.unwrap_err());

        assert_eq!(
            (
                err.contains("does not exist"),
                server.inserts_seen(),
                client.warnings()
            ),
            (true, 1, Vec::<String>::new()),
            "expected one attempt and the server's message, got: {err}"
        );
    }

    /// An address nothing listens on, so every connection to it is refused.
    async fn refused_url() -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        url
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_refused_connection_is_retried() {
        let client = client_at(
            refused_url().await,
            Tuning {
                retries: 3,
                max_retry_delay: Duration::ZERO,
                ..Tuning::default()
            },
        );

        let err = reason(insert(&client, &["a"]).await.unwrap_err());

        assert_eq!(
            (
                err.contains("ClickHouse insert request failed"),
                client.warnings().len(),
                client
                    .warnings()
                    .first()
                    .is_some_and(|warning| warning.contains("3 retries left")),
            ),
            (true, 3, true),
            "expected three retries counted down from three, got: {:?} / {err}",
            client.warnings(),
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_transient_code_nobody_listed_is_retried_whole() {
        let server =
            MockClickHouse::rejecting_with(2, "Code: 439. DB::Exception: Cannot schedule a task")
                .await;
        let client = client_for(&server, 4);

        insert(&client, &["a", "b"]).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (vec![vec!["a".to_string(), "b".to_string()]], 3)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_proxy_page_quoting_a_code_is_read_as_the_proxys_own() {
        let server =
            MockClickHouse::rejecting_with_status(1, 502, "Error Code: 60. upstream unavailable")
                .await;
        let client = client_for(&server, 4);

        insert(&client, &["a", "b"]).await.unwrap();

        assert_eq!(
            (server.accepted_batches(), server.inserts_seen()),
            (vec![vec!["a".to_string(), "b".to_string()]], 2)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_insert_whose_status_is_unknown_is_not_resent() {
        let server = MockClickHouse::accepting_then_erroring(
            1,
            "Code: 319. DB::Exception: Unknown status of insert",
        )
        .await;
        let client = client_for(&server, 4);

        let err = reason(insert(&client, &["a", "b", "c", "d"]).await.unwrap_err());

        assert_eq!(
            (
                err.contains("319"),
                server.inserts_seen(),
                server.accepted_batches(),
            ),
            (
                true,
                1,
                vec![vec![
                    "a".to_string(),
                    "b".to_string(),
                    "c".to_string(),
                    "d".to_string()
                ]],
            ),
            "expected one accepted insert of the original four, got: {err}"
        );
    }

    /// The row counts each warning reports, in order — the shape of the retry
    /// ladder a batch walked before giving up.
    fn retried_row_counts(client: &TestClient) -> Vec<String> {
        client
            .warnings()
            .iter()
            .filter_map(|warning| {
                let rest = warning.strip_prefix("ClickHouse insert of ")?;
                let (count, _) = rest.split_once(" row(s)")?;
                Some(count.to_string())
            })
            .collect()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_request_that_times_out_is_retried_as_halves() {
        let server = MockClickHouse::start_unresponsive().await;
        let client = client_at(
            server.url.clone(),
            Tuning {
                retries: 3,
                max_retry_delay: Duration::ZERO,
                request_timeout: Duration::from_millis(150),
                statement_timeout: Duration::from_millis(150),
                ..Tuning::default()
            },
        );

        let err = reason(insert(&client, &["a", "b", "c", "d"]).await.unwrap_err());

        assert_eq!(
            (
                retried_row_counts(&client),
                err.contains("operation timed out"),
            ),
            (
                vec!["4".to_string(), "2".to_string(), "1".to_string()],
                true
            ),
            "expected the batch to be halved on the way down, got: {err}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_batch_stops_retrying_once_it_is_out_of_time() {
        let client = client_at(
            refused_url().await,
            Tuning {
                retries: 8,
                max_retry_delay: Duration::ZERO,
                retry_budget: Duration::ZERO,
                ..Tuning::default()
            },
        );

        let err = reason(insert(&client, &["a", "b", "c", "d"]).await.unwrap_err());

        assert_eq!(
            (
                retried_row_counts(&client),
                err.contains("ClickHouse insert request failed"),
            ),
            (Vec::<String>::new(), true),
            "expected the first failure to end the batch, got: {err}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_server_that_never_answers_times_out_rather_than_hanging() {
        let server = MockClickHouse::start_unresponsive().await;
        let client = client_at(
            server.url.clone(),
            Tuning {
                retries: 1,
                max_retry_delay: Duration::ZERO,
                request_timeout: Duration::from_millis(150),
                statement_timeout: Duration::from_millis(150),
                ..Tuning::default()
            },
        );

        let err = reason(insert(&client, &["a"]).await.unwrap_err());

        assert_eq!(
            err.contains("operation timed out"),
            true,
            "expected a timeout, got: {err}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_non_ascii_password_still_authenticates() {
        let server = MockClickHouse::start(0).await;
        let client = Client::new(
            Connection {
                username: "défaut".to_string(),
                password: "pässwörd".to_string(),
                ..connection(server.url.clone())
            },
            Tuning::default(),
            Arc::new(|_: &str| ()),
        )
        .unwrap();

        insert(&client, &["a"]).await.unwrap();

        let head = server.heads().first().cloned().unwrap_or_default();
        assert_eq!(
            (
                head.to_lowercase().contains(
                    "authorization: basic ZMOpZmF1dDpww6Rzc3fDtnJk"
                        .to_lowercase()
                        .as_str()
                ),
                head.contains("database=mock"),
                server.accepted_strings()
            ),
            (true, true, vec!["a".to_string()]),
            "expected a Basic credential, got head: {head}"
        );
    }

    #[test]
    fn a_proxy_quoting_a_code_is_not_clickhouse() {
        assert_eq!(
            (
                error_code("Code: 60. DB::Exception: Table x does not exist"),
                error_code("Error Code: 60. upstream unavailable"),
            ),
            (Some(60), None)
        );
    }
}
