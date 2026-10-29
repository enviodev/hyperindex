//! Which `event.transaction` and `event.block` fields a project's mappings
//! actually read.
//!
//! graph-ts populates both objects in full, so without this every event selects
//! every field. On HyperSync that is close to free; over RPC it forces a whole
//! block with its transactions to be fetched per block, which is the difference
//! between indexing and waiting.
//!
//! The scan is textual and deliberately timid: anything that isn't a plain
//! `.transaction.field` / `.block.field` read — an alias, a computed key, the
//! object passed somewhere — gives up and selects everything, because selecting
//! too little is a wrong answer and selecting too much is only slow.

use std::path::Path;

use crate::config_parsing::human_config::evm::{BlockField, TransactionField};

/// Every mapping source under the project. Reading the whole tree rather than
/// following imports is what makes the scan sound: a helper in another file is
/// scanned whether or not the entry point admits to importing it.
pub fn gather(root: &Path) -> Vec<String> {
    fn walk(dir: &Path, out: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if path.is_dir() {
                if !matches!(name.as_ref(), "node_modules" | ".envio" | "build" | ".git") {
                    walk(&path, out);
                }
            } else if matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("ts") | Some("js") | Some("mts") | Some("mjs")
            ) {
                if let Ok(source) = std::fs::read_to_string(&path) {
                    out.push(source);
                }
            }
        }
    }

    let mut sources = Vec::new();
    walk(root, &mut sources);
    sources
}

/// `gather`, plus every file the manifest's mappings reach through relative
/// imports outside the project directory. A monorepo's subgraph may keep its
/// manifest in `subgraphs/` and its mappings in `../src` (Thales), or share
/// helpers from `../lib` (KlimaDAO): a read of `event.transaction.hash` there
/// that the scan never saw selected no transaction field at all, and the
/// mapping read null.
pub fn gather_with_mappings(root: &Path, mapping_files: &[String]) -> Vec<String> {
    let mut sources = gather(root);
    let root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let import =
        regex::Regex::new(r#"(?:from|import)\s*["']([^"']+)["']"#).expect("valid import pattern");
    let workspace = super::workspace::packages(&root);
    let mut seen = std::collections::HashSet::new();
    let mut queue: std::collections::VecDeque<std::path::PathBuf> = mapping_files
        .iter()
        .filter_map(|file| std::fs::canonicalize(root.join(file)).ok())
        .collect();
    while let Some(file) = queue.pop_front() {
        if seen.len() >= 5_000 || !seen.insert(file.clone()) {
            continue;
        }
        let Ok(source) = std::fs::read_to_string(&file) else {
            continue;
        };
        let dir = file.parent().map(Path::to_path_buf).unwrap_or_default();
        for capture in import.captures_iter(&source) {
            let specifier = &capture[1];
            let found = if specifier.starts_with("./") || specifier.starts_with("../") {
                let base = dir.join(specifier);
                [
                    base.clone(),
                    base.with_extension("ts"),
                    std::path::PathBuf::from(format!("{}.ts", base.display())),
                    base.join("index.ts"),
                ]
                .into_iter()
                .find(|candidate| candidate.is_file())
            } else {
                package_file(&dir, specifier, &workspace)
            };
            if let Some(found) = found.and_then(|found| std::fs::canonicalize(found).ok()) {
                queue.push_back(found);
            }
        }
        // `gather` has read the project directory already, all but node_modules.
        let gathered = file.strip_prefix(&root).is_ok_and(|relative| {
            !relative
                .components()
                .any(|part| part.as_os_str() == "node_modules")
        });
        if !gathered {
            sources.push(source);
        }
    }
    sources
}

/// The AssemblyScript file a bare import names, found the way `asc` finds it:
/// the package under the nearest `node_modules` (or the workspace's package of
/// that name, which an install would link there), then its `ascMain`, a `main`
/// or `types` that is TypeScript, `assembly/index.ts` or `index.ts`; a subpath
/// is a file in the package. graph-ts is the shim's, not the mappings'.
fn package_file(
    from: &Path,
    specifier: &str,
    workspace: &std::collections::BTreeMap<String, std::path::PathBuf>,
) -> Option<std::path::PathBuf> {
    if specifier.starts_with("@graphprotocol/") || specifier.starts_with("node:") {
        return None;
    }
    let parts: Vec<&str> = specifier.split('/').collect();
    let name_length = if specifier.starts_with('@') { 2 } else { 1 };
    if parts.len() < name_length || parts[..name_length].iter().any(|part| part.is_empty()) {
        return None;
    }
    let name = parts[..name_length].join("/");
    let inner = parts[name_length..].join("/");
    let package = from
        .ancestors()
        .map(|dir| dir.join("node_modules").join(&name))
        .find(|dir| dir.is_dir())
        .or_else(|| workspace.get(&name).cloned())?;
    let is_source = |file: &str| {
        file.ends_with(".ts") && !file.ends_with(".d.ts") && package.join(file).is_file()
    };
    let candidates: Vec<String> = if inner.is_empty() {
        let manifest = std::fs::read_to_string(package.join("package.json"))
            .ok()
            .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok());
        let field = |key: &str| {
            manifest
                .as_ref()
                .and_then(|manifest| manifest.get(key)?.as_str().map(str::to_string))
        };
        ["ascMain", "main", "types"]
            .into_iter()
            .filter_map(field)
            .chain(["assembly/index.ts".to_string(), "index.ts".to_string()])
            .collect()
    } else {
        vec![
            inner.clone(),
            format!("{inner}.ts"),
            format!("{inner}/index.ts"),
            format!("assembly/{inner}.ts"),
            format!("assembly/{inner}/index.ts"),
        ]
    };
    candidates
        .into_iter()
        .find(|file| is_source(file))
        .map(|file| package.join(file))
}

