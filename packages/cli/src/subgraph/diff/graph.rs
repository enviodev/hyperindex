//! A graph-node GraphQL endpoint, read the way a parity check needs: its
//! `_meta`, its collection names, every id of a type, and entities by id.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use tokio::sync::Semaphore;

use super::model::{Entity, FieldKind};

/// graph-node's cap on `first`.
pub const PAGE_SIZE: usize = 1000;

#[derive(Debug)]
pub struct GraphClient {
    http: reqwest::Client,
    pub url: String,
    headers: reqwest::header::HeaderMap,
    permits: Arc<Semaphore>,
    max_retries: u32,
    requests: AtomicU64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Meta {
    pub block: u64,
    pub deployment: Option<String>,
    pub has_indexing_errors: bool,
}

/// What the endpoint's schema exposes, from introspection. Absent when the
/// endpoint refuses introspection, in which case collection names are guessed
/// and every schema field is selected.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Exposed {
    /// Entity type → the plural collection field that lists it.
    pub collections: BTreeMap<String, String>,
    /// Object type → its field names.
    pub fields: BTreeMap<String, BTreeSet<String>>,
}

/// One type's ids as the endpoint lists them, raw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ids {
    pub ids: Vec<Value>,
    /// False when paging stopped at the cap before the last page.
    pub complete: bool,
}

impl GraphClient {
    pub fn new(
        url: &str,
        headers: &[String],
        concurrency: usize,
        timeout: Duration,
    ) -> Result<Self> {
        let mut header_map = reqwest::header::HeaderMap::new();
        for header in headers {
            let (name, value) = header
                .split_once(':')
                .ok_or_else(|| anyhow!("--header {header:?} isn't `Name: value`"))?;
            header_map.insert(
                reqwest::header::HeaderName::from_bytes(name.trim().as_bytes())
                    .with_context(|| format!("Invalid header name in --header {header:?}"))?,
                reqwest::header::HeaderValue::from_str(value.trim())
                    .with_context(|| format!("Invalid header value in --header {header:?}"))?,
            );
        }
        reqwest::Url::parse(url).with_context(|| format!("{url:?} is not a URL"))?;
        Ok(GraphClient {
            http: reqwest::Client::builder()
                .timeout(timeout)
                .user_agent(concat!("envio-subgraph-diff/", env!("CARGO_PKG_VERSION")))
                .build()
                .context("Failed to build the HTTP client")?,
            url: url.to_string(),
            headers: header_map,
            permits: Arc::new(Semaphore::new(concurrency.max(1))),
            // With the backoff capped at 30s this waits out about a minute and a
            // half, which shared-key public endpoints' rate windows need.
            max_retries: 8,
            requests: AtomicU64::new(0),
        })
    }

    pub fn requests(&self) -> u64 {
        self.requests.load(Ordering::Relaxed)
    }

    /// Runs one query and returns its `data`. Rate limits, gateway hiccups and
    /// timeouts are retried with backoff; a GraphQL error is returned as is.
    pub async fn query(&self, query: &str) -> Result<Value> {
        let _permit = self.permits.acquire().await.expect("never closed");
        let mut attempt = 0;
        loop {
            self.requests.fetch_add(1, Ordering::Relaxed);
            let response = self
                .http
                .post(&self.url)
                .headers(self.headers.clone())
                .json(&json!({ "query": query }))
                .send()
                .await;
            let retry_after = match response {
                Err(err)
                    if attempt < self.max_retries && (err.is_timeout() || err.is_connect()) =>
                {
                    None
                }
                Err(err) => return Err(anyhow!("Request to {} failed: {err}", self.url)),
                Ok(response) => {
                    let status = response.status();
                    let retry_after = response
                        .headers()
                        .get(reqwest::header::RETRY_AFTER)
                        .and_then(|value| value.to_str().ok())
                        .and_then(|value| value.trim().parse::<u64>().ok())
                        .map(Duration::from_secs);
                    let body = response.text().await.unwrap_or_default();
                    let transient = status.as_u16() == 429 || status.is_server_error();
                    if transient && attempt < self.max_retries {
                        retry_after
                    } else if !status.is_success() && !looks_like_graphql(&body) {
                        return Err(anyhow!(
                            "{} answered HTTP {status}: {}",
                            self.url,
                            snippet(&body)
                        ));
                    } else {
                        match parse_response(&body) {
                            Err(GraphError::Transient(_)) if attempt < self.max_retries => None,
                            Err(GraphError::Transient(message) | GraphError::Fatal(message)) => {
                                return Err(anyhow!("{} answered: {message}", self.url))
                            }
                            Ok(data) => return Ok(data),
                        }
                    }
                }
            };
            let backoff = retry_after
                .unwrap_or_else(|| Duration::from_millis(500 * 2u64.pow(attempt)))
                .min(Duration::from_secs(30));
            tokio::time::sleep(backoff).await;
            attempt += 1;
        }
    }

