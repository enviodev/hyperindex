use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;

use super::row_binary::EncodedRows;
use super::select::{External, Read, EXTERNAL_STRUCTURE};

const MAX_RETRIES: u32 = 8;

/// Without it a peer that accepts a connection and then goes silent — a
/// black-holed socket through a load balancer sends neither RST nor FIN —
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
/// How long a pooled socket may sit idle before the client drops it, until the
/// server says how long it keeps one. Deliberately under ClickHouse's own
/// `keep_alive_timeout` (3s on older servers), which is the deadline that
/// matters: past it the server closes the socket, and a batch dispatched onto
/// one already carrying a FIN fails with `connection closed before message
/// completed`.
const POOL_IDLE_TIMEOUT: Duration = Duration::from_millis(2_500);
const MAX_RETRY_DELAY: Duration = Duration::from_millis(1_000);
/// How long one batch may spend on the whole retry ladder. Halving turns a
/// failure into two more attempts, so a range that keeps failing costs
/// exponentially many requests — cheap when each is refused in milliseconds,
/// hours when each one first has to reach [`REQUEST_TIMEOUT`] against a peer
/// that accepts the connection and then goes silent. `retries` bounds how deep
/// a single range may go; this bounds what the batch as a whole may cost.
const RETRY_BUDGET: Duration = Duration::from_secs(120);
/// The server's caps on a statement unless a request raises them: its length,
/// and the elements it parses into before and after expanding aliases.
const DEFAULT_MAX_QUERY_SIZE: usize = 256 * 1024;
const DEFAULT_MAX_AST_ELEMENTS: usize = 50_000;
const DEFAULT_MAX_EXPANDED_AST_ELEMENTS: usize = 500_000;

/// A load spelling a long list of values runs past the server's caps on a
/// statement: on its length, and on its elements, several of which a value
/// spelled as a call makes. Every element takes a byte of the statement at
/// least, so its length is a cap it never runs into; expanding aliases adds
/// what referencing one adds, no more than the statement again.
fn long_statement_settings(sql: &str) -> Vec<(&'static str, String)> {
    let length = sql.len();
    let mut settings = Vec::new();
    if length > DEFAULT_MAX_QUERY_SIZE {
        settings.push(("max_query_size", (length + 1).to_string()));
    }
    if length > DEFAULT_MAX_AST_ELEMENTS {
        settings.push(("max_ast_elements", length.to_string()));
        settings.push((
            "max_expanded_ast_elements",
            (2 * length)
                .max(DEFAULT_MAX_EXPANDED_AST_ELEMENTS)
                .to_string(),
        ));
    }
    settings
}

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
    /// The pool and the idle timeout it was built with. Rebuilt when the server
    /// says how long it keeps an idle socket, which a pool's settings can't
    /// change once built.
    http: RwLock<(reqwest::Client, Duration)>,
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
    tag: Mutex<String>,
}

fn http_client(tuning: &Tuning, idle_timeout: Duration) -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .pool_idle_timeout(idle_timeout)
        .pool_max_idle_per_host(8)
        .timeout(tuning.request_timeout)
        .connect_timeout(CONNECT_TIMEOUT)
        .tcp_keepalive(TCP_KEEPALIVE)
        // reqwest picks up HTTP_PROXY/HTTPS_PROXY by default, which would
        // silently route a deployment's inserts through a proxy nothing asked
        // to be in the path.
        .no_proxy()
        .build()
        .context("Failed building HTTP client")
}

/// A second under how long a `Keep-Alive` answer says the server keeps an
/// idle socket open, so the pool lets go of it first.
fn idle_timeout_of(keep_alive: &str) -> Option<Duration> {
    keep_alive
        .split(',')
        .find_map(|part| part.trim().strip_prefix("timeout="))?
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|seconds| *seconds > 1)
        .map(|seconds| Duration::from_secs(seconds - 1))
}