/// `None` means the mappings do something this scan can't account for, so the
/// full selection stands.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FieldUsage {
    pub transaction: Option<Vec<TransactionField>>,
    pub block: Option<Vec<BlockField>>,
}

/// graph-ts `ethereum.Transaction` -> what envio selects for it.
fn transaction_field(name: &str) -> Option<TransactionField> {
    Some(match name {
        "hash" => TransactionField::Hash,
        "index" => TransactionField::TransactionIndex,
        "from" => TransactionField::From,
        "to" => TransactionField::To,
        "value" => TransactionField::Value,
        // graph-ts before 0.22 called the gas limit `gasUsed`.
        "gasLimit" | "gasUsed" => TransactionField::Gas,
        "gasPrice" => TransactionField::GasPrice,
        "input" => TransactionField::Input,
        "nonce" => TransactionField::Nonce,
        _ => return None,
    })
}

/// graph-ts `ethereum.Block` -> what envio selects for it. `number`, `hash` and
/// `timestamp` are always present, so they select nothing extra.
fn block_field(name: &str) -> Option<Option<BlockField>> {
    Some(match name {
        "number" | "hash" | "timestamp" => None,
        "parentHash" => Some(BlockField::ParentHash),
        "unclesHash" => Some(BlockField::Sha3Uncles),
        "author" => Some(BlockField::Miner),
        "stateRoot" => Some(BlockField::StateRoot),
        "transactionsRoot" => Some(BlockField::TransactionsRoot),
        "receiptsRoot" => Some(BlockField::ReceiptsRoot),
        "gasUsed" => Some(BlockField::GasUsed),
        "gasLimit" => Some(BlockField::GasLimit),
        "difficulty" => Some(BlockField::Difficulty),
        "totalDifficulty" => Some(BlockField::TotalDifficulty),
        "size" => Some(BlockField::Size),
        "baseFeePerGas" => Some(BlockField::BaseFeePerGas),
        _ => return None,
    })
}

fn is_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '$'
}

