use super::graph::tests::{cursor, mock_graph, MockGraph};
use super::*;
use pretty_assertions::assert_eq;
use serde_json::json;
use std::sync::Arc;

const SCHEMA: &str = r#"
type Account @entity {
  id: Bytes!
  balance: BigDecimal!
  tokens: [Token!]!
  minted: [Token!]! @derivedFrom(field: "minter")
}

type Token @entity(immutable: true) {
  id: ID!
  minter: Account!
  supply: BigInt!
  decimals: Int!
  hash: Bytes!
  frozen: Boolean
  labels: [String!]
}
"#;

const MANIFEST: &str = r#"
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"
      abi: Token
      startBlock: 1
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: [Token]
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Minted(uint256)
          handler: handleMinted
      file: ./src/mapping.ts
"#;

fn project() -> tempdir::TempDir {
    let dir = tempdir::TempDir::new("envio-subgraph-diff").unwrap();
    std::fs::write(dir.path().join("subgraph.yaml"), MANIFEST).unwrap();
    std::fs::write(dir.path().join("schema.graphql"), SCHEMA).unwrap();
    dir
}

/// Entities as graph-node would serve them, keyed by collection.
type Dataset = BTreeMap<&'static str, Vec<Value>>;

fn reference_data() -> Dataset {
    let tokens: Vec<Value> = (1..=12)
        .map(|i| {
            json!({
                "id": format!("t{i:02}"),
                "minter": {"id": "0xaa"},
                "supply": format!("{}", i * 1000),
                "decimals": 18,
                "hash": format!("0x{i:02x}ff"),
                "frozen": null,
                "labels": null,
            })
        })
        .collect();
    BTreeMap::from([
        (
            "accounts",
            vec![
                json!({"id": "0xaa", "balance": "1.5", "tokens": [{"id": "t01"}, {"id": "t02"}]}),
                json!({"id": "0xbb", "balance": "0", "tokens": []}),
            ],
        ),
        ("tokens", tokens),
    ])
}

const BLOCK: u64 = 1234;

async fn graph_node(data: Dataset, block: u64) -> MockGraph {
    graph_node_refusing(data, block, None).await
}

/// Serves `data` like graph-node: `_meta`, introspection, cursor pages and
/// `id_in` lookups. Selections are ignored — every row comes back whole —
/// except that a lookup selecting `refuse.0` fails with `refuse.1`.
async fn graph_node_refusing(
    data: Dataset,
    block: u64,
    refuse: Option<(&'static str, &'static str)>,
) -> MockGraph {
    let data = Arc::new(data);
    mock_graph(move |query| {
        if let Some((selected, message)) = refuse {
            if query.starts_with("{ rows:") && query.contains(selected) {
                return (200, json!({"errors": [{"message": message}]}).to_string());
            }
        }
        if query.contains("_meta") {
            let meta = json!({"block": {"number": block}, "deployment": "QmTest", "hasIndexingErrors": false});
            return (200, json!({"data": {"_meta": meta}}).to_string());
        }
        if query.contains("__schema") {
            return (200, json!({"data": introspection(&data)}).to_string());
        }
        let Some(collection) = query
            .split_once(": ")
            .and_then(|(_, rest)| rest.split_once('('))
            .map(|(collection, _)| collection.to_string())
        else {
            return (400, "unparseable".to_string());
        };
        let rows = data.get(collection.as_str()).cloned().unwrap_or_default();
        if query.starts_with("{ page:") {
            let after = cursor(query);
            let page: Vec<Value> = rows
                .iter()
                .filter(|row| after.as_ref().is_none_or(|a| row["id"].as_str().unwrap() > a.as_str()))
                .take(graph::PAGE_SIZE)
                .map(|row| json!({"id": row["id"]}))
                .collect();
            return (200, json!({"data": {"page": page}}).to_string());
        }
        let wanted: Vec<String> = query
            .split_once("id_in: [")
            .and_then(|(_, rest)| rest.split_once(']'))
            .map(|(ids, _)| serde_json::from_str(&format!("[{ids}]")).unwrap())
            .unwrap_or_default();
        let found: Vec<Value> = rows
            .into_iter()
            // graph-node parses a Bytes id, so its case doesn't matter.
            .filter(|row| {
                wanted
                    .iter()
                    .any(|id| row["id"].as_str().unwrap().eq_ignore_ascii_case(id))
            })
            .collect();
        (200, json!({"data": {"rows": found}}).to_string())
    })
    .await
}