    pub async fn meta(&self) -> Result<Meta> {
        let data = self
            .query("{ _meta { block { number } deployment hasIndexingErrors } }")
            .await?;
        let meta = &data["_meta"];
        Ok(Meta {
            block: meta["block"]["number"]
                .as_u64()
                .ok_or_else(|| anyhow!("{} returned no _meta.block.number", self.url))?,
            deployment: meta["deployment"].as_str().map(str::to_string),
            has_indexing_errors: meta["hasIndexingErrors"].as_bool().unwrap_or(false),
        })
    }

    pub async fn exposed(&self) -> Result<Exposed> {
        let data = self.query(INTROSPECTION).await?;
        Ok(parse_exposed(&data))
    }

    /// Every id of a collection, paged by id cursor (graph-node caps `skip`, so
    /// offsets can't reach a large table's tail).
    pub async fn ids(
        &self,
        collection: &str,
        block: Option<u64>,
        cap: Option<usize>,
    ) -> Result<Ids> {
        let mut ids: Vec<Value> = Vec::new();
        loop {
            let cursor = ids.last().map(literal);
            let page = self
                .query(&page_query(collection, cursor.as_deref(), block))
                .await?;
            let rows = page["page"]
                .as_array()
                .ok_or_else(|| anyhow!("{} returned no list for {collection}", self.url))?;
            let full = rows.len() == PAGE_SIZE;
            ids.extend(rows.iter().map(|row| row["id"].clone()));
            if !full {
                return Ok(Ids {
                    ids,
                    complete: true,
                });
            }
            if cap.is_some_and(|cap| ids.len() >= cap) {
                return Ok(Ids {
                    ids,
                    complete: false,
                });
            }
        }
    }

    pub async fn rows(
        &self,
        collection: &str,
        selection: &str,
        ids: &[Value],
        block: Option<u64>,
    ) -> Result<Vec<Value>> {
        self.rows_as("rows", collection, selection, ids, block)
            .await
    }

    /// [`Self::rows`] asked again, in batches, as a query of its own: under
    /// another alias it's a new question to a gateway, not a cached repeat, and
    /// may reach another indexer.
    pub async fn recheck(
        &self,
        collection: &str,
        selection: &str,
        ids: &[Value],
        block: Option<u64>,
        batch: usize,
    ) -> Result<Vec<Value>> {
        let mut rows = Vec::new();
        for chunk in ids.chunks(batch.max(1)) {
            rows.extend(
                self.rows_as("recheck", collection, selection, chunk, block)
                    .await?,
            );
        }
        Ok(rows)
    }

    async fn rows_as(
        &self,
        alias: &str,
        collection: &str,
        selection: &str,
        ids: &[Value],
        block: Option<u64>,
    ) -> Result<Vec<Value>> {
        let data = self
            .query(&rows_query_as(alias, collection, selection, ids, block))
            .await?;
        data[alias]
            .as_array()
            .cloned()
            .ok_or_else(|| anyhow!("{} returned no list for {collection}", self.url))
    }
}

const INTROSPECTION: &str = "{ __schema { queryType { fields { name type { kind name ofType { \
     kind name ofType { kind name ofType { kind name } } } } } } types { kind name fields { name \
     } } } }";