impl Client {
    pub fn new(connection: Connection, tuning: Tuning, warn: Warn) -> Result<Self> {
        // `localhost:8123` parses too, as a URL whose scheme is `localhost`.
        let reachable = reqwest::Url::parse(&connection.url)
            .is_ok_and(|url| matches!(url.scheme(), "http" | "https") && url.has_host());
        if !reachable {
            bail!(
                "ENVIO_CLICKHOUSE_HOST \"{}\" is not a URL the indexer can reach: give its scheme \
                 and port, as in http://localhost:8123",
                connection.url
            );
        }
        Ok(Self {
            http: RwLock::new((http_client(&tuning, POOL_IDLE_TIMEOUT)?, POOL_IDLE_TIMEOUT)),
            url: connection.url.trim_end_matches('/').to_string(),
            username: connection.username,
            password: connection.password,
            tag: Mutex::new(insert_tag(&connection.database, &[])),
            database: connection.database,
            tuning,
            warn,
            served_by: Mutex::new(None),
        })
    }

    fn http(&self) -> reqwest::Client {
        self.http.read().unwrap().0.clone()
    }

    #[cfg(test)]
    fn idle_timeout(&self) -> Duration {
        self.http.read().unwrap().1
    }

    /// Keeps idle sockets as long as the answer says the server does. A pool
    /// that can't be rebuilt keeps the one it has: it only reconnects more.
    fn learn_keep_alive(&self, response: &reqwest::Response) {
        let Some(timeout) = response
            .headers()
            .get("Keep-Alive")
            .and_then(|value| value.to_str().ok())
            .and_then(idle_timeout_of)
        else {
            return;
        };
        let mut http = self.http.write().unwrap();
        if http.1 == timeout {
            return;
        }
        if let Ok(client) = http_client(&self.tuning, timeout) {
            *http = (client, timeout);
        }
    }

    pub fn tag_inserts(&self, chain_ids: &[i64]) {
        *self.tag.lock().unwrap() = insert_tag(&self.database, chain_ids);
    }

    pub async fn statement(&self, query: String) -> Result<String> {
        let body = self.read(query).await?;
        Ok(String::from_utf8_lossy(&body).into_owned())
    }

    pub async fn read(&self, query: String) -> Result<Bytes> {
        self.read_with(Read {
            sql: query,
            external: Vec::new(),
        })
        .await
    }

    pub async fn read_with(&self, read: Read) -> Result<Bytes> {
        self.post(read)
            .await?
            .bytes()
            .await
            .context("ClickHouse's answer broke off before its end")
    }

