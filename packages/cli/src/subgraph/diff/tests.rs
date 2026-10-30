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
  owner: Account
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
    project_with(SCHEMA)
}

fn project_with(schema: &str) -> tempdir::TempDir {
    let dir = tempdir::TempDir::new("envio-subgraph-diff").unwrap();
    std::fs::write(dir.path().join("subgraph.yaml"), MANIFEST).unwrap();
    std::fs::write(dir.path().join("schema.graphql"), schema).unwrap();
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
                "owner": if i == 1 { json!({"id": "0xbb"}) } else { Value::Null },
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
        serve(&data, block, query)
    })
    .await
}

/// One answer of the mock graph-node over `data`.
fn serve(data: &Dataset, block: u64, query: &str) -> (u16, String) {
    if query.contains("_meta") {
        let meta =
            json!({"block": {"number": block}, "deployment": "QmTest", "hasIndexingErrors": false});
        return (200, json!({"data": {"_meta": meta}}).to_string());
    }
    if query.contains("__schema") {
        return (200, json!({"data": introspection(data)}).to_string());
    }
    let Some(collection) = query
        .split_once(": ")
        .and_then(|(_, rest)| rest.split_once('('))
        .map(|(collection, _)| collection.to_string())
    else {
        return (400, "unparseable".to_string());
    };
    // An aggregation's rows are served per interval, which graph-node requires.
    let collection = match collection.as_str() {
        "candleStats" => match ["hour", "day"]
            .into_iter()
            .find(|interval| query.contains(&format!("interval: {interval}")))
        {
            Some(interval) => format!("candleStats@{interval}"),
            None => {
                let message = "Field \"candleStats\" argument \"interval\" of type \
                               \"Aggregation_interval!\" is required but not provided.";
                return (200, json!({"errors": [{"message": message}]}).to_string());
            }
        },
        _ => collection,
    };
    let rows = data.get(collection.as_str()).cloned().unwrap_or_default();
    if query.starts_with("{ page:") {
        let after = cursor(query);
        let page: Vec<Value> = rows
            .iter()
            .filter(|row| {
                after
                    .as_ref()
                    .is_none_or(|a| row["id"].as_str().unwrap() > a.as_str())
            })
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
    let alias = query
        .trim_start_matches("{ ")
        .split_once(':')
        .map_or("rows", |(alias, _)| alias);
    (200, json!({"data": {alias: found}}).to_string())
}

fn introspection(data: &Dataset) -> Value {
    let types = [
        ("accounts", "Account"),
        ("tokens", "Token"),
        ("emodeCategories", "EModeCategory"),
        ("dynamicQuorumParams_collection", "DynamicQuorumParams"),
        ("candles", "Candle"),
        ("candleStats", "CandleStats"),
    ];
    let list_of = |name: &str| {
        json!({"kind": "NON_NULL", "name": null, "ofType": {"kind": "LIST", "name": null,
            "ofType": {"kind": "NON_NULL", "name": null, "ofType": {"kind": "OBJECT", "name": name}}}})
    };
    let fields: Vec<Value> = types
        .iter()
        .filter(|(collection, _)| {
            data.keys()
                .any(|key| key.split('@').next() == Some(*collection))
        })
        .map(|(collection, name)| json!({"name": collection, "type": list_of(name)}))
        .collect();
    let object_types: Vec<Value> = [
        ("Account", vec!["id", "balance", "tokens", "minted"]),
        (
            "Token",
            vec![
                "id", "minter", "owner", "supply", "decimals", "hash", "frozen", "labels",
            ],
        ),
        ("EModeCategory", vec!["id", "label"]),
        ("DynamicQuorumParams", vec!["id", "minQuorumVotesBPS"]),
        ("Candle", vec!["id", "timestamp", "volume"]),
        ("CandleStats", vec!["id", "timestamp", "volume"]),
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
        wait: Duration::ZERO,
        manifest: None,
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
        json!({"id": "t99", "minter": {"id": "0xaa"}, "owner": null, "supply": "1", "decimals": 18,
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

/// A gateway whose paged listing skips an entity it has, and whose first
/// answer for a sampled entity is stale: neither is a difference once the
/// reference is asked again by id.
#[tokio::test]
async fn asks_again_before_reporting_a_difference() {
    let data = Arc::new(reference_data());
    let stale = {
        let mut stale = reference_data();
        stale.get_mut("tokens").unwrap()[2]["supply"] = json!("2999");
        stale.get_mut("tokens").unwrap().remove(4);
        Arc::new(stale)
    };
    let reference = mock_graph(move |query| {
        if query.starts_with("{ recheck:") {
            serve(&data, BLOCK, query)
        } else {
            serve(&stale, BLOCK, query)
        }
    })
    .await;
    // Ours really lacks t07 and really differs on t01's decimals.
    let mut ours = reference_data();
    let tokens = ours.get_mut("tokens").unwrap();
    tokens[0]["decimals"] = json!(6);
    tokens.remove(6);
    let ours = graph_node(ours, BLOCK).await;

    let dir = project();
    let mut options = options(&reference.url, Some(&ours.url));
    options.types = vec!["Token".to_string()];
    let report = run(dir.path(), &options).await;
    let recheck_queries = reference
        .queries
        .lock()
        .unwrap()
        .iter()
        .filter(|q| q.starts_with("{ recheck:"))
        .count();
    assert_eq!(
        (
            outcome(&report),
            json!(report.entities[0].recheck),
            recheck_queries
        ),
        (
            json!({
                "status": "mismatch", "exitCode": 1, "block": BLOCK, "errors": [],
                "entities": [
                    {"type": "Token", "status": "mismatch", "ours": 11, "theirs": 12,
                     "onlyOurs": [], "onlyTheirs": ["t07"], "sampled": 11,
                     "fieldMismatches": {"decimals": 1},
                     "examples": [{"id": "t01", "field": "decimals", "ours": "6", "theirs": "18"}],
                     "skipped": []},
                ],
            }),
            // Asked: t05 and t07 of the listings (and t07 of ours), then the
            // sampled t01, t03 and t05 (which the stale answer left out).
            json!({"asked": 6, "listingMissed": 1, "listingPhantom": 0,
                   "oursListingMissed": 0, "samplesResolved": 2, "unchecked": 0,
                   "error": null}),
            2
        )
    );
}

/// envio-serve answers no introspection, so ours' collection names come from
/// the reference's: graph-node's, which a naive plural gets wrong for these.
#[tokio::test]
async fn names_ours_collections_as_the_reference_does() {
    let schema = r#"
type EModeCategory @entity {
  id: ID!
  label: String!
}

type DynamicQuorumParams @entity {
  id: ID!
  minQuorumVotesBPS: Int!
}
"#;
    let data = || {
        BTreeMap::from([
            (
                "emodeCategories",
                vec![json!({"id": "1", "label": "ETH correlated"})],
            ),
            (
                "dynamicQuorumParams_collection",
                vec![json!({"id": "LATEST", "minQuorumVotesBPS": 1000})],
            ),
        ])
    };
    let reference = graph_node(data(), BLOCK).await;
    let ours_data = Arc::new(data());
    let ours = mock_graph(move |query| {
        if query.contains("__schema") {
            let refusal = json!({"errors": [{"message": "Introspection is not supported"}]});
            return (200, refusal.to_string());
        }
        serve(&ours_data, BLOCK, query)
    })
    .await;
    let dir = project_with(schema);
    let report = run(dir.path(), &options(&reference.url, Some(&ours.url))).await;
    assert_eq!(
        (
            report.status,
            report
                .entities
                .iter()
                .map(|e| (e.name.as_str(), e.status, e.ours, e.error.clone()))
                .collect::<Vec<_>>()
        ),
        (
            Status::Match,
            vec![
                ("EModeCategory", Some(Status::Match), Some(1), None),
                ("DynamicQuorumParams", Some(Status::Match), Some(1), None),
            ]
        )
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
                 graph-node can't answer for a block it hasn't reached. Rerun once it has (or \
                 give it longer with --wait), or compare an indexer stopped at or before block \
                 1233."
                    .to_string()
            ]
        )
    );
}

// Timeseries and aggregations are indexed (docs §3), but the diff skipped them
// as if they weren't, so kenjohnscreates/agent-economy's TownStat timeseries
// and TownDaily rollups were never compared. graph-node serves the timeseries
// as an ordinary collection and each aggregation interval as
// `<collection>(interval: hour|day)`, which ours stores as `<Aggregation>_<interval>`.
#[tokio::test]
async fn compares_timeseries_and_each_aggregation_interval() {
    const CANDLES: &str = r#"
type Candle @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  volume: BigInt!
}

type CandleStats @aggregation(intervals: ["hour", "day"], source: "Candle") {
  id: Int8!
  timestamp: Timestamp!
  volume: BigInt! @aggregate(fn: "sum", arg: "volume")
}
"#;
    let dataset = |day_volume: &str| -> Dataset {
        let candle = |id: u64, ts: u64, volume: u64| json!({"id": id.to_string(), "timestamp": ts.to_string(), "volume": volume.to_string()});
        let stat = |id: u64, ts: u64, volume: &str| json!({"id": id.to_string(), "timestamp": ts.to_string(), "volume": volume});
        BTreeMap::from([
            (
                "candles",
                vec![
                    candle(4294967296, 3_600_000_000, 5),
                    candle(8589934592, 7_200_000_000, 7),
                ],
            ),
            (
                "candleStats@hour",
                vec![
                    stat(4294967296, 3_600_000_000, "5"),
                    stat(8589934592, 7_200_000_000, "7"),
                ],
            ),
            ("candleStats@day", vec![stat(8589934592, 0, day_volume)]),
        ])
    };
    let reference = graph_node(dataset("12"), BLOCK).await;
    let ours = graph_node(dataset("5"), BLOCK).await;
    let dir = project_with(CANDLES);
    let report = run(dir.path(), &options(&reference.url, Some(&ours.url))).await;
    assert_eq!(
        (
            report.skipped_types.len(),
            report
                .entities
                .iter()
                .map(|e| json!([e.name, e.status, e.ours, e.theirs, e.mismatched_fields]))
                .collect::<Vec<_>>()
        ),
        (
            0,
            vec![
                json!(["Candle", "match", 2, 2, {}]),
                json!(["CandleStats_hour", "match", 2, 2, {}]),
                json!(["CandleStats_day", "mismatch", 1, 1, {"volume": 1}]),
            ]
        )
    );
}

// RequestNetwork's payments-subgraph keeps one manifest per network
// (subgraph.base.yaml, ...) and no subgraph.yaml: `envio start --config
// subgraph.base.yaml` indexes it, and the diff read only subgraph.yaml.
#[tokio::test]
async fn reads_the_manifest_the_config_names() {
    let reference = graph_node(reference_data(), BLOCK).await;
    let ours = graph_node(reference_data(), BLOCK).await;
    let dir = tempdir::TempDir::new("envio-subgraph-diff").unwrap();
    let manifest = dir.path().join("subgraph.base.yaml");
    std::fs::write(
        &manifest,
        MANIFEST.replace("./schema.graphql", "./schema.base.graphql"),
    )
    .unwrap();
    std::fs::write(dir.path().join("schema.base.graphql"), SCHEMA).unwrap();
    let report = run(
        dir.path(),
        &Options {
            manifest: Some(manifest),
            ..options(&reference.url, Some(&ours.url))
        },
    )
    .await;
    assert_eq!(
        (report.status, report.exit_code, report.errors),
        (Status::Match, 0, vec![])
    );
}

// A reference indexing at the chain head trails an indexer that has reached it
// by a few blocks (Studio's arbitrum-sepolia deployment of frytegg/inflexion
// was 19 blocks behind), so a diff of a live indexer was refused every time.
#[tokio::test]
async fn waits_for_a_reference_a_few_blocks_behind() {
    let data = Arc::new(reference_data());
    let metas = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let reference = mock_graph(move |query| {
        let latest = query.contains("_meta") && !query.contains("block: {number:");
        let block = if latest && metas.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
            BLOCK - 3
        } else {
            BLOCK
        };
        serve(&data, block, query)
    })
    .await;
    let ours = graph_node(reference_data(), BLOCK).await;
    let dir = project();
    let report = run(
        dir.path(),
        &Options {
            wait: Duration::from_secs(30),
            ..options(&reference.url, Some(&ours.url))
        },
    )
    .await;
    assert_eq!(
        (report.status, report.exit_code, report.block, report.errors),
        (Status::Match, 0, Some(BLOCK), vec![])
    );
}

// Hosted subgraph platforms prune a deployment's history (arcaDeFAI's
// arca-vaults answers from block 81366458 on), and a grafted deployment starts
// at its graft block. graph-node refuses every query pinned earlier; each type
// listed the same error instead of one line saying what to do.
#[tokio::test]
async fn names_the_first_block_a_pruned_reference_serves() {
    let data = Arc::new(reference_data());
    let reference = mock_graph(move |query| {
        if query.contains("block: {number:") {
            let message = "Failed to decode `block.number` value: `subgraph QmTest only has data \
                           starting at block number 2000 and data for block number 1234 is \
                           therefore not available`";
            return (200, json!({"errors": [{"message": message}]}).to_string());
        }
        serve(&data, BLOCK + 5000, query)
    })
    .await;
    let ours = graph_node(reference_data(), BLOCK).await;
    let dir = project();
    let report = run(dir.path(), &options(&reference.url, Some(&ours.url))).await;
    assert_eq!(
        (report.status, report.exit_code, report.errors),
        (
            Status::Error,
            2,
            vec![
                "The reference answers only from block 2000 on (its history was pruned, or it \
                 was grafted there), and ours is at block 1234. Index past block 2000 and \
                 compare again."
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
            ["owner", "supply", "decimals", "hash", "frozen", "labels"]
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
            json!({"id": format!("t{i:05}"), "minter": {"id": "0xaa"}, "owner": null, "supply": "1",
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
/// `ENVIO_DIFF_TEST_PG=postgres://postgres:postgres@localhost:5432` (and
/// optionally `ENVIO_DIFF_TEST_PG_PREFIX` for the scratch database's name).
///
/// Ours also stores two relations to entities it doesn't have, which
/// graph-node serves as a `null` and as a list without that id.
#[tokio::test]
async fn compares_the_indexers_postgres() {
    let Ok(server) = std::env::var("ENVIO_DIFF_TEST_PG") else {
        eprintln!("skipped: set ENVIO_DIFF_TEST_PG to run the Postgres diff test");
        return;
    };
    let url = url::Url::parse(&server).unwrap();
    let database = format!(
        "{}_{}",
        std::env::var("ENVIO_DIFF_TEST_PG_PREFIX").unwrap_or_else(|_| "diff_test".to_string()),
        std::process::id()
    );
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
INSERT INTO "Account" VALUES ('0xaa', 1.50, '{t02,t77,t01}'), ('0xbb', 0.000, '{}');
CREATE TABLE "Token" (id text PRIMARY KEY, minter_id text NOT NULL, owner_id text,
  supply numeric NOT NULL, decimals integer NOT NULL, hash bytea NOT NULL, frozen boolean,
  labels text[]);
"#,
    );
    for i in 1..=12 {
        let supply = if i == 3 { 7 } else { i * 1000 };
        let owner = match i {
            1 => "'0xbb'",
            2 => "'0xcc'",
            _ => "NULL",
        };
        inserts.push_str(&format!(
            "INSERT INTO \"Token\" VALUES ('t{i:02}', '0xaa', {owner}, {supply}, 18, '\\x{i:02x}ff', NULL, NULL);\n"
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
        (
            outcome(&report),
            report
                .entities
                .iter()
                .map(|e| json!(e.dangling_relations))
                .collect::<Vec<_>>()
        ),
        (
            json!({
                "status": "mismatch", "exitCode": 1, "block": BLOCK, "errors": [],
                "entities": [
                    {"type": "Account", "status": "match", "ours": 2, "theirs": 2, "onlyOurs": [],
                     "onlyTheirs": [], "sampled": 2, "fieldMismatches": {}, "examples": [],
                     "skipped": ["minted: derived (@derivedFrom), not stored"]},
                    {"type": "Token", "status": "mismatch", "ours": 12, "theirs": 12,
                     "onlyOurs": [], "onlyTheirs": [], "sampled": 12,
                     "fieldMismatches": {"supply": 1},
                     "examples": [{"id": "t03", "field": "supply", "ours": "7", "theirs": "3000"}],
                     "skipped": []},
                ],
            }),
            vec![
                json!([{"field": "tokens", "target": "Token", "list": true, "count": 1}]),
                json!([{"field": "owner", "target": "Account", "list": false, "count": 1}]),
            ]
        )
    );
}