/// A GraphQL literal for an id as the endpoint returned it. JSON's string
/// escapes are valid GraphQL ones.
fn literal(id: &Value) -> String {
    match id {
        Value::String(s) => serde_json::to_string(s).expect("strings serialize"),
        other => other.to_string(),
    }
}

fn block_arg(block: Option<u64>) -> String {
    block
        .map(|number| format!(", block: {{number: {number}}}"))
        .unwrap_or_default()
}

pub fn page_query(collection: &str, cursor: Option<&str>, block: Option<u64>) -> String {
    let filter = cursor
        .map(|cursor| format!(", where: {{id_gt: {cursor}}}"))
        .unwrap_or_default();
    format!(
        "{{ page: {collection}(first: {PAGE_SIZE}, orderBy: id, orderDirection: asc{filter}{}) {{ \
         id }} }}",
        block_arg(block)
    )
}

pub fn rows_query(collection: &str, selection: &str, ids: &[Value], block: Option<u64>) -> String {
    rows_query_as("rows", collection, selection, ids, block)
}

fn rows_query_as(
    alias: &str,
    collection: &str,
    selection: &str,
    ids: &[Value],
    block: Option<u64>,
) -> String {
    let ids = ids.iter().map(literal).collect::<Vec<_>>().join(", ");
    format!(
        "{{ {alias}: {collection}(first: {PAGE_SIZE}, where: {{id_in: [{ids}]}}{}) {{ id \
         {selection} }} }}",
        block_arg(block)
    )
}

