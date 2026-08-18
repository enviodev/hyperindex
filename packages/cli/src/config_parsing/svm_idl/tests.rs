use std::fmt::Write;

use hypersync_client_solana::decode::{decode_top_level, EnumVariant, FieldType, NamedField};
use pretty_assertions::assert_eq;

use super::*;

/// One line per instruction, event and defined type, so a whole real-world
/// IDL fits in a reviewable snapshot while still asserting every parsed byte.
fn render(idl: &ProgramIdl) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "address: {}", idl.address.as_deref().unwrap_or("-"));
    for (name, ix) in &idl.instructions {
        let accounts = ix
            .accounts
            .iter()
            .map(|a| {
                let mut flags = String::new();
                if a.writable {
                    flags.push('w');
                }
                if a.signer {
                    flags.push('s');
                }
                if a.optional {
                    flags.push('?');
                }
                if flags.is_empty() {
                    a.name.clone()
                } else {
                    format!("{}:{flags}", a.name)
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
    for (name, event) in &idl.events {
        let _ = writeln!(
            out,
            "event {name} 0x{} ({})",
            crate::hex::encode(&event.discriminator),
            render_fields(&event.fields)
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

fn read_fixture(file_stem: &str) -> String {
    let path = format!(
        "{}/../../scenarios/svm_flow_xray/idls/{file_stem}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path}: {e}"))
}

fn parse_fixture(file_stem: &str) -> ProgramIdl {
    parse_idl(&read_fixture(file_stem), file_stem).expect("parse")
}

#[test]
fn parses_legacy_anchor_jupiter_idl() {
    insta::assert_snapshot!(render(&parse_fixture("jupiter")));
}

#[test]
fn parses_legacy_anchor_drift_idl() {
    insta::assert_snapshot!(render(&parse_fixture("drift")));
}

#[test]
fn parses_legacy_anchor_kamino_idl() {
    insta::assert_snapshot!(render(&parse_fixture("kamino")));
}

/// Legacy IDLs declare no address and no inline discriminators, so both are
/// derived: `sha256("global:<snake_case>")[..8]` for instructions and
/// `sha256("event:<Name>")[..8]` for events.
#[test]
fn derives_discriminators_for_legacy_anchor_idl() {
    let idl = parse_idl(
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
          "events": [{
            "name": "SwapEvent",
            "fields": [
              { "name": "amm", "type": "publicKey", "index": false },
              { "name": "inputAmount", "type": "u64", "index": false }
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
        "LegacyProgram",
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         instruction sharedAccountsRoute 0xc1209b3341d69c81 (tokenProgram, userTransferAuthority:ws, platformFeeAccount:w?) (id: u8, routePlan: Vec<@RoutePlanStep>, limitPrice: Option<u64>)\n\
         event SwapEvent 0x40c6cde8260871e2 (amm: pubkey, inputAmount: u64)\n\
         type RoutePlanStep = {percent: u8, swap: @Swap}\n\
         type Swap = enum {Saber, Serum(side: u8), Raydium(_0: u8, _1: u64)}\n"
    );
}

/// Anchor derives the pre-0.30 discriminator from `heck`'s snake_case, which
/// splits an acronym run. A hand-rolled converter that only breaks on
/// lower→upper collapses `CLMM` into one word and derives the wrong bytes for
/// every such instruction — silently, since the IDL still parses.
#[test]
fn splits_acronym_runs_like_anchor_does() {
    let idl = parse_idl(
        r#"{ "instructions": [{ "name": "raydiumCLMMSwap", "accounts": [], "args": [] }] }"#,
        "Router",
    )
    .expect("parse");
    assert_eq!(
        render(&idl),
        "address: -\ninstruction raydiumCLMMSwap 0x2fb8d5c123d25704 () ()\n"
    );
}

/// Anchor 0.30+ ships inline discriminators, `metadata.address`, the
/// `{"defined": {"name": T}}` type ref and the `writable`/`signer` flags; an
/// event's payload lives in `types` under the event's own name.
#[test]
fn parses_anchor_030_idl() {
    let idl = parse_idl(
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
        "MyProgram",
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: MyProgram1111111111111111111111111111111111\n\
         instruction initialize 0xafaf6d1f0d989bed (payer:ws, config:w, optionalAuthority:?, systemProgram) (seed: [u8; 32], authority: pubkey, config: @Config)\n\
         event Initialized 0x0102030405060708 (slot: u64, label: string)\n\
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
        "SplToken",
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\n\
         instruction initializeMint 0x00 (mint:w, rent:?) (decimals: u8, mintAuthority: pubkey, freezeAuthority: Option<pubkey>)\n\
         instruction syncNative 0x11 () ()\n\
         instruction transfer 0x03 (source:w, destination:w, authority:s) (amount: u64)\n\
         instruction transferChecked 0x0c01 (source:w) (amount: u64)\n\
         type accountState = enum {uninitialized, frozen(since: u64), initialized(_0: bool, _1: pubkey)}\n\
         type multisig = {m: u8, signers: [pubkey; 11], memo: string, history: Vec<@accountState>}\n"
    );
}

/// Shapes that parse as JSON but cannot be decoded, or cannot be dispatched.
/// Only a defect in the file itself is fatal; a defect in one instruction
/// costs that instruction. An undecodable event costs nothing at all, since
/// nothing consumes events.
#[test]
fn separates_file_level_defects_from_instruction_level_ones() {
    let cases: Vec<(&str, &str)> = vec![
        ("neither dialect", r#"{ "name": "mystery" }"#),
        (
            "duplicate instruction name",
            r#"{ "instructions": [{ "name": "swap" }, { "name": "swap" }] }"#,
        ),
        (
            // The one-byte tag Borsh uses; SPL's COption uses four.
            "anchor coption",
            r#"{ "instructions": [{
                 "name": "initializeMint",
                 "discriminator": [0],
                 "args": [{ "name": "freezeAuthority", "type": { "coption": "pubkey" } }]
               }] }"#,
        ),
        (
            "undefined type reference",
            r#"{ "instructions": [{
                 "name": "swap",
                 "discriminator": [1],
                 "args": [{ "name": "amount", "type": "u46" }]
               }] }"#,
        ),
        (
            "event with no payload type",
            r#"{ "instructions": [], "events": [{ "name": "Swapped", "discriminator": [1] }] }"#,
        ),
        (
            "discriminator wider than dispatch probes",
            r#"{ "instructions": [{ "name": "swap", "discriminator": [1, 2, 3] }] }"#,
        ),
        (
            "instruction with no discriminator at all",
            r#"{ "kind": "rootNode", "program": { "instructions": [{ "name": "swap" }] } }"#,
        ),
        (
            "one discriminator a prefix of another",
            r#"{ "kind": "rootNode", "program": { "instructions": [
                 { "name": "transfer", "discriminators": [{
                     "kind": "constantDiscriminatorNode", "offset": 0,
                     "constant": { "value": { "kind": "bytesValueNode", "data": "0c" } } }] },
                 { "name": "transferChecked", "discriminators": [{
                     "kind": "constantDiscriminatorNode", "offset": 0,
                     "constant": { "value": { "kind": "bytesValueNode", "data": "0c02" } } }] }
               ] } }"#,
        ),
        (
            // Behind another argument, so the bytes before it are the program's
            // data, not part of the prefix.
            "discriminator field not at offset 0",
            r#"{ "kind": "rootNode", "program": { "instructions": [{
                 "name": "swap",
                 "arguments": [
                   { "name": "amount", "type": { "kind": "numberTypeNode", "format": "u64" } },
                   { "name": "tag", "type": { "kind": "numberTypeNode", "format": "u8" },
                     "defaultValue": { "kind": "numberValueNode", "number": 3 } }
                 ],
                 "discriminators": [{ "kind": "fieldDiscriminatorNode", "name": "tag", "offset": 8 }]
               }] } }"#,
        ),
        (
            "discriminator value too wide for its format",
            r#"{ "kind": "rootNode", "program": { "instructions": [{
                 "name": "swap",
                 "arguments": [{ "name": "tag",
                   "type": { "kind": "numberTypeNode", "format": "u8" },
                   "defaultValue": { "kind": "numberValueNode", "number": 300 } }],
                 "discriminators": [{ "kind": "fieldDiscriminatorNode", "name": "tag", "offset": 0 }]
               }] } }"#,
        ),
        (
            // Setting an instruction aside does not remove it from the chain.
            // `transferChecked` still occurs and still carries 0x0c02, so a
            // surviving `transfer` on 0x0c would collect its calls and decode
            // them against the wrong layout.
            "instruction shadowed by one set aside for its args",
            r#"{ "instructions": [
                 { "name": "transfer", "discriminator": [12],
                   "args": [{ "name": "amount", "type": "u64" }] },
                 { "name": "transferChecked", "discriminator": [12, 2],
                   "args": [{ "name": "amount", "type": { "coption": "u64" } }] }] }"#,
        ),
        (
            // `raw`'s data opens with its `amount` argument, so a call to it
            // whose amount happens to be 3 is indistinguishable on the wire
            // from a call to `swap`.
            "instruction declaring no discriminator at all",
            r#"{ "kind": "rootNode", "program": { "instructions": [
                 { "kind": "instructionNode", "name": "raw",
                   "arguments": [{ "kind": "instructionArgumentNode", "name": "amount",
                     "type": { "kind": "numberTypeNode", "format": "u8" } }] },
                 { "kind": "instructionNode", "name": "swap",
                   "arguments": [{ "kind": "instructionArgumentNode", "name": "tag",
                     "type": { "kind": "numberTypeNode", "format": "u8" },
                     "defaultValue": { "kind": "numberValueNode", "number": 3 } }],
                   "discriminators": [{ "kind": "fieldDiscriminatorNode",
                                        "name": "tag", "offset": 0 }] }] } }"#,
        ),
        (
            // Sorting puts a prefix before everything it prefixes, but only
            // immediately before the first of them.
            "one discriminator a prefix of several others",
            r#"{ "instructions": [
                 { "name": "transfer", "discriminator": [12], "args": [] },
                 { "name": "transferChecked", "discriminator": [12, 2], "args": [] },
                 { "name": "transferAll", "discriminator": [12, 3], "args": [] }] }"#,
        ),
        (
            // Nothing routes *to* a 3-byte discriminator, but `swap` holding
            // its first two bytes still collects its calls.
            "instruction shadowed by one of an undispatchable width",
            r#"{ "instructions": [
                 { "name": "swap", "discriminator": [1, 2], "args": [] },
                 { "name": "swapV2", "discriminator": [1, 2, 3], "args": [] }] }"#,
        ),
        (
            // The discriminator claims offset 0 for an argument declared
            // second, so the offsets and the declaration disagree about where
            // the body starts.
            "codama discriminator argument out of declaration order",
            r#"{ "kind": "rootNode", "program": { "instructions": [{
                 "kind": "instructionNode", "name": "swap",
                 "arguments": [
                   { "kind": "instructionArgumentNode", "name": "amount",
                     "type": { "kind": "numberTypeNode", "format": "u64" } },
                   { "kind": "instructionArgumentNode", "name": "tag",
                     "type": { "kind": "numberTypeNode", "format": "u8" },
                     "defaultValue": { "kind": "numberValueNode", "number": 3 } }],
                 "discriminators": [{ "kind": "fieldDiscriminatorNode",
                                      "name": "tag", "offset": 0 }] }] } }"#,
        ),
        (
            // Nothing consumes events, so one that cannot be decoded costs
            // nothing.
            "undecodable event payload",
            r#"{ "instructions": [{ "name": "swap", "discriminator": [1], "args": [] }],
                 "events": [{ "name": "Swapped", "discriminator": [2],
                   "fields": [{ "name": "a", "type": { "coption": "u64" } }] }] }"#,
        ),
        (
            // Ambiguous for whatever reaches it, harmless for everything else.
            "duplicate type name",
            r#"{ "instructions": [{ "name": "swap", "discriminator": [1],
                 "args": [{ "name": "fee", "type": { "defined": "Fee" } }] }],
                 "types": [
                   { "name": "Fee", "type": { "kind": "struct",
                     "fields": [{ "name": "bps", "type": "u16" }] } },
                   { "name": "Fee", "type": { "kind": "struct",
                     "fields": [{ "name": "bps", "type": "u32" }] } }] }"#,
        ),
    ];

    let reported: Vec<String> = cases
        .iter()
        .map(|(label, json)| {
            let outcome = match parse_idl(json, "Program") {
                Err(e) => format!(
                    "fatal: {}",
                    format!("{e:#}")
                        .strip_prefix("parsing IDL for program 'Program': ")
                        .expect("every message is scoped to the program")
                ),
                Ok(idl) if !idl.unusable.is_empty() => idl
                    .unusable
                    .iter()
                    .map(|(name, reason)| format!("{name} set aside: {reason}"))
                    .collect::<Vec<_>>()
                    .join("; "),
                Ok(_) => "accepted".to_string(),
            };
            format!("{label}: {outcome}")
        })
        .collect();

    assert_eq!(
        reported,
        vec![
            "neither dialect: fatal: unrecognized IDL: expected an Anchor IDL (top-level 'instructions') or a Codama IDL (a 'rootNode')",
            "duplicate instruction name: fatal: IDL declares instruction 'swap' more than once",
            "anchor coption: initializeMint set aside: args.freezeAuthority: `coption` is not Borsh-compatible and cannot be decoded",
            "undefined type reference: swap set aside: it references undefined type 'u46'",
            "event with no payload type: accepted",
            "discriminator wider than dispatch probes: swap set aside: its 3-byte discriminator is not one of the widths dispatch probes ([1, 2, 4, 8])",
            "instruction with no discriminator at all: swap set aside: its 0-byte discriminator is not one of the widths dispatch probes ([1, 2, 4, 8])",
            "one discriminator a prefix of another: transfer set aside: its discriminator 0x0c is a prefix of 'transferChecked''s 0x0c02, so 'transferChecked' takes every call that would have matched it; transferChecked set aside: its discriminator 0x0c02 extends 'transfer''s 0x0c, so a 'transfer' call whose data continues those bytes arrives here instead",
            "discriminator field not at offset 0: swap set aside: discriminators: discriminator part at offset 8 does not follow the previous part, which ends at 0; dispatch needs one contiguous prefix from offset 0",
            "discriminator value too wide for its format: swap set aside: discriminators: discriminator value 300 does not fit in u8",
            "instruction shadowed by one set aside for its args: transfer set aside: its discriminator 0x0c is a prefix of 'transferChecked''s 0x0c02, so 'transferChecked' takes every call that would have matched it; transferChecked set aside: args.amount: `coption` is not Borsh-compatible and cannot be decoded",
            "instruction declaring no discriminator at all: raw set aside: its 0-byte discriminator is not one of the widths dispatch probes ([1, 2, 4, 8]); swap set aside: 'raw' declares no discriminator, so its calls carry argument bytes where a discriminator would be and can match any this program declares",
            "one discriminator a prefix of several others: transfer set aside: its discriminator 0x0c is a prefix of 'transferChecked''s 0x0c02, so 'transferChecked' takes every call that would have matched it; transferAll set aside: its discriminator 0x0c03 extends 'transfer''s 0x0c, so a 'transfer' call whose data continues those bytes arrives here instead; transferChecked set aside: its discriminator 0x0c02 extends 'transfer''s 0x0c, so a 'transfer' call whose data continues those bytes arrives here instead",
            "instruction shadowed by one of an undispatchable width: swap set aside: its discriminator 0x0102 is a prefix of 'swapV2''s 0x010203, so 'swapV2' takes every call that would have matched it; swapV2 set aside: its 3-byte discriminator is not one of the widths dispatch probes ([1, 2, 4, 8])",
            "codama discriminator argument out of declaration order: swap set aside: the discriminator reads [\"tag\"], but the arguments begin [\"amount\"]; their offsets and their declaration order disagree",
            "undecodable event payload: accepted",
            "duplicate type name: swap set aside: it reaches type 'Fee', which cannot be decoded: the IDL declares type 'Fee' more than once",
        ]
    );
}