    /// Every statement the store sends this way is a read or idempotent, so one
    /// is sent again for what goes away by itself: a pooled connection the
    /// server closed while idle, an overloaded server or proxy. Not for what an
    /// insert would be halved for: a statement can't be, and the same one runs
    /// out of the same memory or deadline again. One that timed out after
    /// reaching the server already spent the whole statement timeout.
    async fn post(&self, read: Read) -> Result<reqwest::Response> {
        // External data goes as a form, and the statement with it: a body has
        // to be one or the other.
        let params = long_statement_settings(&read.sql);
        let (content_type, body) = if read.external.is_empty() {
            (None, Bytes::from(read.sql))
        } else {
            let (boundary, form) = multipart(&read.sql, &read.external);
            (
                Some(format!("multipart/form-data; boundary={boundary}")),
                Bytes::from(form),
            )
        };
        let mut retries_left = self.tuning.retries;
        loop {
            // Held until the query has finished, so one that fails after its
            // first rows would have been sent answers with an error status.
            let mut request = self
                .http()
                .post(&self.url)
                .timeout(self.tuning.statement_timeout)
                .query(&[("wait_end_of_query", "1")])
                .query(&params)
                .basic_auth(&self.username, Some(&self.password))
                .body(body.clone());
            if let Some(content_type) = &content_type {
                request = request.header(reqwest::header::CONTENT_TYPE, content_type);
            }
            let failure = match request.send().await {
                Ok(response) => match self.answer(response).await {
                    Ok(response) => return Ok(response),
                    Err(failure) => failure,
                },
                Err(error) => Failure::of_send(error, "ClickHouse request failed", &self.url),
            };
            if failure.retry != Retry::SameRows || retries_left == 0 {
                return Err(failure.error);
            }
            (self.warn)(&format!(
                "ClickHouse request failed, {retries_left} retries left: {:#}",
                failure.error
            ));
            tokio::time::sleep(self.tuning.delay(retries_left)).await;
            retries_left -= 1;
        }
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
            let Err(failure) = self.post_rows(query, encoded.slice(start, end)).await else {
                continue;
            };
            let spent = started.elapsed();
            let out_of_budget = spent >= self.tuning.retry_budget;
            if retries == 0 || out_of_budget || failure.retry == Retry::Never {
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
        Ok(())
    }

    async fn post_rows(&self, query: &str, body: Bytes) -> std::result::Result<(), Failure> {
        // Synchronous whatever the server's profile says: an asynchronous
        // insert can be acknowledged before its rows are written, and a write
        // is only committed once every row it covers has landed. A token of its
        // own, so it is never deduplicated: a batch replayed after a resume
        // trimmed it is the same bytes as before, and an engine that
        // deduplicates (ClickHouse Cloud's does by default) would drop it while
        // answering success. The setting that turns deduplication off is named
        // differently across server versions; the token works on all of them.
        let token = insert_token();
        let query_id = format!("{}{token}", self.tag.lock().unwrap());
        let request = self
            .http()
            .post(&self.url)
            .query(&[
                ("query", query),
                ("database", &self.database),
                ("async_insert", "0"),
                ("insert_deduplication_token", &token),
                ("query_id", &query_id),
            ])
            // Base64 of the credentials rather than the X-ClickHouse-User/Key
            // headers: a header value may only carry visible ASCII, so a password
            // with a non-ASCII character in it fails every request before it is
            // sent.
            .basic_auth(&self.username, Some(&self.password))
            .header("Content-Type", "application/octet-stream")
            .body(body);
        let response = request.send().await.map_err(|error| {
            Failure::of_send(error, "ClickHouse insert request failed", &self.url)
        })?;
        self.answer(response).await.map(drop)
    }

    /// A response that succeeded, or what its failure was.
    async fn answer(
        &self,
        response: reqwest::Response,
    ) -> std::result::Result<reqwest::Response, Failure> {
        self.learn_keep_alive(&response);
        if let Err(error) = self.check_served_by(&response) {
            return Err(Failure {
                retry: Retry::Never,
                error,
            });
        }
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let text = response.text().await.unwrap_or_default();
        Err(Failure {
            retry: retry_for(status, &text),
            error: anyhow!("ClickHouse returned {status}: {text}"),
        })
    }
}

struct Failure {
    error: anyhow::Error,
    retry: Retry,
}

impl Failure {
    /// A timeout is resent smaller: the deadline is the one thing a halved
    /// batch meets differently, whether it ran out mid-upload or waiting on the
    /// server to finish. A connect timeout never reached the server, so it is
    /// resent whole.
    fn of_send(error: reqwest::Error, context: &'static str, url: &str) -> Self {
        let context = if error.is_connect() {
            format!(
                "Couldn't connect to ClickHouse at {url}. Check that it is running and that \
                 ENVIO_CLICKHOUSE_HOST points at it"
            )
        } else {
            context.to_string()
        };
        Self {
            retry: if error.is_timeout() && !error.is_connect() {
                Retry::Halved
            } else {
                Retry::SameRows
            },
            error: anyhow!(said_once(&error)).context(context),
        }
    }
}

/// An error and its causes, each said once: hyper's messages already end with
/// their sources', so the plain chain repeats a refused connection four times.
fn said_once(error: &(dyn std::error::Error + 'static)) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        let said = cause.to_string();
        if !text.ends_with(&said) {
            text = format!("{text}: {said}");
        }
        source = cause.source();
    }
    text
}

/// What sending a failed insert again can change. Whether the server already
/// took the rows doesn't come into it: every insert carries a token of its own
/// (see `post_rows`), so a resend can land them twice, and that costs storage
/// rather than correctness — every read keeps one row per key and checkpoint
/// (`argMax` in handler loads, `LIMIT 1 BY` in the views and rollbacks), a
/// resent row repeats the values of the one it duplicates, and the chains' rows
/// replace each other by version. Only a direct query of a history table sees
/// a duplicate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Retry {
    Never,
    SameRows,
    Halved,
}

/// Conditions a smaller batch is answered differently by, because what ran out
/// was proportional to the batch's size: a batch that outran a deadline or a
/// memory limit fits once it is smaller.
const HALVED_ERROR_CODES: &[u32] = &[
    173, // CANNOT_ALLOCATE_MEMORY
    241, // MEMORY_LIMIT_EXCEEDED
    159, // TIMEOUT_EXCEEDED
    209, // SOCKET_TIMEOUT
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
    164, // READONLY
    192, // UNKNOWN_USER
    193, // WRONG_PASSWORD
    194, // REQUIRED_PASSWORD
    497, // ACCESS_DENIED
    516, // AUTHENTICATION_FAILED
];

