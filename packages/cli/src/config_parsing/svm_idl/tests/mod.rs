use std::fmt::Write;

use hypersync_client_solana::decode::{EnumVariant, FieldType, NamedField};
use pretty_assertions::assert_eq;

use super::*;

pub(super) fn render(idl: &ProgramIdl) -> String {
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

pub(super) fn render_fields(fields: &[NamedField]) -> String {
    fields
        .iter()
        .map(|f| format!("{}: {}", f.name, render_type(&f.ty)))
        .collect::<Vec<_>>()
        .join(", ")
}

pub(super) fn render_type(ty: &FieldType) -> String {
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
pub(super) fn read_fixture(path: &str) -> String {
    let path = format!("{}/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path}: {e}"))
}

/// The published SPL Token and SPL Memo IDLs, unmodified. Both declare
/// instructions Borsh cannot express, and the point of the pair is that one
/// such instruction costs only itself: SPL Token keeps the other 26, while
/// Memo — whose whole payload is a remainder-encoded string — has nothing left
/// and would fail the program at the layer above.
#[test]
fn parses_the_published_spl_idls() {
    let catalog = |file: &str| {
        let idl = parse_idl(&read_fixture(&format!("test/idls/{file}")), "Spl").expect("parse");
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
                        "args.data.item.instructionData.prefix: Borsh needs u32 here, got u8"
                            .to_string()
                    ),
                    (
                        "uiAmountToAmount".to_string(),
                        "args.uiAmount: a bare stringTypeNode carries no length; Borsh needs it \
                         wrapped in a sizePrefixTypeNode with a u32 prefix"
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
                    "args.memo: a bare stringTypeNode carries no length; Borsh needs it wrapped \
                     in a sizePrefixTypeNode with a u32 prefix"
                        .to_string()
                )]),
            ),
        ]
    );
}

#[test]
fn parses_a_codama_program_node_without_root_wrapper() {
    let idl = parse_idl(
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
        "SplToken",
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\n\
         instruction transfer 0x03 (source, destination) (amount: u64)\n"
    );
}

#[test]
fn trailing_optional_mask_keeps_middle_slots_required() {
    let account = |name: &str, optional| IdlAccount {
        name: name.to_string(),
        optional,
    };
    assert_eq!(
        [
            trailing_optional_mask(&[
                account("metadata", false),
                account("mint", true),
                account("payer", false),
                account("rent", true),
            ]),
            trailing_optional_mask(&[account("a", true), account("b", true)]),
            trailing_optional_mask(&[account("a", false), account("b", true), account("c", true)]),
            trailing_optional_mask(&[]),
        ],
        [
            vec![false, false, false, true],
            vec![true, true],
            vec![false, true, true],
            vec![],
        ]
    );
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
        r#"{ "instructions": [{ "name": "raydiumCLMMSwap", "accounts": [], "args": [] }] }"#,
        "Router",
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
         instruction initialize 0xafaf6d1f0d989bed (payer, config, optionalAuthority:?, systemProgram) (seed: [u8; 32], authority: pubkey, config: @Config)\n\
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
         instruction initializeMint 0x00 (mint, rent:?) (decimals: u8, mintAuthority: pubkey, freezeAuthority: Option<pubkey>)\n\
         instruction syncNative 0x11 () ()\n\
         instruction transfer 0x03 (source, destination, authority) (amount: u64)\n\
         instruction transferChecked 0x0c01 (source) (amount: u64)\n\
         type accountState = enum {uninitialized, frozen(since: u64), initialized(_0: bool, _1: pubkey)}\n\
         type multisig = {m: u8, signers: [pubkey; 11], memo: string, history: Vec<@accountState>}\n"
    );
}

/// Shank IDLs (Metaplex's published format) share Anchor's top-level shape but
/// carry the real dispatch byte in `discriminant`. Hashing `global:<name>` for
/// one yields eight bytes the program never encodes, so codegen succeeds and
/// the indexer then matches nothing.
#[test]
fn reads_shank_discriminants_instead_of_hashing_the_name() {
    let idl = parse_idl(
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
        "TokenMetadata",
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s\n\
         instruction burnNft 0x1d () ()\n\
         instruction createMetadataAccount 0x00 (metadata) (isMutable: bool)\n\
         unusable instruction undispatchable: discriminant: this Shank IDL declares no \
         'discriminant' for the instruction, and a hashed Anchor discriminator is not what a \
         Shank program dispatches on\n"
    );
}

mod layout;
mod validate;
