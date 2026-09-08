use hypersync_client_solana::decode::decode_top_level;
use pretty_assertions::assert_eq;

use super::*;

/// A Codama IDL with one instruction whose body is a single argument of the
/// given type: the smallest shape that puts a type node in front of the parser
/// on the path a config actually takes. The leading `tag` argument carrying the
/// dispatch byte is how a real Codama IDL spells a discriminator — the bytes
/// are part of the encoded arguments, not a prefix in front of them.
fn codama_type(type_node: &str) -> String {
    format!(
        r#"{{ "kind": "rootNode", "program": {{ "instructions": [{{
             "kind": "instructionNode", "name": "probe",
             "discriminators": [{{ "kind": "fieldDiscriminatorNode",
                                   "name": "tag", "offset": 0 }}],
             "arguments": [
               {{ "kind": "instructionArgumentNode", "name": "tag",
                  "type": {{ "kind": "numberTypeNode", "format": "u8" }},
                  "defaultValue": {{ "kind": "numberValueNode", "number": 1 }} }},
               {{ "kind": "instructionArgumentNode", "name": "probed",
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
            let idl = parse_idl("idl.json", json).unwrap_or_else(|e| {
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
            "codama fixed option: probe: idl.json:1:53: args.probed: a fixed option pads its body when absent, which Borsh does not encode",
            "codama enum with a wide tag: probe: idl.json:1:53: args.probed.size: Borsh needs u8 here, got u32",
            "codama big-endian number: probe: idl.json:1:53: args.probed: Borsh decodes numbers little-endian, got 'be'",
            "codama bare string: probe: idl.json:1:53: args.probed: a bare stringTypeNode carries no length; Borsh needs it wrapped in a sizePrefixTypeNode with a u32 prefix",
            "codama bare bytes: probe: idl.json:1:53: args.probed: a bare bytesTypeNode carries no length; Borsh needs it wrapped in a sizePrefixTypeNode with a u32 prefix",
            "codama non-utf8 string: probe: idl.json:1:53: args.probed: Borsh strings are utf8, got 'base58'",
            "codama boolean wider than a byte: probe: idl.json:1:53: args.probed.size: Borsh needs u8 here, got u32",
            "codama enum variant with its own discriminator: probe: idl.json:1:53: args.probed.Init: enumEmptyVariantTypeNode carries 'discriminator', which this parser does not model; decoding it would be a guess at the byte layout. Removing the key from a local copy of the IDL is the way through if it does not affect the layout",
            "codama size prefix around a struct: probe: idl.json:1:53: args.probed: a u32 size prefix frames a string or bytes in Borsh, got structTypeNode",
            "codama big-endian length prefix: probe: idl.json:1:53: args.probed.prefix: Borsh decodes numbers little-endian, got 'be'",
            "codama enum tuple variant behind a wrapper: probe: idl.json:1:53: args.probed.Wrapped: sizePrefixTypeNode carries 'items', which this parser does not model; decoding it would be a guess at the byte layout. Removing the key from a local copy of the IDL is the way through if it does not affect the layout",
            "codama zeroable option: probe: idl.json:1:53: args.probed: zeroable options are not Borsh-compatible and cannot be decoded",
            "codama option with a wide tag: probe: idl.json:1:53: args.probed.prefix: Borsh needs u8 here, got u32",
            "codama vector with a narrow length prefix: probe: idl.json:1:53: args.probed.prefix: Borsh needs u32 here, got u8",
            "codama string with a narrow size prefix: probe: idl.json:1:53: args.probed.prefix: Borsh needs u32 here, got u8",
            "anchor generic parameter: swap: idl.json:1:20: args.wrapped: generic parameter 'T' has no concrete layout to decode against",
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
            let idl = parse_idl("idl.json", json).unwrap_or_else(|e| panic!("{label}: {e:#}"));
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
        "idl.json",
        r#"{
          "kind": "rootNode",
          "program": {
            "kind": "programNode",
            "publicKey": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
            "instructions": [{
              "kind": "instructionNode",
              "name": "probe",
              "discriminators": [{
                "kind": "fieldDiscriminatorNode", "name": "tag", "offset": 0
              }],
              "arguments": [
                { "kind": "instructionArgumentNode", "name": "tag",
                  "type": { "kind": "numberTypeNode", "format": "u8" },
                  "defaultValue": { "kind": "numberValueNode", "number": 1 } },
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