/// The identifier read off `source` immediately after `.<property>`, or `None`
/// when what follows isn't a plain property read.
fn read_after(source: &str, property_end: usize) -> Option<&str> {
    let rest = &source[property_end..];
    let mut chars = rest.char_indices();
    let (_, first) = chars.next()?;
    if first != '.' {
        return None;
    }
    let start = property_end + 1;
    let end = source[start..]
        .find(|c: char| !is_ident_char(c))
        .map(|offset| start + offset)
        .unwrap_or(source.len());
    if end == start {
        None
    } else {
        Some(&source[start..end])
    }
}

/// Every `.<property>` occurrence that isn't part of a longer identifier.
fn occurrences(source: &str, property: &str) -> Vec<usize> {
    let needle = format!(".{property}");
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(offset) = source[from..].find(&needle) {
        let start = from + offset;
        let end = start + needle.len();
        let follows_identifier = source[end..].chars().next().is_some_and(is_ident_char);
        let preceded_by_dot = source[..start].ends_with('.');
        if !follows_identifier && !preceded_by_dot {
            found.push(end);
        }
        from = end;
    }
    found
}

/// The graph-ts APIs that need an `eth_call`, which HyperSync and HyperRPC
/// don't serve. `getBalance` and `hasCode` are unambiguous; a contract call is
/// recognised by the binding idiom `graph codegen` emits, `Contract.bind(...)`
/// on a capitalised name — the generated class declares `static bind(`, which
/// has no receiver and so doesn't match.
///
/// Timid in the same way as the field scan, but in the opposite direction:
/// missing a call only restores today's behaviour of failing mid-batch, while a
/// false positive would demand an endpoint from a subgraph that never calls
/// anything.
pub fn rpc_call_site(sources: &[String]) -> Option<String> {
    for source in sources {
        for host in ["ethereum.getBalance", "ethereum.hasCode"] {
            if source.contains(host) {
                return Some(host.to_string());
            }
        }
    }
    for source in sources {
        if let Some(receiver) = bind_receiver(source) {
            return Some(format!("{receiver}.bind(...)"));
        }
    }
    None
}

/// The name a `.bind(` is called on, when it reads as a contract binding.
fn bind_receiver(source: &str) -> Option<&str> {
    let mut from = 0;
    while let Some(offset) = source[from..].find(".bind(") {
        let dot = from + offset;
        from = dot + ".bind(".len();
        let start = source[..dot]
            .rfind(|c: char| !is_ident_char(c))
            .map(|index| index + 1)
            .unwrap_or(0);
        let name = &source[start..dot];
        if name.starts_with(|c: char| c.is_ascii_uppercase()) {
            return Some(name);
        }
    }
    None
}

pub fn scan(sources: &[String]) -> FieldUsage {
    let mut transaction = Some(Vec::new());
    let mut block = Some(Vec::new());

    for source in sources {
        for end in occurrences(source, "transaction") {
            match read_after(source, end).and_then(transaction_field) {
                Some(field) => {
                    if let Some(fields) = transaction.as_mut() {
                        if !fields.contains(&field) {
                            fields.push(field);
                        }
                    }
                }
                None => transaction = None,
            }
        }

        for end in occurrences(source, "block") {
            match read_after(source, end).and_then(block_field) {
                Some(Some(field)) => {
                    if let Some(fields) = block.as_mut() {
                        if !fields.contains(&field) {
                            fields.push(field);
                        }
                    }
                }
                Some(None) => {}
                None => block = None,
            }
        }
    }

    FieldUsage { transaction, block }
}

/// The header fields of an `ethereum.Block` that a block handler cannot be
/// handed for free: envio gives a block handler only the block number, so
/// everything but `number` and `timestamp` has to be fetched afterwards.
const FREE_BLOCK_PROPERTIES: &[&str] = &["number", "timestamp"];

/// Every field of an `ethereum.Block`, by the name envio selects it under.
pub const BLOCK_HEADER_FIELDS: &[&str] = &[
    "hash",
    "parentHash",
    "sha3Uncles",
    "miner",
    "stateRoot",
    "transactionsRoot",
    "receiptsRoot",
    "gasUsed",
    "gasLimit",
    "timestamp",
    "difficulty",
    "totalDifficulty",
    "size",
    "baseFeePerGas",
];

