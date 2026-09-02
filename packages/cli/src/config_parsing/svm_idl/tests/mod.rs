use std::fmt::Write;

use hypersync_client_solana::decode::{EnumVariant, FieldType, NamedField};
use pretty_assertions::assert_eq;

use super::*;

fn render(idl: &ProgramIdl) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "address: {}", idl.address.as_deref().unwrap_or("-"));
    for (name, ix) in &idl.instructions {
        let accounts = ix
            .accounts
            .iter()
            .map(|a| {
                if a.optional {
                    format!("{}:?", a.name)
                } else {
                    a.name.clone()
                }
            })
            .collect::<Vec<_>>()
            .join(", ");
        let _ = writeln!(
            out,
            "instruction {name} 0x{} ({accounts}) ({})",
            crate::hex::encode(&ix.discriminator),
            render_fields(&ix.args)
        );
    }
    for (name, ty) in &idl.defined_types {
        let _ = writeln!(out, "type {name} = {}", render_type(ty));
    }
    for (name, reason) in &idl.unusable {
        let _ = writeln!(out, "unusable instruction {name}: {reason}");
    }
    for (name, reason) in &idl.unusable_types {
        let _ = writeln!(out, "unusable type {name}: {reason}");
    }
    out
}

fn render_fields(fields: &[NamedField]) -> String {
    fields
        .iter()
        .map(|f| format!("{}: {}", f.name, render_type(&f.ty)))
        .collect::<Vec<_>>()
        .join(", ")
}

fn render_type(ty: &FieldType) -> String {
    match ty {
        FieldType::Option(inner) => format!("Option<{}>", render_type(inner)),
        FieldType::Vec(inner) => format!("Vec<{}>", render_type(inner)),
        FieldType::Array { ty, len } => format!("[{}; {len}]", render_type(ty)),
        FieldType::Struct(fields) => format!("{{{}}}", render_fields(fields)),
        FieldType::Enum(variants) => format!(
            "enum {{{}}}",
            variants
                .iter()
                .map(|EnumVariant { name, fields }| match fields {
                    None => name.clone(),
                    Some(fields) => format!("{name}({})", render_fields(fields)),
                })
                .collect::<Vec<_>>()
                .join(", ")
        ),
        FieldType::Defined(name) => format!("@{name}"),
        primitive => format!("{primitive:?}").to_lowercase(),
    }
}

/// `path` is relative to the crate root.
fn read_fixture(path: &str) -> String {
    let path = format!("{}/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path}: {e}"))
}

/// The published SPL Token and SPL Memo IDLs, unmodified. Both declare
/// instructions Borsh cannot express, and the point of the pair is that such an
/// instruction costs only itself: SPL Token keeps the other 26, while Memo —
/// whose whole payload is a remainder-encoded string — has only the one and is
/// left with an empty catalog.
#[test]
fn parses_the_published_spl_idls() {
    let catalog = |file: &str| {
        let idl =
            parse_idl("idl.json", &read_fixture(&format!("test/idls/{file}"))).expect("parse");
        (
            idl.address,
            idl.instructions.len(),
            idl.defined_types.keys().cloned().collect::<Vec<_>>(),
            idl.unusable,
        )
    };

    assert_eq!(
        [
            catalog("spl-token.codama.json"),
            catalog("memo.codama.json")
        ],
        [
            (
                Some("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA".to_string()),
                26,
                vec!["accountState".to_string(), "authorityType".to_string()],
                Unusable::from([
                    (
                        "batch".to_string(),
                        "idl.json:2774:7: args.data.item.instructionData.prefix: Borsh needs u32 \
                         here, got u8"
                            .to_string()
                    ),
                    (
                        "uiAmountToAmount".to_string(),
                        "idl.json:2505:7: args.uiAmount: a bare stringTypeNode carries no length; \
                         Borsh needs it wrapped in a sizePrefixTypeNode with a u32 prefix"
                            .to_string()
                    ),
                ]),
            ),
            (
                Some("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr".to_string()),
                0,
                Vec::new(),
                Unusable::from([(
                    "addMemo".to_string(),
                    "idl.json:8:7: args.memo: a bare stringTypeNode carries no length; Borsh needs \
                     it wrapped in a sizePrefixTypeNode with a u32 prefix"
                        .to_string()
                )]),
            ),
        ]
    );
}