/// Deterministic mutation fuzzing over the real fixtures. `parse_idl` takes
/// untrusted JSON, so no input may panic — every rejection has to arrive as an
/// `Err`. A seeded walk keeps a failure reproducible from the printed seed.
///
/// This covers panics, not semantics. For semantics the gap that remains is a
/// Borsh round trip: encode a value against a parsed layout, decode it back,
/// and assert equality. That would have caught the option-tag and size-prefix
/// bugs by construction rather than by review, and it wants an encoder the
/// runtime does not currently expose — worth adding when one exists. A
/// `cargo-fuzz` target over `parse_idl` is the other natural extension, for
/// continuous coverage rather than a fixed seed per run.
#[test]
fn mutated_fixtures_never_panic() {
    // xorshift64*, so the sequence is fixed across platforms and runs.
    fn next(state: &mut u64) -> u64 {
        *state ^= *state >> 12;
        *state ^= *state << 25;
        *state ^= *state >> 27;
        state.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Replace the `target`-th node of `value` in traversal order with
    /// something of a different shape.
    fn mutate(value: &mut Value, target: &mut i64, replacement: u64) {
        if *target < 0 {
            return;
        }
        if *target == 0 {
            *value = match replacement % 6 {
                0 => Value::Null,
                1 => Value::Bool(true),
                2 => Value::from(replacement),
                3 => Value::from(-1i64),
                4 => Value::String("\u{1F600}".into()),
                _ => Value::Array(vec![]),
            };
            *target = -1;
            return;
        }
        *target -= 1;
        match value {
            Value::Object(map) => map
                .values_mut()
                .for_each(|child| mutate(child, target, replacement)),
            Value::Array(items) => items
                .iter_mut()
                .for_each(|child| mutate(child, target, replacement)),
            _ => {}
        }
    }

    let mut state = 0x005E_ED1D_u64;
    for stem in ["jupiter", "kamino"] {
        let original: Value = serde_json::from_str(&read_fixture(stem)).expect("fixture is JSON");
        for _ in 0..150 {
            let seed = state;
            let replacement = next(&mut state);
            let mut mutated = original.clone();
            let mut target = (next(&mut state) % 4000) as i64;
            mutate(&mut mutated, &mut target, replacement);
            let json = mutated.to_string();
            // `parse_idl` must decide, not panic. A panic here fails the test
            // with the seed in the message so it can be replayed.
            let outcome = std::panic::catch_unwind(|| parse_idl(&json, "Fuzzed").is_ok());
            assert!(
                outcome.is_ok(),
                "parse_idl panicked on a mutation of {stem}.json (seed 0x{seed:x})"
            );
        }
    }
}

/// A Codama IDL with one instruction whose only argument has the given type:
/// the smallest shape that puts a type node in front of the parser on the path
/// a config actually takes.
fn codama_type(type_node: &str) -> String {
    format!(
        r#"{{ "kind": "rootNode", "program": {{ "instructions": [{{
             "kind": "instructionNode", "name": "probe",
             "discriminators": [{{ "kind": "constantDiscriminatorNode", "offset": 0,
               "constant": {{ "value": {{ "kind": "bytesValueNode", "data": "01",
                                          "encoding": "base16" }} }} }}],
             "arguments": [{{ "kind": "instructionArgumentNode", "name": "probed",
                              "type": {type_node} }}] }}] }} }}"#
    )
}