/// The block fields a block handler reads, by envio's names: the whole header
/// once it reads anything past `number` and `timestamp` (or hands its block
/// on), else `timestamp` if it reads that, else nothing.
pub fn block_handler_fields(sources: &[String], handler: &str) -> Vec<String> {
    let reads = sources
        .iter()
        .filter_map(|source| handler_block_reads(source, handler))
        .fold((false, false), |(timestamp, header), (t, h)| {
            (timestamp || t, header || h)
        });
    match reads {
        (_, true) => BLOCK_HEADER_FIELDS.iter().map(|f| f.to_string()).collect(),
        (true, false) => vec!["timestamp".to_string()],
        (false, false) => Vec::new(),
    }
}

/// The code with its string literals and comments emptied: a `"block-"` in an
/// id is not a use of the handler's `block`.
fn strip_literals(code: &str) -> String {
    let literals = regex::Regex::new(
        r#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`|//[^\n]*|/\*(?s:.*?)\*/"#,
    )
    .expect("valid literal pattern");
    literals.replace_all(code, "\"\"").into_owned()
}

/// Whether the handler reads its block's timestamp, and whether it reads any
/// other header field. `None` when the source doesn't define the handler.
fn handler_block_reads(source: &str, handler: &str) -> Option<(bool, bool)> {
    let signature = regex::Regex::new(&format!(
        r"function\s+{}\s*\(\s*([A-Za-z_$][A-Za-z0-9_$]*)",
        regex::escape(handler)
    ))
    .expect("valid signature pattern");
    let found = signature.captures(source)?;
    let param = found.get(1).expect("one group").as_str();
    let after_param = found.get(0).expect("whole match").end();
    // The body: from the first `{` after the signature to its closing brace.
    let rest = &source[after_param..];
    let open = rest.find('{')?;
    let mut depth = 0usize;
    let mut end = rest.len();
    for (at, c) in rest[open..].char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    end = open + at;
                    break;
                }
            }
            _ => {}
        }
    }
    let body = strip_literals(&rest[open..end]);
    let body = body.as_str();
    let uses = regex::Regex::new(&format!(
        r"(^|[^A-Za-z0-9_$.]){}\b(\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*))?",
        regex::escape(param)
    ))
    .expect("valid use pattern");
    let mut timestamp = false;
    let mut header = false;
    for capture in uses.captures_iter(body) {
        match capture.get(3).map(|property| property.as_str()) {
            Some("timestamp") => timestamp = true,
            Some(property) if FREE_BLOCK_PROPERTIES.contains(&property) => {}
            _ => header = true,
        }
    }
    Some((timestamp, header))
}

#[cfg(test)]
mod gather_tests {
    use super::*;
    use tempdir::TempDir;

