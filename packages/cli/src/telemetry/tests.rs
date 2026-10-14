use super::*;
use serde_json::json;
use std::collections::BTreeSet;

const SCHEMA: &str = r#"
type SecretVaultDeposit {
  id: ID!
  ownerAddress: String!
}
"#;

/// Every user-supplied value a config can carry, each one distinctive so a leak
/// into the payload is easy to spot.
fn config() -> SystemConfig {
    let yaml = r#"
name: acme-private-indexer
description: Indexes the secret vault
contracts:
  - name: SecretVault
    handler: ./src/secret/handlers.ts
    events:
      - event: SecretMoved(address indexed owner, uint256 amount)
chains:
  - id: 1
    start_block: 0
    end_block: 20000000
    rpc:
      url: https://rpc.example-provider.io/v2/${RPC_KEY}
      for: fallback
    contracts:
      - name: SecretVault
        address: "0x1234567890123456789012345678901234567890"
  - id: 31337
    start_block: 0
    rpc:
      url: http://devnet.internal-host.lan:8545
      ws: ws://devnet.internal-host.lan:8546
      for: sync
    contracts:
      - name: SecretVault
        address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
"#;
    let env = HashMap::from([("RPC_KEY".to_string(), "sk-live-SECRETTOKEN".to_string())]);
    SystemConfig::parse_yaml(yaml, Some(SCHEMA), &env, &HashMap::new(), false)
        .expect("config should parse")
}

fn fixed_context() -> Context {
    Context {
        install_id: Some("11111111-1111-4111-8111-111111111111".to_string()),
        session_id: "22222222-2222-4222-8222-222222222222".to_string(),
        envio_version: "2.40.0".to_string(),
        os: "linux".to_string(),
        arch: "x86_64".to_string(),
        node_major: Some(22),
        ci: false,
        environment: Environment::Docker,
    }
}

fn batch() -> Batch {
    let errors = HashMap::from([
        ("source".to_string(), 3),
        ("handler".to_string(), 0),
        ("an unknown class".to_string(), 7),
    ]);
    let features = [
        "effects".to_string(),
        "contract_register".to_string(),
        "SecretVault".to_string(),
    ];
    Batch {
        schema_version: SCHEMA_VERSION,
        context: fixed_context(),
        events: vec![
            Event::Command(CommandEvent {
                indexer_id: Some("33333333-3333-4333-8333-333333333333".to_string()),
                command: CommandName::Init,
                outcome: Outcome::Success,
                error_class: None,
                duration: DurationBucket::OneToFiveSeconds,
                init: Some(InitChoice {
                    ecosystem: event::Ecosystem::Evm,
                    flow: event::InitFlow::Template,
                    template: Some(event::InitTemplate::Erc20),
                    language: event::Language::Typescript,
                }),
            }),
            Event::Heartbeat(heartbeat_event(
                Some("33333333-3333-4333-8333-333333333333".to_string()),
                HeartbeatReason::Interval,
                IndexerProfile::of(&config()),
                &RuntimeReport {
                    reason: "interval",
                    features: &features,
                    synced: true,
                    uptime_seconds: 7.0 * 3600.0,
                    events_processed: 250_000.0,
                    errors: &errors,
                },
            )),
        ],
    }
}

#[test]
fn batch_has_the_documented_shape() {
    assert_eq!(
        serde_json::to_value(batch()).unwrap(),
        json!({
            "schema_version": 1,
            "context": {
                "install_id": "11111111-1111-4111-8111-111111111111",
                "session_id": "22222222-2222-4222-8222-222222222222",
                "envio_version": "2.40.0",
                "os": "linux",
                "arch": "x86_64",
                "node_major": 22,
                "ci": false,
                "environment": "docker"
            },
            "events": [
                {
                    "type": "command",
                    "indexer_id": "33333333-3333-4333-8333-333333333333",
                    "command": "init",
                    "outcome": "success",
                    "error_class": null,
                    "duration": "1-5s",
                    "init": {
                        "ecosystem": "evm",
                        "flow": "template",
                        "template": "erc20",
                        "language": "typescript"
                    }
                },
                {
                    "type": "heartbeat",
                    "indexer_id": "33333333-3333-4333-8333-333333333333",
                    "reason": "interval",
                    "ecosystem": "evm",
                    "language": "typescript",
                    "chains": [
                        {"chain_id": 1, "sources": ["hypersync", "rpc_fallback"]},
                        {"chain_id": 31337, "sources": ["rpc", "rpc_ws"]}
                    ],
                    "contracts": 1,
                    "events": 1,
                    "entities": 1,
                    "storage": ["postgres"],
                    "features": ["end_block", "effects", "contract_register"],
                    "sync_state": "synced",
                    "uptime": "6-24h",
                    "events_processed": "100k-10m",
                    "errors": {"source": 3}
                }
            ]
        })
    );
}

fn keys(value: &serde_json::Value, out: &mut BTreeSet<String>) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, value) in map {
                out.insert(key.clone());
                keys(value, out);
            }
        }
        serde_json::Value::Array(items) => items.iter().for_each(|item| keys(item, out)),
        _ => {}
    }
}

#[test]
fn batch_carries_nothing_the_user_wrote() {
    let payload = serde_json::to_string(&batch()).unwrap();
    let forbidden = [
        "acme-private-indexer",
        "Indexes the secret vault",
        "SecretVault",
        "SecretMoved",
        "owner",
        "0x1234567890123456789012345678901234567890",
        "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        "example-provider",
        "SECRETTOKEN",
        "RPC_KEY",
        "internal-host",
        "8545",
        "./src",
        "handlers.ts",
        "schema.graphql",
        "config.yaml",
        "abi",
        "/",
    ];
    let leaked: Vec<&str> = forbidden
        .into_iter()
        .filter(|needle| payload.contains(needle))
        .collect();

    let mut found = BTreeSet::new();
    keys(&serde_json::to_value(batch()).unwrap(), &mut found);
    let allowed: BTreeSet<String> = [
        "schema_version",
        "context",
        "install_id",
        "session_id",
        "envio_version",
        "os",
        "arch",
        "node_major",
        "ci",
        "environment",
        "events",
        "type",
        "indexer_id",
        "command",
        "outcome",
        "error_class",
        "duration",
        "init",
        "ecosystem",
        "flow",
        "template",
        "language",
        "reason",
        "chains",
        "chain_id",
        "sources",
        "contracts",
        "entities",
        "storage",
        "features",
        "sync_state",
        "uptime",
        "events_processed",
        "errors",
        // Error classes are the keys of `errors`.
        "source",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    let unexpected: Vec<String> = found.difference(&allowed).cloned().collect();

    assert_eq!(
        (leaked, unexpected),
        (Vec::<&str>::new(), Vec::<String>::new())
    );
}

#[test]
fn node_major_reads_process_versions_node() {
    assert_eq!(
        (node_major("22.18.0"), node_major("v24.1.0"), node_major("")),
        (Some(22), Some(24), None)
    );
}