/// A statement and its external data as the form ClickHouse reads them: the
/// statement and each table's description as fields, each table's rows as a
/// file. The rows are binary, so the boundary is one nothing in the form
/// happens to contain.
fn multipart(sql: &str, external: &[External]) -> (String, Vec<u8>) {
    let mut fields = vec![("query".to_string(), sql.to_string())];
    for table in external {
        fields.push((
            format!("{}_structure", table.name),
            EXTERNAL_STRUCTURE.to_string(),
        ));
        fields.push((format!("{}_format", table.name), "RowBinary".to_string()));
    }
    let contains = |bytes: &[u8], boundary: &str| {
        bytes
            .windows(boundary.len())
            .any(|window| window == boundary.as_bytes())
    };
    let boundary = (0..)
        .map(|attempt| format!("envio-external-data-{attempt}"))
        .find(|boundary| {
            !external.iter().any(|table| contains(&table.rows, boundary))
                && !contains(sql.as_bytes(), boundary)
        })
        .expect("an unbounded range always yields a boundary");
    let mut form = Vec::new();
    for (name, value) in &fields {
        form.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            )
            .as_bytes(),
        );
    }
    for table in external {
        form.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; \
                 filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
                name = table.name
            )
            .as_bytes(),
        );
        form.extend_from_slice(&table.rows);
        form.extend_from_slice(b"\r\n");
    }
    form.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
    (boundary, form)
}

/// What every insert of a process driving `chain_ids` in `database` starts its
/// query id with, so the next process driving any of them can find the ones it
/// left running. The chains sit between commas, each findable as `,<id>,`.
pub fn insert_tag(database: &str, chain_ids: &[i64]) -> String {
    let mut chain_ids = chain_ids.to_vec();
    chain_ids.sort_unstable();
    let chains = chain_ids
        .iter()
        .map(i64::to_string)
        .collect::<Vec<_>>()
        .join(",");
    format!("{},{chains},:", insert_tag_prefix(database))
}

/// What every [`insert_tag`] in `database` starts with, whatever its chains.
pub fn insert_tag_prefix(database: &str) -> String {
    format!("envio:{database}:")
}

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