fn introspection(data: &Dataset) -> Value {
    let types = [("accounts", "Account"), ("tokens", "Token")];
    let list_of = |name: &str| {
        json!({"kind": "NON_NULL", "name": null, "ofType": {"kind": "LIST", "name": null,
            "ofType": {"kind": "NON_NULL", "name": null, "ofType": {"kind": "OBJECT", "name": name}}}})
    };
    let fields: Vec<Value> = types
        .iter()
        .filter(|(collection, _)| data.contains_key(collection))
        .map(|(collection, name)| json!({"name": collection, "type": list_of(name)}))
        .collect();
    let object_types: Vec<Value> = [
        ("Account", vec!["id", "balance", "tokens", "minted"]),
        (
            "Token",
            vec![
                "id", "minter", "supply", "decimals", "hash", "frozen", "labels",
            ],
        ),
    ]
    .iter()
    .map(|(name, fields)| {
        json!({"kind": "OBJECT", "name": name,
            "fields": fields.iter().map(|f| json!({"name": f})).collect::<Vec<_>>()})
    })
    .collect();
    json!({"__schema": {"queryType": {"fields": fields}, "types": object_types}})
}

fn options(endpoint: &str, ours: Option<&str>) -> Options {
    Options {
        endpoint: endpoint.to_string(),
        ours: ours.map(str::to_string),
        block: None,
        sample: 100,
        types: vec![],
        tolerance_pct: 0.1,
        max_field_mismatches: 0,
        concurrency: 4,
        max_entities: None,
        headers: vec![],
        allow_indexing_errors: false,
        timeout: Duration::from_secs(10),
        progress: false,
    }
}