/// The selection set for an entity's compared fields.
pub fn selection(entity: &Entity, fields: &[&str]) -> String {
    entity
        .fields
        .iter()
        .filter(|field| fields.contains(&field.name.as_str()))
        .map(|field| match (&field.kind, field.list) {
            (FieldKind::Entity { .. }, true) => format!(
                "{}(first: {PAGE_SIZE}, orderBy: id, orderDirection: asc) {{ id }}",
                field.name
            ),
            (FieldKind::Entity { .. }, false) => format!("{} {{ id }}", field.name),
            (FieldKind::Scalar(_), _) => field.name.clone(),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// graph-node's collection field for an entity, for endpoints that refuse
/// introspection: `camel_cased_names` (graph/src/data/graphql/ext.rs) with the
/// Inflector version graph-node pins, so `ATokenBalanceHistoryItem` is
/// `atokenBalanceHistoryItems` and a name whose plural is itself gets
/// `_collection` (`DynamicQuorumParams` → `dynamicQuorumParams_collection`).
pub fn plural_collection(entity: &str) -> String {
    use inflector::Inflector;
    let singular = entity.to_camel_case();
    let plural = entity.to_plural().to_camel_case();
    if plural == singular {
        format!("{plural}_collection")
    } else {
        plural
    }
}

pub fn parse_exposed(data: &Value) -> Exposed {
    let mut exposed = Exposed::default();
    let schema = &data["__schema"];
    for field in schema["queryType"]["fields"]
        .as_array()
        .into_iter()
        .flatten()
    {
        let Some(name) = field["name"].as_str() else {
            continue;
        };
        if name.starts_with("__") || name.starts_with('_') {
            continue;
        }
        let mut current = &field["type"];
        let mut list = false;
        let mut base = None;
        for _ in 0..6 {
            match current["kind"].as_str() {
                Some("LIST") => list = true,
                Some("NON_NULL") => {}
                Some(_) => {
                    base = current["name"].as_str();
                    break;
                }
                None => break,
            }
            current = &current["ofType"];
        }
        if let (true, Some(base)) = (list, base) {
            exposed
                .collections
                .entry(base.to_string())
                .or_insert_with(|| name.to_string());
        }
    }
    for ty in schema["types"].as_array().into_iter().flatten() {
        if ty["kind"].as_str() != Some("OBJECT") {
            continue;
        }
        let (Some(name), Some(fields)) = (ty["name"].as_str(), ty["fields"].as_array()) else {
            continue;
        };
        exposed.fields.insert(
            name.to_string(),
            fields
                .iter()
                .filter_map(|field| field["name"].as_str().map(str::to_string))
                .collect(),
        );
    }
    exposed
}

#[derive(Debug, PartialEq, Eq)]
enum GraphError {
    Transient(String),
    Fatal(String),
}

fn looks_like_graphql(body: &str) -> bool {
    serde_json::from_str::<Value>(body)
        .map(|value| value.get("errors").is_some() || value.get("data").is_some())
        .unwrap_or(false)
}

/// The body with every JSON number too long for an f64 turned into a string
/// of its digits. graph-node sends BigInt as a string, but an endpoint that
/// sends a number must not lose digits on the way into the comparison.
fn lossless_numbers(body: &str) -> std::borrow::Cow<'_, str> {
    let bytes = body.as_bytes();
    let mut out: Option<String> = None;
    let mut copied = 0;
    let mut in_string = false;
    let mut escaped = false;
    let mut at = 0;
    while at < bytes.len() {
        let byte = bytes[at];
        if in_string {
            match (escaped, byte) {
                (true, _) => escaped = false,
                (false, b'\\') => escaped = true,
                (false, b'"') => in_string = false,
                _ => {}
            }
            at += 1;
            continue;
        }
        if byte == b'"' {
            in_string = true;
            at += 1;
            continue;
        }
        if byte == b'-' || byte.is_ascii_digit() {
            let start = at;
            while at < bytes.len()
                && matches!(bytes[at], b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')
            {
                at += 1;
            }
            let token = &body[start..at];
            if token.bytes().filter(u8::is_ascii_digit).count() > 15 {
                let out = out.get_or_insert_with(|| String::with_capacity(body.len() + 16));
                out.push_str(&body[copied..start]);
                out.push('"');
                out.push_str(token);
                out.push('"');
                copied = at;
            }
            continue;
        }
        at += 1;
    }
    match out {
        Some(mut out) => {
            out.push_str(&body[copied..]);
            std::borrow::Cow::Owned(out)
        }
        None => std::borrow::Cow::Borrowed(body),
    }
}

fn parse_response(body: &str) -> Result<Value, GraphError> {
    let value: Value = serde_json::from_str(&lossless_numbers(body))
        .map_err(|_| GraphError::Fatal(format!("a response that isn't JSON: {}", snippet(body))))?;
    if let Some(errors) = value["errors"]
        .as_array()
        .filter(|errors| !errors.is_empty())
    {
        let message = errors
            .iter()
            .map(|error| {
                error["message"]
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| error.to_string())
            })
            .collect::<Vec<_>>()
            .join("; ");
        let lower = message.to_lowercase();
        // graph-node reports an overloaded store or a slow query as a GraphQL
        // error on a 200, not as an HTTP status.
        let transient = [
            "timeout",
            "timed out",
            "too many",
            "rate limit",
            "unavailable",
        ]
        .iter()
        .any(|needle| lower.contains(needle));
        return Err(if transient {
            GraphError::Transient(message)
        } else {
            GraphError::Fatal(message)
        });
    }
    match value.get("data") {
        Some(data) if !data.is_null() => Ok(data.clone()),
        _ => Err(GraphError::Fatal(format!(
            "a response without data: {}",
            snippet(body)
        ))),
    }
}

fn snippet(body: &str) -> String {
    let trimmed = body.trim();
    match trimmed.char_indices().nth(300) {
        Some((at, _)) => format!("{}…", &trimmed[..at]),
        None => trimmed.to_string(),
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::mock_http::{read_request, write_response};
    use pretty_assertions::assert_eq;
    use std::sync::Mutex;
    use tokio::net::TcpListener;

    /// A graph-node stand-in: answers each request with `respond(query)` as
    /// (HTTP status, body), and records the queries it was sent.
    pub struct MockGraph {
        pub url: String,
        pub queries: Arc<Mutex<Vec<String>>>,
    }

    pub async fn mock_graph(
        respond: impl Fn(&str) -> (u16, String) + Send + Sync + 'static,
    ) -> MockGraph {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!(
            "http://{}/subgraphs/name/test",
            listener.local_addr().unwrap()
        );
        let queries = Arc::new(Mutex::new(Vec::new()));
        let recorded = queries.clone();
        let respond = Arc::new(respond);
        tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    return;
                };
                let recorded = recorded.clone();
                let respond = respond.clone();
                tokio::spawn(async move {
                    let mut buffered = Vec::new();
                    while let Ok(Some(request)) = read_request(&mut stream, &mut buffered).await {
                        let body: Value = serde_json::from_slice(&request.body).unwrap();
                        let query = body["query"].as_str().unwrap().to_string();
                        recorded.lock().unwrap().push(query.clone());
                        let (status, response) = respond(&query);
                        if write_response(
                            &mut stream,
                            status,
                            &[("Content-Type", "application/json")],
                            response.as_bytes(),
                        )
                        .await
                        .is_err()
                        {
                            return;
                        }
                    }
                });
            }
        });
        MockGraph { url, queries }
    }

    fn client(url: &str) -> GraphClient {
        let mut client = GraphClient::new(url, &[], 2, Duration::from_secs(5)).unwrap();
        client.max_retries = 2;
        client
    }

    /// The id cursor a page query carries, if any.
    pub fn cursor(query: &str) -> Option<String> {
        let start = query.find("id_gt: ")? + "id_gt: ".len();
        let rest = &query[start..];
        let end = rest.find('}')?;
        serde_json::from_str(&rest[..end]).ok()
    }

    #[tokio::test]
    async fn pages_every_id_by_cursor() {
        let all: Vec<String> = (0..2500).map(|i| format!("id-{i:05}")).collect();
        let served = all.clone();
        let mock = mock_graph(move |query| {
            let after = cursor(query);
            let page: Vec<Value> = served
                .iter()
                .filter(|id| after.as_ref().is_none_or(|after| *id > after))
                .take(PAGE_SIZE)
                .map(|id| json!({ "id": id }))
                .collect();
            (200, json!({ "data": { "page": page } }).to_string())
        })
        .await;

        let ids = client(&mock.url)
            .ids("tokens", Some(17), None)
            .await
            .unwrap();
        let queries = mock.queries.lock().unwrap().clone();
        assert_eq!(
            (
                ids,
                queries.first().cloned(),
                queries.iter().map(|q| cursor(q)).collect::<Vec<_>>(),
            ),
            (
                Ids {
                    ids: all.iter().map(|id| json!(id)).collect(),
                    complete: true
                },
                Some(
                    "{ page: tokens(first: 1000, orderBy: id, orderDirection: asc, block: \
                     {number: 17}) { id } }"
                        .to_string()
                ),
                vec![
                    None,
                    Some("id-00999".to_string()),
                    Some("id-01999".to_string())
                ],
            )
        );
    }

    #[tokio::test]
    async fn stops_paging_at_the_cap() {
        let mock = mock_graph(|query| {
            let start = cursor(query).map_or(0, |c| c.parse::<usize>().unwrap() + 1);
            let page: Vec<Value> = (start..start + PAGE_SIZE)
                .map(|i| json!({ "id": format!("{i}") }))
                .collect();
            (200, json!({ "data": { "page": page } }).to_string())
        })
        .await;
        let ids = client(&mock.url)
            .ids("tokens", None, Some(1500))
            .await
            .unwrap();
        assert_eq!((ids.ids.len(), ids.complete), (2000, false));
    }

    #[tokio::test]
    async fn retries_a_rate_limit_and_reports_a_graphql_error() {
        let calls = Arc::new(Mutex::new(0));
        let counter = calls.clone();
        let mock = mock_graph(move |query| {
            let mut calls = counter.lock().unwrap();
            *calls += 1;
            if query.contains("_meta") {
                if *calls == 1 {
                    (429, "slow down".to_string())
                } else {
                    (
                        200,
                        json!({"data": {"_meta": {"block": {"number": 99}, "deployment": "Qm1", "hasIndexingErrors": false}}})
                            .to_string(),
                    )
                }
            } else {
                (
                    200,
                    json!({"errors": [{"message": "Type `Query` has no field `nope`"}]})
                        .to_string(),
                )
            }
        })
        .await;
        let client = client(&mock.url);
        let meta = client.meta().await.unwrap();
        let err = client.query("{ nope { id } }").await.unwrap_err();
        assert_eq!(
            (meta, err.to_string(), client.requests()),
            (
                Meta {
                    block: 99,
                    deployment: Some("Qm1".to_string()),
                    has_indexing_errors: false
                },
                format!("{} answered: Type `Query` has no field `nope`", mock.url),
                3
            )
        );
    }

    #[test]
    fn reads_collections_and_fields_from_introspection() {
        let data = json!({"__schema": {
            "queryType": {"fields": [
                {"name": "pool", "type": {"kind": "OBJECT", "name": "Pool", "ofType": null}},
                {"name": "pools", "type": {"kind": "NON_NULL", "name": null, "ofType": {"kind": "LIST", "name": null, "ofType": {"kind": "NON_NULL", "name": null, "ofType": {"kind": "OBJECT", "name": "Pool"}}}}},
                {"name": "_meta", "type": {"kind": "OBJECT", "name": "_Meta_", "ofType": null}}
            ]},
            "types": [
                {"kind": "OBJECT", "name": "Pool", "fields": [{"name": "id"}, {"name": "token0"}]},
                {"kind": "SCALAR", "name": "BigInt", "fields": null}
            ]
        }});
        assert_eq!(
            parse_exposed(&data),
            Exposed {
                collections: BTreeMap::from([("Pool".to_string(), "pools".to_string())]),
                fields: BTreeMap::from([(
                    "Pool".to_string(),
                    BTreeSet::from(["id".to_string(), "token0".to_string()])
                )]),
            }
        );
    }

    /// graph-node's own answers: spec/GRAPH_DIALECT.md §2.1, and the Aave v3
    /// and Nouns names checked on the network.
    #[test]
    fn names_collections_as_graph_node_does() {
        let names = [
            ("Pool", "pools"),
            ("PoolDayData", "poolDayDatas"),
            ("Factory", "factories"),
            ("Day", "days"),
            ("Status", "statuses"),
            ("Box", "boxes"),
            ("Match", "matches"),
            ("UserReserve", "userReserves"),
            ("Child", "childs"),
            ("Person", "persons"),
            ("Metadata", "metadata_collection"),
            ("Stats", "stats_collection"),
            ("Users", "users_collection"),
            ("ERC20Token", "erc20Tokens"),
            ("ENSName", "ensnames"),
            ("USDPrice", "usdprices"),
            ("Leaf", "leaves"),
            ("Analysis", "analyses"),
            ("snake_case_name", "snakeCaseNames"),
            ("ATokenBalanceHistoryItem", "atokenBalanceHistoryItems"),
            ("EModeCategory", "emodeCategories"),
            ("DynamicQuorumParams", "dynamicQuorumParams_collection"),
        ];
        assert_eq!(
            names.map(|(entity, _)| plural_collection(entity)).to_vec(),
            names.map(|(_, plural)| plural.to_string()).to_vec()
        );
    }

    #[test]
    fn keeps_every_digit_of_a_long_number() {
        assert_eq!(
            parse_response(
                r#"{"data":{"rows":[{"id":"\"9007199254740993\"","values":[0,214150674921510188467],"n":-12.5}]}}"#
            ),
            Ok(json!({"rows": [{
                "id": "\"9007199254740993\"",
                "values": [0, "214150674921510188467"],
                "n": -12.5
            }]}))
        );
    }

    #[test]
    fn escapes_ids_in_queries() {
        assert_eq!(
            rows_query("tokens", "name", &[json!("a\"b"), json!("0x01")], None),
            "{ rows: tokens(first: 1000, where: {id_in: [\"a\\\"b\", \"0x01\"]}) { id name } }"
        );
    }
}