/// A code nobody has classified is retried rather than surfaced: an overloaded
/// server has far more codes for saying so than this file can enumerate, and the
/// retry budget bounds what being wrong costs. Only the lists above,
/// and a 4xx the server never wrote, end a write on the first answer.
fn retry_for(status: reqwest::StatusCode, body: &str) -> Retry {
    match error_code(body) {
        Some(code) if HALVED_ERROR_CODES.contains(&code) => Retry::Halved,
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

    pub fn connection(url: String) -> Connection {
        Connection {
            url,
            username: "default".to_string(),
            password: String::new(),
            database: "mock".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use crate::clickhouse::ch_type::ChType;
    use crate::clickhouse::mock_server::MockClickHouse;
    use crate::clickhouse::row_binary::{encode_values, Value};
    use pretty_assertions::assert_eq;

    struct TestClient {
        client: Client,
        warnings: Arc<Mutex<Vec<String>>>,
    }

    impl TestClient {
        fn warnings(&self) -> Vec<String> {
            self.warnings.lock().unwrap().clone()
        }
    }

    impl std::ops::Deref for TestClient {
        type Target = Client;
        fn deref(&self) -> &Client {
            &self.client
        }
    }

    fn client_at(url: String, tuning: Tuning) -> TestClient {
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

    fn client_for(server: &MockClickHouse, retries: u32) -> TestClient {
        client_at(
            server.url.clone(),
            Tuning {
                retries,
                max_retry_delay: Duration::ZERO,
                ..Tuning::default()
            },
        )
    }

    /// A client that gives up on any request after 150ms, retrying three times.
    fn client_timing_out(server: &MockClickHouse) -> TestClient {
        client_at(
            server.url.clone(),
            Tuning {
                retries: 3,
                max_retry_delay: Duration::ZERO,
                request_timeout: Duration::from_millis(150),
                statement_timeout: Duration::from_millis(150),
                ..Tuning::default()
            },
        )
    }

    /// Rows of a single `String` column, as RowBinary carries them.
    fn strings(values: &[&str]) -> EncodedRows {
        encode_values(
            &[ChType::String],
            &values
                .iter()
                .map(|value| vec![Value::Text(value.to_string())])
                .collect::<Vec<_>>(),
        )
        .unwrap()
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

    fn owned(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
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
    async fn a_read_on_a_connection_the_server_dropped_is_sent_again() {
        let server =
            MockClickHouse::dropping_reads(1, Arc::new(|_: &str| (200, "1".to_string()))).await;
        let client = client_for(&server, 4);

        let answer = client.statement("SELECT 1".to_string()).await;

        assert_eq!(
            (answer.map_err(reason), server.queries_seen()),
            (Ok("1".to_string()), 1)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_read_turned_away_for_now_is_sent_again() {
        let server = MockClickHouse::rejecting_reads(
            2,
            503,
            "Service Unavailable",
            Arc::new(|_: &str| (200, "1".to_string())),
        )
        .await;
        let client = client_for(&server, 4);

        let answer = client.statement("SELECT 1".to_string()).await;

        assert_eq!(
            (answer.map_err(reason), server.queries_seen()),
            (Ok("1".to_string()), 3)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_read_the_statement_is_to_blame_for_is_not_sent_again() {
        let server = MockClickHouse::rejecting_reads(
            1,
            400,
            "Code: 62. DB::Exception: Syntax error",
            Arc::new(|_: &str| (200, "1".to_string())),
        )
        .await;
        let client = client_for(&server, 4);

        let answer = client.statement("SELECT".to_string()).await;

        assert_eq!(
            (answer.map_err(reason), server.queries_seen()),
            (
                Err(
                    "ClickHouse returned 400 Bad Request: Code: 62. DB::Exception: Syntax error"
                        .to_string()
                ),
                1
            )
        );
    }

    /// A load names its ids beside the statement, as a form. The statement
    /// goes in the form too: a wide entity's spans kilobytes, more than a
    /// proxy in front of the server may take in a URL.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_read_with_external_data_keeps_its_statement_out_of_the_url() {
        let server =
            MockClickHouse::answering_statements(Arc::new(|_: &str| (200, String::new()))).await;
        let client = client_for(&server, 0);

        client
            .read_with(Read {
                sql: "SELECT 1 WHERE 'a' IN envio_list_0".to_string(),
                external: vec![External {
                    name: "envio_list_0".to_string(),
                    rows: b"\x01a".to_vec(),
                }],
            })
            .await
            .unwrap();

        let (head, form) = (server.heads().concat(), server.statements_seen().concat());
        assert_eq!(
            (
                head.contains("SELECT"),
                [
                    "name=\"query\"\r\n\r\nSELECT 1 WHERE 'a' IN envio_list_0\r\n",
                    "name=\"envio_list_0_structure\"\r\n\r\nvalue String\r\n",
                    "name=\"envio_list_0_format\"\r\n\r\nRowBinary\r\n",
                    "filename=\"envio_list_0\"",
                ]
                .map(|part| form.contains(part)),
            ),
            (false, [true; 4])
        );
    }

    /// A host given without its scheme would otherwise fail every request to
    /// it, and only after the whole retry ladder.
    #[test]
    fn a_host_without_a_scheme_is_refused_up_front() {
        let refused = Client::new(
            connection("localhost:8123".to_string()),
            Tuning::default(),
            Arc::new(|_: &str| {}),
        )
        .err()
        .map(|error| format!("{error:#}"));
        assert_eq!(
            refused,
            Some(
                "ENVIO_CLICKHOUSE_HOST \"localhost:8123\" is not a URL the indexer can reach: \
                 give its scheme and port, as in http://localhost:8123"
                    .to_string()
            )
        );
    }

    /// A socket reopened per request costs a handshake each time, and at the
    /// chain head requests come further apart than the pool's opening guess.
    /// The server says how long it keeps one, and the pool keeps it a second
    /// less; a value it can't read leaves the guess alone.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_pool_keeps_sockets_as_long_as_the_server_says() {
        let server =
            MockClickHouse::answering_statements(Arc::new(|_: &str| (200, "1".to_string()))).await;
        let client = client_for(&server, 0);
        let before = client.idle_timeout();
        server.keep_alive("timeout=30, max=9999");
        client.statement("SELECT 1".to_string()).await.unwrap();
        let announced = client.idle_timeout();
        server.keep_alive("max=9999");
        client.statement("SELECT 1".to_string()).await.unwrap();

        assert_eq!(
            (before, announced, client.idle_timeout()),
            (
                POOL_IDLE_TIMEOUT,
                Duration::from_secs(29),
                Duration::from_secs(29)
            )
        );
    }

    /// A statement can't be halved, and the same one runs out of the same
    /// memory again.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_read_too_big_for_the_server_is_not_sent_again() {
        let server = MockClickHouse::rejecting_reads(
            1,
            500,
            "Code: 241. DB::Exception: Memory limit (total) exceeded",
            Arc::new(|_: &str| (200, "1".to_string())),
        )
        .await;
        let client = client_for(&server, 4);

        let answer = client.statement("SELECT 1".to_string()).await;

        assert_eq!(
            (answer.map_err(reason), server.queries_seen()),
            (
                Err("ClickHouse returned 500 Internal Server Error: Code: 241. \
                     DB::Exception: Memory limit (total) exceeded"
                    .to_string()),
                1
            )
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_read_that_times_out_is_not_sent_again() {
        let server = MockClickHouse::start_unresponsive().await;
        let client = client_timing_out(&server);
        let started = std::time::Instant::now();

        let err = reason(client.statement("SELECT 1".to_string()).await.unwrap_err());

        assert_eq!(
            (
                err.contains("operation timed out"),
                started.elapsed() < Duration::from_millis(600)
            ),
            (true, true),
            "expected one timed out attempt, got: {err}"
        );
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
            (owned(&["a", "b", "c", "d"]), 3, 1)
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
            (vec![owned(&["a", "b", "c", "d"])], 2)
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
            (vec![owned(&["a", "b", "c", "d"])], 3)
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
            (vec![owned(&["a", "b"]), owned(&["c", "d"])], 3)
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
            (vec![owned(&["a", "b", "c", "d"])], 3)
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

    // A profile that forbids the settings the inserts send refuses every retry
    // the same way, so retrying only spends the budget.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_profile_refusing_the_settings_sent_is_not_retried() {
        let server = MockClickHouse::rejecting_with(
            usize::MAX,
            "Code: 164. DB::Exception: Cannot modify 'max_query_size' setting in readonly mode",
        )
        .await;
        let client = client_for(&server, 8);

        let err = reason(insert(&client, &["a", "b"]).await.unwrap_err());

        assert_eq!(
            (err.contains("readonly"), server.inserts_seen()),
            (true, 1),
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
                err.contains("Couldn't connect to ClickHouse"),
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

    /// What an operator reads when nothing answers at the configured host: the
    /// setting to check, and the cause said once.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_unreachable_server_names_the_host_setting() {
        let url = refused_url().await;
        let client = client_at(
            url.clone(),
            Tuning {
                retries: 0,
                ..Tuning::default()
            },
        );

        let err = reason(client.statement("SELECT 1".to_string()).await.unwrap_err());

        assert_eq!(
            err,
            format!(
                "Couldn't connect to ClickHouse at {url}. Check that it is running and that \
                 ENVIO_CLICKHOUSE_HOST points at it: error sending request for url \
                 ({url}/?wait_end_of_query=1): error trying to connect: tcp connect error: \
                 Connection refused (os error 111)"
            ),
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

    /// Every read collapses a row that landed twice, so an insert the server
    /// may or may not have taken is sent again rather than failing the batch.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_insert_whose_status_is_unknown_is_sent_again_whole() {
        let server = MockClickHouse::accepting_then_erroring(
            1,
            "Code: 319. DB::Exception: Unknown status of insert",
        )
        .await;
        let client = client_for(&server, 4);

        let sent = insert(&client, &["a", "b", "c", "d"]).await;

        let rows = owned(&["a", "b", "c", "d"]);
        assert_eq!(
            (
                sent.map_err(reason),
                server.inserts_seen(),
                server.accepted_batches(),
            ),
            (Ok(()), 2, vec![rows.clone(), rows]),
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
        let client = client_timing_out(&server);

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
                err.contains("Couldn't connect to ClickHouse"),
            ),
            (Vec::<String>::new(), true),
            "expected the first failure to end the batch, got: {err}"
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