/// Layout modifiers the Borsh runtime cannot honour. Each of these once parsed
/// clean and decoded at the wrong offset, which is worse than a rejected IDL:
/// the indexer reports values that are plausible and wrong. A node is refused
/// unless every key on it is modelled, so a Codama feature this parser has not
/// learned yet arrives as a codegen error rather than as corrupt data.
#[test]
fn refuses_layouts_the_runtime_would_misdecode() {
    let cases: Vec<(&str, String)> = vec![
        (
            // Always occupies prefix + item bytes, zero-padded when absent.
            "codama fixed option",
            codama_type(
                r#"{ "kind": "optionTypeNode", "fixed": true,
                     "item": { "kind": "publicKeyTypeNode" } }"#,
            ),
        ),
        (
            "codama enum with a wide tag",
            codama_type(
                r#"{ "kind": "enumTypeNode",
                     "size": { "kind": "numberTypeNode", "format": "u32" },
                     "variants": [{ "kind": "enumEmptyVariantTypeNode", "name": "Init" }] }"#,
            ),
        ),
        (
            "codama big-endian number",
            codama_type(r#"{ "kind": "numberTypeNode", "format": "u32", "endian": "be" }"#),
        ),
        (
            "codama bare string",
            codama_type(r#"{ "kind": "stringTypeNode", "encoding": "utf8" }"#),
        ),
        (
            "codama bare bytes",
            codama_type(r#"{ "kind": "bytesTypeNode" }"#),
        ),
        (
            "codama non-utf8 string",
            codama_type(
                r#"{ "kind": "sizePrefixTypeNode",
                     "prefix": { "kind": "numberTypeNode", "format": "u32" },
                     "type": { "kind": "stringTypeNode", "encoding": "base58" } }"#,
            ),
        ),
        (
            "codama boolean wider than a byte",
            codama_type(
                r#"{ "kind": "booleanTypeNode",
                     "size": { "kind": "numberTypeNode", "format": "u32" } }"#,
            ),
        ),
        (
            // Borsh numbers variants by position; an explicit one renumbers them.
            "codama enum variant with its own discriminator",
            codama_type(
                r#"{ "kind": "enumTypeNode", "variants": [
                     { "kind": "enumEmptyVariantTypeNode", "name": "Init", "discriminator": 3 }] }"#,
            ),
        ),
        (
            "codama size prefix around a struct",
            codama_type(
                r#"{ "kind": "sizePrefixTypeNode",
                     "prefix": { "kind": "numberTypeNode", "format": "u32" },
                     "type": { "kind": "structTypeNode", "fields": [] } }"#,
            ),
        ),
        (
            // The length itself is framing: read big-endian, it shifts every
            // byte after it.
            "codama big-endian length prefix",
            codama_type(
                r#"{ "kind": "arrayTypeNode",
                     "item": { "kind": "numberTypeNode", "format": "u8" },
                     "count": { "kind": "prefixedCountNode",
                                "prefix": { "kind": "numberTypeNode", "format": "u32",
                                            "endian": "be" } } }"#,
            ),
        ),
        (
            // Codama types a tuple variant's body as a nested node, so the
            // wrapper needs the same checks as any other type.
            "codama enum tuple variant behind a wrapper",
            codama_type(
                r#"{ "kind": "enumTypeNode", "variants": [
                     { "kind": "enumTupleVariantTypeNode", "name": "Wrapped",
                       "tuple": { "kind": "sizePrefixTypeNode",
                                  "prefix": { "kind": "numberTypeNode", "format": "u32" },
                                  "items": [{ "kind": "numberTypeNode", "format": "u8" }] } }] }"#,
            ),
        ),
        (
            // SPL Token's real `freezeAuthority`: presence is a zero check, not
            // a tag byte, so there is no byte for the runtime to consume.
            "codama zeroable option",
            codama_type(
                r#"{ "kind": "zeroableOptionTypeNode",
                     "item": { "kind": "publicKeyTypeNode" } }"#,
            ),
        ),
        (
            "codama option with a wide tag",
            codama_type(
                r#"{ "kind": "optionTypeNode",
                     "prefix": { "kind": "numberTypeNode", "format": "u32" },
                     "item": { "kind": "publicKeyTypeNode" } }"#,
            ),
        ),
        (
            "codama vector with a narrow length prefix",
            codama_type(
                r#"{ "kind": "arrayTypeNode",
                     "item": { "kind": "publicKeyTypeNode" },
                     "count": { "kind": "prefixedCountNode",
                                "prefix": { "kind": "numberTypeNode", "format": "u8" } } }"#,
            ),
        ),
        (
            "codama string with a narrow size prefix",
            codama_type(
                r#"{ "kind": "sizePrefixTypeNode",
                     "prefix": { "kind": "numberTypeNode", "format": "u8" },
                     "type": { "kind": "stringTypeNode", "encoding": "utf8" } }"#,
            ),
        ),
        (
            // Bound at the use site, so it has no layout of its own.
            "anchor generic parameter",
            r#"{ "instructions": [{ "name": "swap", "discriminator": [1],
                 "args": [{ "name": "wrapped", "type": { "generic": "T" } }] }] }"#
                .to_string(),
        ),
    ];

    let reported: Vec<String> = cases
        .iter()
        .map(|(label, json)| {
            let idl = parse_idl(json, "Program").unwrap_or_else(|e| {
                panic!("{label} should set the instruction aside, not fail the file: {e:#}")
            });
            let (name, reason) = idl
                .unusable
                .iter()
                .next()
                .unwrap_or_else(|| panic!("{label} left every instruction usable"));
            format!("{label}: {name}: {reason}")
        })
        .collect();

    assert_eq!(
        reported,
        vec![
            "codama fixed option: probe: args.probed: a fixed option pads its body when absent, which Borsh does not encode",
            "codama enum with a wide tag: probe: args.probed.size: Borsh needs u8 here, got u32",
            "codama big-endian number: probe: args.probed: Borsh decodes numbers little-endian, got 'be'",
            "codama bare string: probe: args.probed: a bare stringTypeNode carries no length; Borsh needs it wrapped in a sizePrefixTypeNode with a u32 prefix",
            "codama bare bytes: probe: args.probed: a bare bytesTypeNode carries no length; Borsh needs it wrapped in a sizePrefixTypeNode with a u32 prefix",
            "codama non-utf8 string: probe: args.probed: Borsh strings are utf8, got 'base58'",
            "codama boolean wider than a byte: probe: args.probed.size: Borsh needs u8 here, got u32",
            "codama enum variant with its own discriminator: probe: args.probed.Init: enumEmptyVariantTypeNode carries 'discriminator', which this parser does not model; decoding it would be a guess at the byte layout",
            "codama size prefix around a struct: probe: args.probed: a u32 size prefix frames a string or bytes in Borsh, got structTypeNode",
            "codama big-endian length prefix: probe: args.probed.prefix: Borsh decodes numbers little-endian, got 'be'",
            "codama enum tuple variant behind a wrapper: probe: args.probed.Wrapped: sizePrefixTypeNode carries 'items', which this parser does not model; decoding it would be a guess at the byte layout",
            "codama zeroable option: probe: args.probed: zeroable options are not Borsh-compatible and cannot be decoded",
            "codama option with a wide tag: probe: args.probed.prefix: Borsh needs u8 here, got u32",
            "codama vector with a narrow length prefix: probe: args.probed.prefix: Borsh needs u32 here, got u8",
            "codama string with a narrow size prefix: probe: args.probed.prefix: Borsh needs u32 here, got u8",
            "anchor generic parameter: swap: args.wrapped: generic parameter 'T' has no concrete layout to decode against",
        ]
    );
}