/// A reason is reported against the file and the entry it is about, the way an
/// ABI's is: `path:line:column` for an instruction or type the file was seen
/// to hold, the path alone for what fails before any entry is read.
#[test]
fn points_each_reason_at_the_entry_in_the_file() {
    let json = "{\n  \"instructions\": [\n    { \"name\": \"swap\", \"discriminator\": [1, 2, \
                3] },\n    { \"name\": \"burn\", \"discriminator\": [4] }\n  ],\n  \"types\": \
                [\n    { \"name\": \"Loop\", \"type\": { \"kind\": \"type\", \"alias\": { \
                \"defined\": \"Loop\" } } }\n  ]\n}";
    let fatal = |json: &str| {
        format!(
            "{:#}",
            parse_idl("idls/pool.json", json).expect_err("fatal")
        )
    };

    assert_eq!(
        (
            render(&parse_idl("idls/pool.json", json).expect("parse")),
            fatal("not json"),
            fatal("[]"),
            fatal(r#"{ "instructions": [{ "name": "swap" }, { "name": "swap" }] }"#),
        ),
        (
            "address: -\n\
             instruction burn 0x04 () ()\n\
             unusable instruction swap: idls/pool.json:3:5: its discriminator is 3 bytes, and \
             dispatch matches only 1, 2, 4, or 8\n\
             unusable type Loop: idls/pool.json:7:5: it recursively contains itself without an \
             option or vec to terminate decoding\n"
                .to_string(),
            "idls/pool.json is not valid JSON: expected ident at line 1 column 2".to_string(),
            "idls/pool.json: expected a JSON object at the IDL root".to_string(),
            "idls/pool.json: IDL declares instruction 'swap' more than once".to_string(),
        )
    );
}

#[test]
fn parses_a_codama_program_node_without_root_wrapper() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "kind": "programNode",
          "name": "splToken",
          "publicKey": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
          "instructions": [{
            "kind": "instructionNode",
            "name": "transfer",
            "accounts": [
              { "kind": "instructionAccountNode", "name": "source", "isWritable": true },
              { "kind": "instructionAccountNode", "name": "destination", "isWritable": true }
            ],
            "arguments": [
              {
                "kind": "instructionArgumentNode",
                "name": "discriminator",
                "type": { "kind": "numberTypeNode", "format": "u8" },
                "defaultValue": { "kind": "numberValueNode", "number": 3 }
              },
              { "kind": "instructionArgumentNode", "name": "amount",
                "type": { "kind": "numberTypeNode", "format": "u64" } }
            ],
            "discriminators": [{ "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }]
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\n\
         instruction transfer 0x03 (source, destination) (amount: u64)\n"
    );
}

/// A legacy IDL declares no address and no inline discriminator, so the bytes
/// are derived: `sha256("global:<snake_case>")[..8]`.
#[test]
fn derives_discriminators_for_legacy_anchor_idl() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "version": "0.1.0",
          "name": "legacy_program",
          "instructions": [{
            "name": "sharedAccountsRoute",
            "accounts": [
              { "name": "tokenProgram", "isMut": false, "isSigner": false },
              { "name": "userTransferAuthority", "isMut": true, "isSigner": true },
              { "name": "platformFeeAccount", "isMut": true, "isSigner": false, "isOptional": true }
            ],
            "args": [
              { "name": "id", "type": "u8" },
              { "name": "routePlan", "type": { "vec": { "defined": "RoutePlanStep" } } },
              { "name": "limitPrice", "type": { "option": "u64" } }
            ]
          }],
          "types": [{
            "name": "RoutePlanStep",
            "type": {
              "kind": "struct",
              "fields": [
                { "name": "percent", "type": "u8" },
                { "name": "swap", "type": { "defined": "Swap" } }
              ]
            }
          }, {
            "name": "Swap",
            "type": {
              "kind": "enum",
              "variants": [
                { "name": "Saber" },
                { "name": "Serum", "fields": [{ "name": "side", "type": "u8" }] },
                { "name": "Raydium", "fields": ["u8", "u64"] }
              ]
            }
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         instruction sharedAccountsRoute 0xc1209b3341d69c81 (tokenProgram, userTransferAuthority, platformFeeAccount:?) (id: u8, routePlan: Vec<@RoutePlanStep>, limitPrice: Option<u64>)\n\
         type RoutePlanStep = {percent: u8, swap: @Swap}\n\
         type Swap = enum {Saber, Serum(side: u8), Raydium(_0: u8, _1: u64)}\n"
    );
}

/// Anchor derives the pre-0.30 discriminator from snake_case that splits an
/// acronym run. A converter that only breaks on lower→upper collapses `CLMM`
/// into one word and derives the wrong bytes for every such instruction —
/// silently, since the IDL still parses.
#[test]
fn splits_acronym_runs_like_anchor_does() {
    let idl = parse_idl(
        "idl.json",
        r#"{ "instructions": [{ "name": "raydiumCLMMSwap", "accounts": [], "args": [] }] }"#,
    )
    .expect("parse");
    assert_eq!(
        render(&idl),
        "address: -\ninstruction raydiumCLMMSwap 0x2fb8d5c123d25704 () ()\n"
    );
}

/// Anchor 0.30+ ships inline discriminators, `metadata.address`, and
/// `{"defined": {"name": T}}` type refs; an event's payload lives in `types`
/// under the event's own name.
#[test]
fn parses_anchor_030_idl() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "address": "MyProgram1111111111111111111111111111111111",
          "metadata": { "name": "my_program", "version": "0.1.0", "spec": "0.1.0" },
          "instructions": [{
            "name": "initialize",
            "discriminator": [175, 175, 109, 31, 13, 152, 155, 237],
            "accounts": [
              { "name": "payer", "writable": true, "signer": true },
              { "name": "config", "writable": true },
              { "name": "optionalAuthority", "optional": true },
              { "name": "nested", "accounts": [{ "name": "systemProgram" }] }
            ],
            "args": [
              { "name": "seed", "type": { "array": ["u8", 32] } },
              { "name": "authority", "type": "pubkey" },
              { "name": "config", "type": { "defined": { "name": "Config" } } }
            ]
          }],
          "events": [{
            "name": "Initialized",
            "discriminator": [1, 2, 3, 4, 5, 6, 7, 8]
          }],
          "types": [{
            "name": "Config",
            "type": { "kind": "struct", "fields": [{ "name": "fee", "type": "u16" }] }
          }, {
            "name": "Initialized",
            "type": {
              "kind": "struct",
              "fields": [
                { "name": "slot", "type": "u64" },
                { "name": "label", "type": "string" }
              ]
            }
          }, {
            "name": "Alias",
            "type": { "kind": "type", "alias": "pubkey" }
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: MyProgram1111111111111111111111111111111111\n\
         instruction initialize 0xafaf6d1f0d989bed (payer, config, optionalAuthority:?, nestedSystemProgram) (seed: [u8; 32], authority: pubkey, config: @Config)\n\
         type Alias = pubkey\n\
         type Config = {fee: u16}\n\
         type Initialized = {slot: u64, label: string}\n"
    );
}

/// SPL Token is the case Anchor cannot express and the reason Codama is in the
/// spec: a 1-byte discriminator carried by a regular argument, a two-byte one
/// packed from two such arguments, and a literal byte constant.
#[test]
fn parses_codama_spl_token_idl() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "kind": "rootNode",
          "standard": "codama",
          "version": "1.0.0",
          "program": {
            "kind": "programNode",
            "name": "splToken",
            "publicKey": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
            "version": "3.5.0",
            "instructions": [
              {
                "kind": "instructionNode",
                "name": "transfer",
                "accounts": [
                  { "kind": "instructionAccountNode", "name": "source", "isWritable": true, "isSigner": false },
                  { "kind": "instructionAccountNode", "name": "destination", "isWritable": true, "isSigner": false },
                  { "kind": "instructionAccountNode", "name": "authority", "isWritable": false, "isSigner": "either" }
                ],
                "arguments": [
                  {
                    "kind": "instructionArgumentNode",
                    "name": "discriminator",
                    "type": { "kind": "numberTypeNode", "format": "u8", "endian": "le" },
                    "defaultValue": { "kind": "numberValueNode", "number": 3 },
                    "defaultValueStrategy": "omitted"
                  },
                  {
                    "kind": "instructionArgumentNode",
                    "name": "amount",
                    "type": { "kind": "numberTypeNode", "format": "u64", "endian": "le" }
                  }
                ],
                "discriminators": [
                  { "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }
                ]
              },
              {
                "kind": "instructionNode",
                "name": "initializeMint",
                "accounts": [
                  { "kind": "instructionAccountNode", "name": "mint", "isWritable": true, "isSigner": false },
                  { "kind": "instructionAccountNode", "name": "rent", "isWritable": false, "isSigner": false, "isOptional": true }
                ],
                "arguments": [
                  {
                    "kind": "instructionArgumentNode",
                    "name": "discriminator",
                    "type": { "kind": "numberTypeNode", "format": "u8", "endian": "le" },
                    "defaultValue": { "kind": "numberValueNode", "number": 0 },
                    "defaultValueStrategy": "omitted"
                  },
                  { "kind": "instructionArgumentNode", "name": "decimals", "type": { "kind": "numberTypeNode", "format": "u8" } },
                  { "kind": "instructionArgumentNode", "name": "mintAuthority", "type": { "kind": "publicKeyTypeNode" } },
                  {
                    "kind": "instructionArgumentNode",
                    "name": "freezeAuthority",
                    "type": { "kind": "optionTypeNode", "item": { "kind": "publicKeyTypeNode" } }
                  }
                ],
                "discriminators": [
                  { "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }
                ]
              },
              {
                "kind": "instructionNode",
                "name": "transferChecked",
                "accounts": [
                  { "kind": "instructionAccountNode", "name": "source", "isWritable": true, "isSigner": false }
                ],
                "arguments": [
                  {
                    "kind": "instructionArgumentNode",
                    "name": "discriminator",
                    "type": { "kind": "numberTypeNode", "format": "u8", "endian": "le" },
                    "defaultValue": { "kind": "numberValueNode", "number": 12 },
                    "defaultValueStrategy": "omitted"
                  },
                  {
                    "kind": "instructionArgumentNode",
                    "name": "subDiscriminator",
                    "type": { "kind": "numberTypeNode", "format": "u8", "endian": "le" },
                    "defaultValue": { "kind": "numberValueNode", "number": 1 },
                    "defaultValueStrategy": "omitted"
                  },
                  { "kind": "instructionArgumentNode", "name": "amount", "type": { "kind": "numberTypeNode", "format": "u64" } }
                ],
                "discriminators": [
                  { "kind": "fieldDiscriminatorNode", "name": "subDiscriminator", "offset": 1 },
                  { "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }
                ]
              },
              {
                "kind": "instructionNode",
                "name": "syncNative",
                "accounts": [],
                "arguments": [],
                "discriminators": [
                  {
                    "kind": "constantDiscriminatorNode",
                    "offset": 0,
                    "constant": {
                      "kind": "constantValueNode",
                      "type": { "kind": "bytesTypeNode" },
                      "value": { "kind": "bytesValueNode", "data": "11", "encoding": "base16" }
                    }
                  }
                ]
              }
            ],
            "definedTypes": [
              {
                "kind": "definedTypeNode",
                "name": "accountState",
                "type": {
                  "kind": "enumTypeNode",
                  "variants": [
                    { "kind": "enumEmptyVariantTypeNode", "name": "uninitialized" },
                    { "kind": "enumStructVariantTypeNode", "name": "frozen", "struct": {
                      "kind": "structTypeNode",
                      "fields": [{ "kind": "structFieldTypeNode", "name": "since", "type": { "kind": "numberTypeNode", "format": "u64" } }]
                    } },
                    { "kind": "enumTupleVariantTypeNode", "name": "initialized", "tuple": {
                      "kind": "tupleTypeNode",
                      "items": [{ "kind": "booleanTypeNode" }, { "kind": "publicKeyTypeNode" }]
                    } }
                  ]
                }
              },
              {
                "kind": "definedTypeNode",
                "name": "multisig",
                "type": {
                  "kind": "structTypeNode",
                  "fields": [
                    { "kind": "structFieldTypeNode", "name": "m", "type": { "kind": "numberTypeNode", "format": "u8" } },
                    { "kind": "structFieldTypeNode", "name": "signers", "type": {
                      "kind": "arrayTypeNode",
                      "item": { "kind": "publicKeyTypeNode" },
                      "count": { "kind": "fixedCountNode", "value": 11 }
                    } },
                    { "kind": "structFieldTypeNode", "name": "memo", "type": {
                      "kind": "sizePrefixTypeNode",
                      "type": { "kind": "stringTypeNode", "encoding": "utf8" },
                      "prefix": { "kind": "numberTypeNode", "format": "u32" }
                    } },
                    { "kind": "structFieldTypeNode", "name": "history", "type": {
                      "kind": "arrayTypeNode",
                      "item": { "kind": "definedTypeLinkNode", "name": "accountState" },
                      "count": { "kind": "prefixedCountNode", "prefix": { "kind": "numberTypeNode", "format": "u32" } }
                    } }
                  ]
                }
              }
            ]
          }
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\n\
         instruction initializeMint 0x00 (mint, rent:?) (decimals: u8, mintAuthority: pubkey, freezeAuthority: Option<pubkey>)\n\
         instruction syncNative 0x11 () ()\n\
         instruction transfer 0x03 (source, destination, authority) (amount: u64)\n\
         instruction transferChecked 0x0c01 (source) (amount: u64)\n\
         type accountState = enum {uninitialized, frozen(since: u64), initialized(_0: bool, _1: pubkey)}\n\
         type multisig = {m: u8, signers: [pubkey; 11], memo: string, history: Vec<@accountState>}\n"
    );
}

/// Codama encodes an instruction's data from its arguments alone and matches a
/// discriminator against those same bytes at an offset — a literal constant no
/// differently from a named field. Dispatch here reads a prefix and decodes the
/// body after it, so an argument the prefix covers is already spent: decoding it
/// again reads every later field one argument too early.
#[test]
fn a_constant_discriminator_spends_the_argument_it_covers() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "kind": "programNode",
          "instructions": [{
            "kind": "instructionNode",
            "name": "transferChecked",
            "arguments": [
              { "kind": "instructionArgumentNode", "name": "tag",
                "type": { "kind": "numberTypeNode", "format": "u8" },
                "defaultValue": { "kind": "numberValueNode", "number": 12 } },
              { "kind": "instructionArgumentNode", "name": "amount",
                "type": { "kind": "numberTypeNode", "format": "u64" } }
            ],
            "discriminators": [{
              "kind": "constantDiscriminatorNode", "offset": 0,
              "constant": { "kind": "constantValueNode",
                            "type": { "kind": "bytesTypeNode" },
                            "value": { "kind": "bytesValueNode", "data": "0c",
                                       "encoding": "base16" } }
            }]
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\ninstruction transferChecked 0x0c () (amount: u64)\n"
    );
}

/// A prefix that stops partway into an argument has no honest reading: the
/// runtime would start the body at that argument's second byte.
#[test]
fn demotes_a_discriminator_that_stops_inside_an_argument() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "kind": "programNode",
          "instructions": [{
            "kind": "instructionNode",
            "name": "transfer",
            "arguments": [
              { "kind": "instructionArgumentNode", "name": "amount",
                "type": { "kind": "numberTypeNode", "format": "u64" } }
            ],
            "discriminators": [{
              "kind": "constantDiscriminatorNode", "offset": 0,
              "constant": { "kind": "constantValueNode",
                            "type": { "kind": "bytesTypeNode" },
                            "value": { "kind": "bytesValueNode", "data": "0c",
                                       "encoding": "base16" } }
            }]
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         unusable instruction transfer: idl.json:3:28: the 1-byte discriminator stops inside argument \
         'amount', which starts at byte 0 and is 8 bytes wide\n"
    );
}

/// A size discriminator matches on the data's length, and dispatch here reads a
/// fixed-width prefix. Dropping it quietly leaves two instructions the IDL
/// distinguishes looking like a plain collision, so the reason names the reason.
#[test]
fn names_the_size_dispatch_it_cannot_honour() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "kind": "programNode",
          "instructions": [{
            "kind": "instructionNode", "name": "closeAccount", "arguments": [],
            "discriminators": [{ "kind": "sizeDiscriminatorNode", "size": 1 }]
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         unusable instruction closeAccount: idl.json:3:28: discriminators: dispatch matches a fixed-width \
         prefix of the data, not its length, so a sizeDiscriminatorNode cannot be honoured\n"
    );
}

/// A `program` on a type link names another program's type. Resolution here is
/// against this program's own registry, so a local type of the same name would
/// decode in its place — and with no local name at all the honest report is the
/// link, not "undefined type".
#[test]
fn rejects_a_type_link_into_another_program() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "kind": "programNode",
          "instructions": [{
            "kind": "instructionNode", "name": "mint", "arguments": [
              { "kind": "instructionArgumentNode", "name": "meta",
                "type": { "kind": "definedTypeLinkNode", "name": "tokenMetadata",
                          "program": { "kind": "programLinkNode", "name": "mplTokenMetadata" } } }
            ],
            "discriminators": [{
              "kind": "constantDiscriminatorNode", "offset": 0,
              "constant": { "kind": "constantValueNode",
                            "type": { "kind": "bytesTypeNode" },
                            "value": { "kind": "bytesValueNode", "data": "07",
                                       "encoding": "base16" } } }]
          }],
          "definedTypes": [{
            "kind": "definedTypeNode", "name": "tokenMetadata",
            "type": { "kind": "structTypeNode", "fields": [
              { "kind": "structFieldTypeNode", "name": "supply",
                "type": { "kind": "numberTypeNode", "format": "u64" } }] }
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         type tokenMetadata = {supply: u64}\n\
         unusable instruction mint: idl.json:3:28: args.meta: 'tokenMetadata' is defined by program \
         'mplTokenMetadata', and this parser resolves type links against the program it is \
         parsing, where the name means something else\n"
    );
}

/// A present-but-unreadable `discriminators` is a defect, not an absent list:
/// read as absent it leaves an empty prefix, and the instruction is then set
/// aside for a width problem the file does not have.
#[test]
fn rejects_a_discriminator_list_that_is_not_an_array() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "kind": "programNode",
          "instructions": [{
            "kind": "instructionNode", "name": "transfer", "arguments": [],
            "discriminators": {}
          }]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         unusable instruction transfer: idl.json:3:28: discriminators: expected an array, got {}\n"
    );
}

/// Shank IDLs (Metaplex's published format) share Anchor's top-level shape but
/// carry the real dispatch byte in `discriminant`. Hashing `global:<name>` for
/// one yields eight bytes the program never encodes, so codegen succeeds and
/// the indexer then matches nothing.
#[test]
fn reads_shank_discriminants_instead_of_hashing_the_name() {
    let idl = parse_idl(
        "idl.json",
        r#"{
          "version": "1.13.2",
          "name": "mpl_token_metadata",
          "metadata": {
            "origin": "shank",
            "address": "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
          },
          "instructions": [
            { "name": "createMetadataAccount",
              "accounts": [{ "name": "metadata", "isMut": true }],
              "args": [{ "name": "isMutable", "type": "bool" }],
              "discriminant": { "type": "u8", "value": 0 } },
            { "name": "burnNft",
              "accounts": [],
              "args": [],
              "discriminant": { "type": "u8", "value": 29 } },
            { "name": "undispatchable", "accounts": [], "args": [] }
          ]
        }"#,
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s\n\
         instruction burnNft 0x1d () ()\n\
         instruction createMetadataAccount 0x00 (metadata) (isMutable: bool)\n\
         unusable instruction undispatchable: idl.json:17:13: discriminant: this Shank IDL declares none, and \
         a hashed Anchor discriminator is not what a Shank program dispatches on\n"
    );
}

mod layout;
mod validate;