/// What a test checks of a report: everything but timings and URLs.
fn outcome(report: &Report) -> Value {
    json!({
        "status": report.status,
        "exitCode": report.exit_code,
        "block": report.block,
        "errors": report.errors,
        "entities": report.entities.iter().map(|e| json!({
            "type": e.name,
            "status": e.status,
            "ours": e.ours,
            "theirs": e.theirs,
            "onlyOurs": e.only_ours_examples,
            "onlyTheirs": e.only_theirs_examples,
            "sampled": e.sampled,
            "fieldMismatches": e.mismatched_fields,
            "examples": e.mismatch_examples,
            "skipped": e.skipped_fields.iter().map(|s| format!("{}: {}", s.name, s.reason)).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

#[tokio::test]
async fn matches_when_only_the_encodings_differ() {
    let reference = graph_node(reference_data(), BLOCK + 50).await;
    // The same data spelled the way envio's side might: trailing zeros,
    // uppercase hex, ids in another order, a list saved unsorted.
    let mut ours = reference_data();
    ours.get_mut("accounts").unwrap()[0] =
        json!({"id": "0xAA", "balance": "1.50", "tokens": [{"id": "t02"}, {"id": "t01"}]});
    ours.get_mut("tokens").unwrap()[3]["hash"] = json!("0x04FF");
    let ours = graph_node(ours, BLOCK).await;

    let dir = project();
    let report = run(dir.path(), &options(&reference.url, Some(&ours.url))).await;

    let reference_queries = reference.queries.lock().unwrap().clone();
    let ours_queries = ours.queries.lock().unwrap().clone();
    let pinned = |queries: &[String]| {
        queries
            .iter()
            .filter(|q| q.contains("page:") || q.contains("rows:"))
            .all(|q| q.contains(&format!("block: {{number: {BLOCK}}}")))
    };
    let unpinned = |queries: &[String]| queries.iter().all(|q| !q.contains("block:"));
    assert_eq!(
        (
            outcome(&report),
            pinned(&reference_queries),
            unpinned(&ours_queries)
        ),
        (
            json!({
                "status": "match", "exitCode": 0, "block": BLOCK, "errors": [],
                "entities": [
                    {"type": "Account", "status": "match", "ours": 2, "theirs": 2, "onlyOurs": [],
                     "onlyTheirs": [], "sampled": 2, "fieldMismatches": {}, "examples": [],
                     "skipped": ["minted: derived (@derivedFrom), not stored"]},
                    {"type": "Token", "status": "match", "ours": 12, "theirs": 12, "onlyOurs": [],
                     "onlyTheirs": [], "sampled": 12, "fieldMismatches": {}, "examples": [],
                     "skipped": []},
                ],
            }),
            true,
            true
        )
    );
}

#[tokio::test]
async fn reports_missing_entities_and_wrong_fields() {
    let reference = graph_node(reference_data(), BLOCK).await;
    let mut ours = reference_data();
    let tokens = ours.get_mut("tokens").unwrap();
    tokens.remove(4);
    tokens[0]["supply"] = json!("999");
    tokens.push(
        json!({"id": "t99", "minter": {"id": "0xaa"}, "supply": "1", "decimals": 18,
        "hash": "0x00", "frozen": true, "labels": ["x"]}),
    );
    let ours = graph_node(ours, BLOCK).await;

    let dir = project();
    let report = run(dir.path(), &options(&reference.url, Some(&ours.url))).await;
    assert_eq!(
        outcome(&report),
        json!({
            "status": "mismatch", "exitCode": 1, "block": BLOCK, "errors": [],
            "entities": [
                {"type": "Account", "status": "match", "ours": 2, "theirs": 2, "onlyOurs": [],
                 "onlyTheirs": [], "sampled": 2, "fieldMismatches": {}, "examples": [],
                 "skipped": ["minted: derived (@derivedFrom), not stored"]},
                {"type": "Token", "status": "mismatch", "ours": 12, "theirs": 12,
                 "onlyOurs": ["t99"], "onlyTheirs": ["t05"], "sampled": 11,
                 "fieldMismatches": {"supply": 1},
                 "examples": [{"id": "t01", "field": "supply", "ours": "999", "theirs": "1000"}],
                 "skipped": []},
            ],
        })
    );
}

#[tokio::test]
async fn refuses_a_reference_behind_ours() {
    let reference = graph_node(reference_data(), BLOCK - 1).await;
    let ours = graph_node(reference_data(), BLOCK).await;
    let dir = project();
    let report = run(dir.path(), &options(&reference.url, Some(&ours.url))).await;
    assert_eq!(
        (report.status, report.exit_code, report.errors),
        (
            Status::Error,
            2,
            vec![
                "The reference has only indexed up to block 1233, behind ours at 1234, and \
                 graph-node can't answer for a block it hasn't reached. Rerun once it has, or \
                 compare an indexer stopped at or before block 1233."
                    .to_string()
            ]
        )
    );
}

#[tokio::test]
async fn drops_a_field_the_reference_cannot_resolve() {
    let reference = graph_node_refusing(
        reference_data(),
        BLOCK,
        Some((
            "minter { id }",
            "Null value resolved for non-null field `minter`",
        )),
    )
    .await;
    let ours = graph_node(reference_data(), BLOCK).await;
    let dir = project();
    let mut options = options(&reference.url, Some(&ours.url));
    options.types = vec!["Token".to_string()];
    let report = run(dir.path(), &options).await;
    assert_eq!(
        (outcome(&report), report.entities[0].fields_compared.clone()),
        (
            json!({
                "status": "match", "exitCode": 0, "block": BLOCK, "errors": [],
                "entities": [
                    {"type": "Token", "status": "match", "ours": 12, "theirs": 12, "onlyOurs": [],
                     "onlyTheirs": [], "sampled": 12, "fieldMismatches": {}, "examples": [],
                     "skipped": [format!(
                         "minter: unreadable: Failed to read the reference's sampled rows: {} \
                          answered: Null value resolved for non-null field `minter`",
                         reference.url
                     )]},
                ],
            }),
            ["supply", "decimals", "hash", "frozen", "labels"]
                .map(String::from)
                .to_vec()
        )
    );
}

#[tokio::test]
async fn fails_parity_on_a_field_ours_cannot_serve() {
    let reference = graph_node(reference_data(), BLOCK).await;
    let ours = graph_node_refusing(
        reference_data(),
        BLOCK,
        Some((
            "tokens(first: 1000, orderBy",
            "Field `tokens` of type `text` must not have a selection",
        )),
    )
    .await;
    let dir = project();
    let mut options = options(&reference.url, Some(&ours.url));
    options.types = vec!["Account".to_string()];
    let report = run(dir.path(), &options).await;
    assert_eq!(
        (
            report.status,
            report.exit_code,
            report.entities[0].fields_compared.clone(),
            report.entities[0]
                .unservable_fields
                .iter()
                .map(|s| s.name.as_str())
                .collect::<Vec<_>>(),
        ),
        (
            Status::Mismatch,
            1,
            vec!["balance".to_string()],
            vec!["tokens"]
        )
    );
}

#[tokio::test]
async fn calls_a_capped_listing_incomplete_not_a_match() {
    let many: Vec<Value> = (0..1500)
        .map(|i| {
            json!({"id": format!("t{i:05}"), "minter": {"id": "0xaa"}, "supply": "1",
                "decimals": 18, "hash": "0x01", "frozen": null, "labels": null})
        })
        .collect();
    let data = || {
        let mut data = reference_data();
        data.insert("tokens", many.clone());
        data
    };
    let reference = graph_node(data(), BLOCK).await;
    let ours = graph_node(data(), BLOCK).await;
    let dir = project();
    let mut options = options(&reference.url, Some(&ours.url));
    options.max_entities = Some(1000);
    let report = run(dir.path(), &options).await;
    assert_eq!(
        (
            report.status,
            report.exit_code,
            report
                .entities
                .iter()
                .map(|e| (
                    e.name.as_str(),
                    e.status,
                    e.theirs,
                    e.theirs_complete,
                    e.delta_pct
                ))
                .collect::<Vec<_>>()
        ),
        (
            Status::Incomplete,
            2,
            vec![
                ("Account", Some(Status::Match), Some(2), true, Some(0.0)),
                ("Token", Some(Status::Incomplete), Some(1000), false, None),
            ]
        )
    );
}

#[test]
fn pins_the_block_ours_has_reached() {
    let messages = [
        pin_block(None, 100, 120),
        pin_block(Some(100), 100, 100),
        pin_block(Some(101), 100, 120),
        pin_block(Some(99), 100, 120),
    ]
    .map(|result| result.map_err(|err| err.to_string()));
    assert_eq!(
        messages.to_vec(),
        vec![
            Ok(100),
            Ok(100),
            Err(
                "Ours has only reached block 100, so it can't answer for block 101. Wait for \
                 it to get there, or omit --block."
                    .to_string()
            ),
            Err(
                "Ours is at block 100 and keeps no history, so it can only be compared at that \
                 block. Omit --block, or stop the indexer at block 99 and rerun."
                    .to_string()
            ),
        ]
    );
}

#[test]
fn samples_the_same_ids_whatever_the_order() {
    let ids: Vec<String> = (0..50).map(|i| format!("id{i}")).collect();
    let forward = sample(ids.iter().collect(), 5);
    let backward = sample(ids.iter().rev().collect(), 5);
    assert_eq!((forward.len(), forward == backward), (5, true));
}

/// The Postgres path end to end, against a scratch database laid out the way
/// subgraph mode stores entities. Needs a server to create it on:
/// `ENVIO_DIFF_TEST_PG=postgres://postgres:postgres@localhost:5432`.
#[tokio::test]
async fn compares_the_indexers_postgres() {
    let Ok(server) = std::env::var("ENVIO_DIFF_TEST_PG") else {
        eprintln!("skipped: set ENVIO_DIFF_TEST_PG to run the Postgres diff test");
        return;
    };
    let url = url::Url::parse(&server).unwrap();
    let database = format!("diff_test_{}", std::process::id());
    let connect = |db: &str| {
        let mut config = tokio_postgres::Config::new();
        config
            .host(url.host_str().unwrap())
            .port(url.port().unwrap_or(5432))
            .user(url.username())
            .password(url.password().unwrap_or_default())
            .dbname(db);
        async move {
            let (client, connection) = config.connect(tokio_postgres::NoTls).await.unwrap();
            tokio::spawn(connection);
            client
        }
    };
    let admin = connect("postgres").await;
    for statement in ["DROP DATABASE IF EXISTS", "CREATE DATABASE"] {
        admin
            .batch_execute(&format!("{statement} {database}"))
            .await
            .unwrap();
    }

    let db = connect(&database).await;
    let mut inserts = String::from(
        r#"
CREATE TABLE envio_chains (id integer PRIMARY KEY, progress_block integer NOT NULL);
INSERT INTO envio_chains VALUES (1, 1234);
CREATE TABLE "Account" (id text PRIMARY KEY, balance numeric NOT NULL, tokens text[] NOT NULL);
INSERT INTO "Account" VALUES ('0xaa', 1.50, '{t02,t01}'), ('0xbb', 0.000, '{}');
CREATE TABLE "Token" (id text PRIMARY KEY, minter_id text NOT NULL, supply numeric NOT NULL,
  decimals integer NOT NULL, hash bytea NOT NULL, frozen boolean, labels text[]);
"#,
    );
    for i in 1..=12 {
        let supply = if i == 3 { 7 } else { i * 1000 };
        inserts.push_str(&format!(
            "INSERT INTO \"Token\" VALUES ('t{i:02}', '0xaa', {supply}, 18, '\\x{i:02x}ff', NULL, NULL);\n"
        ));
    }
    db.batch_execute(&inserts).await.unwrap();

    let reference = graph_node(reference_data(), BLOCK).await;
    let dir = project();
    std::fs::write(
        dir.path().join(".env"),
        format!(
            "ENVIO_PG_HOST={}\nENVIO_PG_PORT={}\nENVIO_PG_USER={}\nENVIO_PG_PASSWORD={}\nENVIO_PG_DATABASE={database}\n",
            url.host_str().unwrap(),
            url.port().unwrap_or(5432),
            url.username(),
            url.password().unwrap_or_default()
        ),
    )
    .unwrap();
    let report = run(dir.path(), &options(&reference.url, None)).await;
    drop(db);
    admin
        .batch_execute(&format!("DROP DATABASE IF EXISTS {database} WITH (FORCE)"))
        .await
        .unwrap();

    assert_eq!(
        outcome(&report),
        json!({
            "status": "mismatch", "exitCode": 1, "block": BLOCK, "errors": [],
            "entities": [
                {"type": "Account", "status": "match", "ours": 2, "theirs": 2, "onlyOurs": [],
                 "onlyTheirs": [], "sampled": 2, "fieldMismatches": {}, "examples": [],
                 "skipped": ["minted: derived (@derivedFrom), not stored"]},
                {"type": "Token", "status": "mismatch", "ours": 12, "theirs": 12, "onlyOurs": [],
                 "onlyTheirs": [], "sampled": 12, "fieldMismatches": {"supply": 1},
                 "examples": [{"id": "t03", "field": "supply", "ours": "7", "theirs": "3000"}],
                 "skipped": []},
            ],
        })
    );
}
