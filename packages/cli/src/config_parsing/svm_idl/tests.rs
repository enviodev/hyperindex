use std::fmt::Write;

use hypersync_client_solana::decode::{EnumVariant, FieldType, NamedField};
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
            hex(&ix.discriminator),
            render_fields(&ix.args)
        );
    }
    for (name, event) in &idl.events {
        let _ = writeln!(
            out,
            "event {name} 0x{} ({})",
            hex(&event.discriminator),
            render_fields(&event.fields)
        );
    }
    for (name, ty) in &idl.defined_types {
        let _ = writeln!(out, "type {name} = {}", render_type(ty));
    }
    out
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
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

fn parse_fixture(file_stem: &str) -> ProgramIdl {
    let path = format!(
        "{}/../../scenarios/svm_flow_xray/idls/{file_stem}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let json = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path}: {e}"));
    parse_idl(&json, &program_name_from_filename(file_stem)).expect("parse")
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

/// SPL Token is the case Anchor cannot express and the reason Codama is in
/// the spec: a 1-byte discriminator carried by a regular argument, a packed
/// two-field discriminator, and a COption account slot.
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
                    "type": { "kind": "zeroableOptionTypeNode", "item": { "kind": "publicKeyTypeNode" } }
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
                    "type": { "kind": "numberTypeNode", "format": "u16", "endian": "le" },
                    "defaultValue": { "kind": "numberValueNode", "number": 258 },
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
         instruction transferChecked 0x0c0201 (source:w) (amount: u64)\n\
         type accountState = enum {uninitialized, frozen(since: u64), initialized(_0: bool, _1: pubkey)}\n\
         type multisig = {m: u8, signers: [pubkey; 11], memo: string, history: Vec<@accountState>}\n"
    );
}

#[test]
fn rejects_an_idl_of_neither_dialect() {
    let error = parse_idl(r#"{ "name": "mystery" }"#, "Mystery").unwrap_err();
    assert_eq!(
        format!("{error:#}"),
        "parsing IDL for program 'Mystery': unrecognized IDL: expected an Anchor IDL (top-level \
         'instructions') or a Codama IDL (a 'rootNode')"
    );
}

#[test]
fn rejects_duplicate_instruction_names() {
    let error = parse_idl(
        r#"{ "instructions": [{ "name": "swap", "args": [] }, { "name": "swap", "args": [] }] }"#,
        "Dup",
    )
    .unwrap_err();
    assert_eq!(
        format!("{error:#}"),
        "parsing IDL for program 'Dup': IDL declares instruction 'swap' more than once"
    );
}

/// Only a u32 size prefix matches how the Borsh runtime frames a string, so a
/// narrower one is rejected rather than decoded at the wrong offset.
#[test]
fn rejects_a_codama_size_prefix_the_runtime_cannot_decode() {
    let error = parse_idl(
        r#"{
          "kind": "rootNode",
          "program": {
            "instructions": [],
            "definedTypes": [{
              "name": "label",
              "type": {
                "kind": "sizePrefixTypeNode",
                "type": { "kind": "stringTypeNode", "encoding": "utf8" },
                "prefix": { "kind": "numberTypeNode", "format": "u8" }
              }
            }]
          }
        }"#,
        "Labelled",
    )
    .unwrap_err();
    assert_eq!(
        format!("{error:#}"),
        "parsing IDL for program 'Labelled': definedTypes.label: size prefix must be u32, got \
         Some(\"u8\")"
    );
}

#[test]
fn derives_program_names_from_filenames() {
    let derived: Vec<String> = ["pump_fun", "pumpfun", "jupiter-v6", "spl.token", "drift"]
        .iter()
        .map(|stem| program_name_from_filename(stem))
        .collect();
    assert_eq!(
        derived,
        vec!["PumpFun", "Pumpfun", "JupiterV6", "SplToken", "Drift"]
    );
}