/// The other half of deny-by-default: a node that carries something the
/// parser doesn't read, but which cannot move a byte, has to keep parsing.
/// Rejecting these would fail real IDLs for decoration — `display` annotates
/// a `u64` as a token amount, and Codama drops `fields`/`items`/`variants`
/// entirely rather than writing an empty array.
#[test]
fn accepts_codama_nodes_that_cannot_change_the_layout() {
    let cases: Vec<(&str, String)> = vec![
        (
            "number with a display annotation",
            codama_type(
                r#"{ "kind": "numberTypeNode", "format": "u64", "endian": "le",
                     "display": { "kind": "amountNumberDisplayNode", "decimals": 9,
                                  "unit": "SOL" } }"#,
            ),
        ),
        (
            "string with a display annotation",
            codama_type(
                r#"{ "kind": "sizePrefixTypeNode",
                     "prefix": { "kind": "numberTypeNode", "format": "u32" },
                     "type": { "kind": "stringTypeNode", "encoding": "utf8",
                               "display": { "kind": "stringDisplayNode" } } }"#,
            ),
        ),
        (
            "struct with no fields",
            codama_type(r#"{ "kind": "structTypeNode" }"#),
        ),
        (
            "tuple with no items",
            codama_type(r#"{ "kind": "tupleTypeNode" }"#),
        ),
        (
            "enum with no variants",
            codama_type(r#"{ "kind": "enumTypeNode" }"#),
        ),
        (
            "documented node",
            codama_type(r#"{ "kind": "booleanTypeNode", "docs": ["whether the mint is frozen"] }"#),
        ),
    ];

    let parsed: Vec<(&str, String)> = cases
        .iter()
        .map(|(label, json)| {
            let idl = parse_idl(json, "Program").unwrap_or_else(|e| panic!("{label}: {e:#}"));
            let ty = match idl.instructions.get("probe") {
                Some(ix) => render_type(&ix.args[0].ty),
                None => format!("SET ASIDE: {}", idl.unusable["probe"]),
            };
            (*label, ty)
        })
        .collect();

    assert_eq!(
        parsed,
        vec![
            ("number with a display annotation", "u64".to_string()),
            ("string with a display annotation", "string".to_string()),
            ("struct with no fields", "{}".to_string()),
            ("tuple with no items", "{}".to_string()),
            ("enum with no variants", "enum {}".to_string()),
            ("documented node", "bool".to_string()),
        ]
    );
}

/// The parser and the Borsh runtime have to agree byte for byte, and neither
/// side's own tests can show that: each is self-consistent about a layout they
/// disagree on. This runs real instruction data through the schema the parser
/// produced, so a mapping that drifts from the decoder fails here.
#[test]
fn decodes_instruction_data_through_the_parsed_schema() {
    let idl = parse_idl(
        r#"{
          "kind": "rootNode",
          "program": {
            "kind": "programNode",
            "publicKey": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
            "instructions": [{
              "kind": "instructionNode",
              "name": "probe",
              "discriminators": [{
                "kind": "constantDiscriminatorNode",
                "offset": 0,
                "constant": { "value": {
                  "kind": "bytesValueNode", "data": "01", "encoding": "base16" } }
              }],
              "arguments": [
                { "kind": "instructionArgumentNode", "name": "amount",
                  "type": { "kind": "numberTypeNode", "format": "u64", "endian": "le" } },
                { "kind": "instructionArgumentNode", "name": "flag",
                  "type": { "kind": "booleanTypeNode" } },
                { "kind": "instructionArgumentNode", "name": "label",
                  "type": { "kind": "sizePrefixTypeNode",
                            "prefix": { "kind": "numberTypeNode", "format": "u32" },
                            "type": { "kind": "stringTypeNode", "encoding": "utf8" } } },
                { "kind": "instructionArgumentNode", "name": "maybe",
                  "type": { "kind": "optionTypeNode",
                            "item": { "kind": "numberTypeNode", "format": "u8" } } },
                { "kind": "instructionArgumentNode", "name": "items",
                  "type": { "kind": "arrayTypeNode",
                            "item": { "kind": "numberTypeNode", "format": "u8" },
                            "count": { "kind": "prefixedCountNode",
                                       "prefix": { "kind": "numberTypeNode",
                                                   "format": "u32" } } } },
                { "kind": "instructionArgumentNode", "name": "trio",
                  "type": { "kind": "arrayTypeNode",
                            "item": { "kind": "numberTypeNode", "format": "u8" },
                            "count": { "kind": "fixedCountNode", "value": 3 } } }
              ]
            }],
            "definedTypes": []
          }
        }"#,
        "Probe",
    )
    .expect("parse");

    // Borsh, little-endian, in declared order. Written out by hand so the
    // expectation comes from the wire format rather than from the parser.
    let data: Vec<u8> = vec![
        1, 0, 0, 0, 0, 0, 0, 0, // amount: u64 = 1
        1, // flag: true
        2, 0, 0, 0, b'h', b'i', // label: u32 len 2 + "hi"
        1, 7, // maybe: tag 1 + 7
        2, 0, 0, 0, 1, 2, // items: u32 len 2 + [1, 2]
        9, 8, 7, // trio: [9, 8, 7], no length
    ];

    let decoded = decode_top_level(
        &FieldType::Struct(idl.instructions["probe"].args.clone()),
        &idl.defined_types,
        &data,
    )
    .expect("decode");

    assert_eq!(
        decoded,
        serde_json::json!({
            "amount": "1",
            "flag": true,
            "label": "hi",
            "maybe": 7,
            "items": [1, 2],
            "trio": [9, 8, 7],
        })
    );
}

/// The CLI fixture and the `envio init` template ship the same IDL, and
/// nothing else keeps them in step. A fixture that drifts is a fixture for a
/// project nobody generates.
#[test]
fn template_and_fixture_idls_match() {
    let root = env!("CARGO_MANIFEST_DIR");
    let template = std::fs::read_to_string(format!(
        "{root}/templates/static/svm_metaplex_template/typescript/idls/token-metadata.codama.json"
    ))
    .expect("template IDL");
    let fixture = std::fs::read_to_string(format!("{root}/test/idls/token-metadata.codama.json"))
        .expect("fixture IDL");
    assert_eq!(template, fixture);
}

/// Real, unmodified Codama IDLs, straight from the upstream program repos.
/// Both declare a shape Borsh has no room for — SPL Token's
/// `uiAmountToAmount` takes a remainder-encoded string, and Memo's entire
/// payload is one — so they pin the rule that costs an instruction only
/// itself: 26 of SPL Token's 28 stay indexable.
#[test]
fn parses_real_codama_spl_token_idl() {
    insta::assert_snapshot!(render(&parse_fixture("spl-token.codama")));
}

#[test]
fn parses_real_codama_memo_idl() {
    insta::assert_snapshot!(render(&parse_fixture("memo.codama")));
}

/// Types that share subtrees are ordinary — a struct referenced from two
/// fields, thirty levels down. Resolving nominal references per occurrence
/// doubles the work at every level, which reads as a hang rather than as a
/// wrong answer, so this pins that the cost stays flat.
#[test]
fn resolves_shared_type_graphs_without_blowing_up() {
    let depth = 40;
    let mut types = vec![r#"{ "name": "T0", "type": { "kind": "struct",
             "fields": [{ "name": "x", "type": "u8" }] } }"#
        .to_string()];
    for i in 1..depth {
        types.push(format!(
            r#"{{ "name": "T{i}", "type": {{ "kind": "struct", "fields": [
                 {{ "name": "a", "type": {{ "defined": "T{prev}" }} }},
                 {{ "name": "b", "type": {{ "defined": "T{prev}" }} }}] }} }}"#,
            prev = i - 1
        ));
    }
    let json = format!(
        r#"{{ "instructions": [{{ "name": "swap", "discriminator": [1],
             "args": [{{ "name": "deep", "type": {{ "defined": "T{}" }} }}] }}],
             "types": [{}] }}"#,
        depth - 1,
        types.join(",")
    );

    let idl = parse_idl(&json, "Deep").expect("parse");
    assert_eq!(idl.instructions.keys().collect::<Vec<_>>(), vec!["swap"]);
}