    #[test]
    fn reads_mappings_outside_the_project_directory() {
        let dir = TempDir::new("envio_subgraph_usage").unwrap();
        let write = |path: &str, source: &str| {
            let file = dir.path().join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, source).unwrap();
        };
        write("subgraphs/subgraph.yaml", "");
        write(
            "src/mapping.ts",
            "import { id } from \"../lib/ids\";\nexport function handle(event: any): void { id(event); }",
        );
        write(
            "lib/ids.ts",
            "export function id(event: any): string { return event.transaction.hash.toHex(); }",
        );
        write("unrelated/other.ts", "export const x = event.block.number;");
        let sources = gather_with_mappings(
            &dir.path().join("subgraphs"),
            &["../src/mapping.ts".to_string()],
        );
        assert_eq!(
            scan(&sources).transaction,
            Some(vec![TransactionField::Hash])
        );
    }

    // Enzyme builds every event id with `uniqueEventId(event)` from its
    // workspace package `@enzymefinance/subgraph-utils`, imported by name and
    // linked into node_modules; OpenZeppelin's subgraphs ship their mappings in
    // node_modules. Neither was scanned, so no transaction field was selected
    // and `event.transaction.hash` read null.
    #[test]
    fn reads_packages_the_mappings_import() {
        let dir = TempDir::new("envio_subgraph_usage_packages").unwrap();
        let write = |path: &str, source: &str| {
            let file = dir.path().join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, source).unwrap();
        };
        write(
            "packages/utils/package.json",
            r#"{"name":"@enzymefinance/subgraph-utils","main":"index.ts"}"#,
        );
        write("packages/utils/index.ts", "export * from './utils/id';\n");
        write(
            "packages/utils/utils/id.ts",
            "export function uniqueEventId(event: ethereum.Event): string { return event.transaction.hash.toHex(); }",
        );
        write(
            "subgraph/src/feed.ts",
            "import { uniqueEventId } from '@enzymefinance/subgraph-utils';\nexport function handle(event: any): void { uniqueEventId(event); }",
        );
        write(
            "subgraph/node_modules/@openzeppelin/subgraphs/src/datasources/voting.ts",
            "export function handleVote(event: any): void { let from = event.transaction.from; }",
        );
        std::fs::create_dir_all(dir.path().join("subgraph/node_modules/@enzymefinance")).unwrap();
        std::os::unix::fs::symlink(
            dir.path().join("packages/utils"),
            dir.path()
                .join("subgraph/node_modules/@enzymefinance/subgraph-utils"),
        )
        .unwrap();
        let sources = gather_with_mappings(
            &dir.path().join("subgraph"),
            &[
                "./src/feed.ts".to_string(),
                "./node_modules/@openzeppelin/subgraphs/src/datasources/voting.ts".to_string(),
            ],
        );
        assert_eq!(
            scan(&sources).transaction,
            Some(vec![TransactionField::From, TransactionField::Hash])
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan_one(source: &str) -> FieldUsage {
        scan(&[source.to_string()])
    }

    #[test]
    fn selects_only_the_fields_a_mapping_reads() {
        let usage = scan_one(
            r#"
            export function handleTransfer(event: Transfer): void {
              const entity = new TransferEvent(event.transaction.hash.toHexString());
              entity.timestamp = event.block.timestamp.toI32();
              entity.gas = event.transaction.gasLimit;
              entity.miner = event.block.author;
            }
            "#,
        );
        assert_eq!(
            usage,
            FieldUsage {
                transaction: Some(vec![TransactionField::Hash, TransactionField::Gas]),
                block: Some(vec![BlockField::Miner]),
            }
        );
    }

    #[test]
    fn selects_the_gas_limit_for_a_pre_0_22_gas_used() {
        assert_eq!(
            scan_one("transaction.gasUsed = event.transaction.gasUsed").transaction,
            Some(vec![TransactionField::Gas])
        );
    }

    #[test]
    fn selects_nothing_when_the_mapping_touches_neither() {
        let usage = scan_one(
            r#"
            export function handleTransfer(event: Transfer): void {
              const entity = new TransferEvent(event.logIndex.toString());
              entity.from = event.params.from;
            }
            "#,
        );
        assert_eq!(
            usage,
            FieldUsage {
                transaction: Some(vec![]),
                block: Some(vec![]),
            }
        );
    }

    #[test]
    fn gives_up_on_an_alias() {
        let usage = scan_one("const tx = event.transaction;\nentity.hash = tx.hash;");
        assert_eq!(usage.transaction, None);
        assert_eq!(usage.block, Some(vec![]));
    }

    #[test]
    fn gives_up_on_a_computed_key() {
        assert_eq!(scan_one(r#"event.block["number"]"#).block, None);
    }

    #[test]
    fn gives_up_on_a_field_it_does_not_know() {
        assert_eq!(scan_one("event.block.withdrawalsRoot").block, None);
        assert_eq!(scan_one("event.transaction.maxFeePerGas").transaction, None);
    }

    #[test]
    fn ignores_longer_identifiers_and_nested_reads() {
        // `transactionLogIndex` and `blockNumber` are their own properties, and
        // `receipt.transaction` is not the event's.
        let usage = scan_one("event.transactionLogIndex; log.blockNumber; a.b.transaction.hash;");
        assert_eq!(
            usage,
            FieldUsage {
                transaction: Some(vec![TransactionField::Hash]),
                block: Some(vec![]),
            }
        );
    }

    #[test]
    fn one_ambiguous_file_gives_up_for_all_of_them() {
        let usage = scan(&[
            "event.transaction.hash".to_string(),
            "helper(event.transaction)".to_string(),
        ]);
        assert_eq!(usage.transaction, None);
    }

    #[test]
    fn finds_the_binding_a_mapping_calls_through() {
        assert_eq!(
            rpc_call_site(&["let pair = PairContract.bind(event.address)".to_string()]),
            Some("PairContract.bind(...)".to_string())
        );
    }

    #[test]
    fn finds_the_host_calls_that_need_an_endpoint() {
        assert_eq!(
            rpc_call_site(&["ethereum.hasCode(address)".to_string()]),
            Some("ethereum.hasCode".to_string())
        );
    }

    #[test]
    fn ignores_a_mapping_that_calls_nothing() {
        assert_eq!(
            rpc_call_site(&["store.set(\"Domain\", id, domain)".to_string()]),
            None
        );
    }

    #[test]
    fn ignores_the_generated_declaration_and_plain_js_binds() {
        // `static bind(` has no receiver, and a lowercase one is a function
        // being bound rather than a contract.
        assert_eq!(
            rpc_call_site(&[
                "static bind(address: Address): Token {".to_string(),
                "const run = handler.bind(this)".to_string(),
            ]),
            None
        );
    }
}

#[cfg(test)]
mod block_handler_tests {
    use super::*;

    fn fields(source: &str) -> Vec<String> {
        block_handler_fields(&[source.to_string()], "handleBlock")
    }

    fn header() -> Vec<String> {
        BLOCK_HEADER_FIELDS.iter().map(|f| f.to_string()).collect()
    }

    #[test]
    fn selects_what_the_handler_reads() {
        assert_eq!(
            (
                fields("export function handleBlock(block: ethereum.Block): void { let n = block.number; }"),
                fields(
                    "export function handleBlock(block: ethereum.Block): void { let t = block.timestamp; let n = block.number; }"
                ),
                fields(
                    "export function handleBlock(block: ethereum.Block): void { let e = new Block(block.hash.toHex()); }"
                ),
                fields("export function handleBlock(b: ethereum.Block): void { x.parent = b.parentHash; }"),
            ),
            (vec![], vec!["timestamp".to_string()], header(), header())
        );
    }

    #[test]
    fn a_block_named_in_a_string_is_not_a_use() {
        assert_eq!(
            fields(
                "export function handleBlock(block: ethereum.Block): void { store.set('P', \"block-\" + block.number.toString()); } // block"
            ),
            Vec::<String>::new()
        );
    }

    #[test]
    fn a_block_handed_to_a_helper_is_a_read() {
        assert_eq!(
            fields("export function handleBlock(block: ethereum.Block): void { index(block); }"),
            header()
        );
    }

    #[test]
    fn a_block_variable_elsewhere_is_not_the_handlers() {
        assert_eq!(
            fields(
                "export function handleBlock(block: ethereum.Block): void { let n = block.number; }\n\
                 export function other(event: Ev): void { let block = event.block; block.hash; }"
            ),
            Vec::<String>::new()
        );
    }

    #[test]
    fn a_handler_in_another_file_is_still_found() {
        let sources = vec![
            "export const x = 1;".to_string(),
            "export function handleBlock(block: ethereum.Block): void { block.author; }"
                .to_string(),
        ];
        assert_eq!(block_handler_fields(&sources, "handleBlock"), header());
    }
}