/// Codegen hands `defined_types` to the runtime's type registry whole, so a
/// type that cannot be resolved must not travel with it — even when nothing
/// reaches it and the file is otherwise fine.
#[test]
fn prunes_types_it_cannot_resolve_from_the_registry() {
    let idl = parse_idl(
        r#"{ "instructions": [{ "name": "swap", "discriminator": [1],
             "args": [{ "name": "fee", "type": { "defined": "Fee" } }] }],
             "types": [
               { "name": "Fee", "type": { "kind": "struct",
                 "fields": [{ "name": "bps", "type": "u16" }] } },
               { "name": "Orphan", "type": { "kind": "struct",
                 "fields": [{ "name": "x", "type": { "defined": "Missing" } }] } }] }"#,
        "Program",
    )
    .expect("parse");

    assert_eq!(
        (
            idl.instructions
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            idl.defined_types
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            idl.unusable_types
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
        ),
        (vec!["swap"], vec!["Fee"], vec!["Orphan"])
    );
}

/// A type that reaches itself is ordinary — a linked list, a tree node — and
/// decodable, since the `Option` terminates it. Condemning one would take
/// every instruction that touches it out of reach.
#[test]
fn resolves_self_referential_types() {
    let idl = parse_idl(
        r#"{ "instructions": [{ "name": "walk", "discriminator": [1],
             "args": [{ "name": "head", "type": { "defined": "Node" } }] }],
             "types": [
               { "name": "Node", "type": { "kind": "struct", "fields": [
                 { "name": "value", "type": "u64" },
                 { "name": "next", "type": { "option": { "defined": "Node" } } },
                 { "name": "peer", "type": { "option": { "defined": "Other" } } }] } },
               { "name": "Other", "type": { "kind": "struct", "fields": [
                 { "name": "back", "type": { "option": { "defined": "Node" } } }] } }] }"#,
        "Program",
    )
    .expect("parse");

    assert_eq!(
        (
            idl.instructions
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            idl.unusable.keys().map(String::as_str).collect::<Vec<_>>(),
            idl.unusable_types
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
        ),
        (vec!["walk"], Vec::new(), Vec::new())
    );
}
