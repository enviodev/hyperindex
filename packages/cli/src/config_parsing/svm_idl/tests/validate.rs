use pretty_assertions::assert_eq;
use serde_json::Value;

use super::*;

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
            "instruction whose discriminator cannot be read",
            r#"{ "instructions": [
                 { "name": "burn", "discriminator": [12], "args": [] },
                 { "name": "sub", "discriminator": [12, 999], "args": [] }] }"#,
        ),
        (
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
            "size-only discriminator does not poison a sibling",
            r#"{ "kind": "rootNode", "program": { "instructions": [
                 { "name": "transfer", "discriminators": [{
                     "kind": "constantDiscriminatorNode", "offset": 0,
                     "constant": { "value": { "kind": "bytesValueNode", "data": "03" } } }] },
                 { "name": "sized", "discriminators": [{
                     "kind": "sizeDiscriminatorNode", "size": 10 }] }
               ] } }"#,
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
            "duplicate type name",
            r#"{ "instructions": [{ "name": "swap", "discriminator": [1],
                 "args": [{ "name": "fee", "type": { "defined": "Fee" } }] }],
                 "types": [
                   { "name": "Fee", "type": { "kind": "struct",
                     "fields": [{ "name": "bps", "type": "u16" }] } },
                   { "name": "Fee", "type": { "kind": "struct",
                     "fields": [{ "name": "bps", "type": "u32" }] } }] }"#,
        ),
        (
            "duplicate account name",
            r#"{ "instructions": [{ "name": "swap", "discriminator": [1],
                 "accounts": [{ "name": "vault" }, { "name": "vault" }] }] }"#,
        ),
        (
            // The trailing `tag` is wire-encoded like any other argument. Read
            // as part of the discriminator it would vanish, and `amount` would
            // then decode one byte short of where the program wrote it.
            "codama argument reusing a discriminator name",
            r#"{ "kind": "rootNode", "program": { "instructions": [{
                 "kind": "instructionNode", "name": "swap",
                 "arguments": [
                   { "name": "tag", "type": { "kind": "numberTypeNode", "format": "u8" },
                     "defaultValue": { "kind": "numberValueNode", "number": 3 } },
                   { "name": "amount", "type": { "kind": "numberTypeNode", "format": "u64" } },
                   { "name": "tag", "type": { "kind": "numberTypeNode", "format": "u8" } }],
                 "discriminators": [{ "kind": "fieldDiscriminatorNode",
                                      "name": "tag", "offset": 0 }] }] } }"#,
        ),
        (
            // Coerced to 0 it tiles from the head and the instruction is
            // accepted carrying a prefix the program encodes elsewhere.
            "codama discriminator offset that is not a byte position",
            r#"{ "kind": "rootNode", "program": { "instructions": [{
                 "name": "swap",
                 "discriminators": [{ "kind": "constantDiscriminatorNode", "offset": -1,
                   "constant": { "value": { "kind": "bytesValueNode", "data": "03" } } }] }] } }"#,
        ),
        (
            // Read as an empty group its slots vanish, and every account
            // declared after it answers to the name of the one before.
            "anchor composite group whose 'accounts' is not an array",
            r#"{ "instructions": [{ "name": "swap", "discriminator": [1],
                 "accounts": [{ "name": "group", "accounts": null },
                              { "name": "vault" }] }] }"#,
        ),
        (
            // Read as `false` the slot becomes required, and a transaction that
            // omits it pairs every later pubkey with the wrong name. Anchor
            // already refused this; Codama used to default it.
            "codama account with an unreadable isOptional",
            r#"{ "kind": "rootNode", "program": { "instructions": [{
                 "kind": "instructionNode", "name": "swap",
                 "accounts": [{ "name": "vault", "isOptional": "yes" }],
                 "discriminators": [{ "kind": "constantDiscriminatorNode", "offset": 0,
                   "constant": { "value": { "kind": "bytesValueNode", "data": "03" } } }] }] } }"#,
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
            "neither dialect: fatal: unrecognized IDL: expected an Anchor IDL (top-level 'instructions') or a Codama IDL (a 'rootNode' or 'programNode')",
            "duplicate instruction name: fatal: IDL declares instruction 'swap' more than once",
            "anchor coption: initializeMint set aside: args.freezeAuthority: `coption` is not Borsh-compatible and cannot be decoded",
            "undefined type reference: swap set aside: args.amount: unknown type 'u46'",
            "discriminator wider than dispatch probes: swap set aside: its discriminator is 3 bytes, and dispatch matches only 1, 2, 4, or 8",
            "instruction with no discriminator at all: swap set aside: its discriminator is 0 bytes, and dispatch matches only 1, 2, 4, or 8",
            "one discriminator a prefix of another: transfer set aside: its discriminator 0x0c is a prefix of 'transferChecked''s 0x0c02, so 'transferChecked' takes every call that would have matched it; transferChecked set aside: its discriminator 0x0c02 extends 'transfer''s 0x0c, so a 'transfer' call whose data continues those bytes arrives here instead",
            "discriminator field not at offset 0: swap set aside: discriminators: discriminator part at offset 8 does not follow the previous part, which ends at 0; dispatch needs one contiguous prefix from offset 0",
            "discriminator value too wide for its format: swap set aside: discriminators: discriminator value 300 does not fit in u8",
            "instruction shadowed by one set aside for its args: transfer set aside: its discriminator 0x0c is a prefix of 'transferChecked''s 0x0c02, so 'transferChecked' takes every call that would have matched it; transferChecked set aside: args.amount: `coption` is not Borsh-compatible and cannot be decoded",
            "instruction whose discriminator cannot be read: sub set aside: discriminator: expected a byte (0-255), got 999",
            "instruction declaring no discriminator at all: raw set aside: its discriminator is 0 bytes, and dispatch matches only 1, 2, 4, or 8",
            "size-only discriminator does not poison a sibling: sized set aside: its discriminator is 0 bytes, and dispatch matches only 1, 2, 4, or 8",
            "one discriminator a prefix of several others: transfer set aside: its discriminator 0x0c is a prefix of 'transferChecked''s 0x0c02, so 'transferChecked' takes every call that would have matched it; transferAll set aside: its discriminator 0x0c03 extends 'transfer''s 0x0c, so a 'transfer' call whose data continues those bytes arrives here instead; transferChecked set aside: its discriminator 0x0c02 extends 'transfer''s 0x0c, so a 'transfer' call whose data continues those bytes arrives here instead",
            "instruction shadowed by one of an undispatchable width: swap set aside: its discriminator 0x0102 is a prefix of 'swapV2''s 0x010203, so 'swapV2' takes every call that would have matched it; swapV2 set aside: its discriminator is 3 bytes, and dispatch matches only 1, 2, 4, or 8",
            "codama discriminator argument out of declaration order: swap set aside: the discriminator reads [\"tag\"], but the arguments begin [\"amount\"]; their offsets and their declaration order disagree",
            "duplicate type name: fatal: IDL declares type 'Fee' more than once",
            "duplicate account name: swap set aside: IDL declares account 'vault' more than once",
            "codama argument reusing a discriminator name: swap set aside: IDL declares argument 'tag' more than once",
            "codama discriminator offset that is not a byte position: swap set aside: discriminators: expected a non-negative integer 'offset', got -1",
            "anchor composite group whose 'accounts' is not an array: swap set aside: accounts: expected an array of accounts, got null",
            "codama account with an unreadable isOptional: swap set aside: accounts: 'isOptional' must be a boolean, got \"yes\"",
        ]
    );
}

/// Codama's default `optionalAccountStrategy` fills an absent optional account
/// with the program id, so every later account stays at its declared position.
/// Under `omitted` the slot is gone, and a non-trailing optional shifts
/// everything after it — this parser pairs names to accounts by position, as
/// the runtime does, so it would report the wrong pubkey under every later
/// name.
#[test]
fn demotes_omitted_strategy_instructions_with_a_middle_optional() {
    let instruction = |name: &str, strategy: &str, byte: &str| {
        format!(
            r#"{{ "kind": "instructionNode", "name": "{name}"{strategy},
                 "accounts": [{{ "name": "source" }},
                              {{ "name": "authority", "isOptional": true }},
                              {{ "name": "destination" }}],
                 "discriminators": [{{ "kind": "constantDiscriminatorNode", "offset": 0,
                   "constant": {{ "value": {{ "kind": "bytesValueNode",
                                              "data": "{byte}" }} }} }}] }}"#
        )
    };
    let idl = parse_idl(
        &format!(
            r#"{{ "kind": "rootNode", "program": {{ "instructions": [
                 {shifted}, {padded},
                 {{ "kind": "instructionNode", "name": "trailing",
                    "optionalAccountStrategy": "omitted",
                    "accounts": [{{ "name": "account" }},
                                 {{ "name": "rent", "isOptional": true }}],
                    "discriminators": [{{ "kind": "constantDiscriminatorNode", "offset": 0,
                      "constant": {{ "value": {{ "kind": "bytesValueNode",
                                                 "data": "03" }} }} }}] }}] }} }}"#,
            shifted = instruction("shifted", r#", "optionalAccountStrategy": "omitted""#, "01"),
            padded = instruction(
                "padded",
                r#", "optionalAccountStrategy": "programId""#,
                "02"
            ),
        ),
        "Program",
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         instruction padded 0x02 (source, authority:?, destination) ()\n\
         instruction trailing 0x03 (account, rent:?) ()\n\
         unusable instruction shifted: account 'authority' is optional and left out entirely \
         when absent, so every account after it shifts and this parser cannot tell which name a \
         slot carries\n"
    );
}

/// Two Anchor composite groups may nest the same inner name — in the program's
/// source they are separate namespaces. Flattening collides them, but that is
/// one instruction's defect: every other per-instruction defect leaves the rest
/// of the program indexable, and this one used to fail the whole file.
#[test]
fn demotes_an_instruction_whose_flattened_accounts_collide() {
    let idl = parse_idl(
        r#"{ "instructions": [
             { "name": "swap", "discriminator": [1], "accounts": [
               { "name": "from", "accounts": [{ "name": "authority" }] },
               { "name": "to", "accounts": [{ "name": "authority" }] }] },
             { "name": "deposit", "discriminator": [2],
               "accounts": [{ "name": "vault" }] }] }"#,
        "Program",
    )
    .expect("parse");

    assert_eq!(
        render(&idl),
        "address: -\n\
         instruction deposit 0x02 (vault) ()\n\
         unusable instruction swap: IDL declares account 'authority' more than once\n"
    );
}

/// Deterministic mutation fuzzing over the real fixtures. `parse_idl` takes
/// untrusted JSON, so no input may panic — every rejection has to arrive as an
/// `Err`. A seeded walk keeps a failure reproducible from the printed seed.
///
#[test]
fn mutated_fixtures_never_panic() {
    // xorshift64*, so the sequence is fixed across platforms and runs.
    fn next(state: &mut u64) -> u64 {
        *state ^= *state >> 12;
        *state ^= *state << 25;
        *state ^= *state >> 27;
        state.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Replace the `target`-th node of `value` in traversal order, handing back
    /// what was there. The nodes traversed before `target` do not depend on
    /// that node's own shape, so passing the same target again with the saved
    /// value puts the fixture back as it was.
    fn replace_nth(value: &mut Value, target: &mut i64, new: &Value, replaced: &mut Option<Value>) {
        if *target < 0 {
            return;
        }
        if *target == 0 {
            *replaced = Some(std::mem::replace(value, new.clone()));
            *target = -1;
            return;
        }
        *target -= 1;
        match value {
            Value::Object(map) => map
                .values_mut()
                .for_each(|child| replace_nth(child, target, new, replaced)),
            Value::Array(items) => items
                .iter_mut()
                .for_each(|child| replace_nth(child, target, new, replaced)),
            _ => {}
        }
    }

    let mut state = 0x005E_ED1D_u64;
    for stem in ["jupiter", "kamino"] {
        let source = read_fixture(&format!("../../scenarios/svm_flow_xray/idls/{stem}.json"));
        let mut fixture: Value = serde_json::from_str(&source).expect("fixture is JSON");
        for _ in 0..150 {
            let seed = state;
            let replacement = next(&mut state);
            let replacement = match replacement % 6 {
                0 => Value::Null,
                1 => Value::Bool(true),
                2 => Value::from(replacement),
                3 => Value::from(-1i64),
                4 => Value::String("\u{1F600}".into()),
                _ => Value::Array(vec![]),
            };
            let target = (next(&mut state) % 4000) as i64;

            let mut replaced = None;
            replace_nth(&mut fixture, &mut { target }, &replacement, &mut replaced);
            let json = fixture.to_string();
            // `parse_idl` must decide, not panic. A panic here fails the test
            // with the seed in the message so it can be replayed.
            let outcome = std::panic::catch_unwind(|| parse_idl(&json, "Fuzzed").is_ok());
            if let Some(original) = replaced {
                replace_nth(&mut fixture, &mut { target }, &original, &mut None);
            }
            assert!(
                outcome.is_ok(),
                "parse_idl panicked on a mutation of {stem}.json (seed 0x{seed:x})"
            );
        }
        // Restoring in place is what keeps every iteration a single-node
        // mutation of the real IDL rather than of the previous mutation.
        assert_eq!(
            fixture,
            serde_json::from_str::<Value>(&source).expect("fixture is JSON")
        );
    }
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

    // Bounded, because resolving per occurrence would not fail this assertion
    // — it would run for hours and surface as a CI timeout pointing nowhere.
    let started = std::time::Instant::now();
    let idl = parse_idl(&json, "Deep").expect("parse");
    assert_eq!(
        (
            idl.instructions.keys().collect::<Vec<_>>(),
            started.elapsed() < std::time::Duration::from_secs(5)
        ),
        (vec![&"swap".to_string()], true)
    );
}

/// A type that cannot be resolved condemns every type reaching it, and a long
/// dependency chain reaches a long way. Settling one name per pass — re-walking
/// every remaining type from scratch each time — is cubic in the number of
/// types, which surfaces as a codegen that never returns rather than as a wrong
/// answer.
#[test]
fn settles_a_long_chain_of_unresolvable_types_in_one_pass() {
    let depth = 400;
    let types: Vec<String> = (0..depth)
        .map(|i| {
            let next = if i + 1 == depth {
                "Missing".to_string()
            } else {
                format!("T{:04}", i + 1)
            };
            format!(
                r#"{{ "name": "T{i:04}", "type": {{ "kind": "struct", "fields": [
                     {{ "name": "next", "type": {{ "defined": "{next}" }} }}] }} }}"#
            )
        })
        .collect();
    let json = format!(
        r#"{{ "instructions": [{{ "name": "walk", "discriminator": [1],
             "args": [{{ "name": "head", "type": {{ "defined": "T0000" }} }}] }}],
             "types": [{}] }}"#,
        types.join(",")
    );

    // Bounded, because settling one name per pass would not fail an assertion
    // on the outcome — it would surface as a CI timeout pointing nowhere.
    let started = std::time::Instant::now();
    let idl = parse_idl(&json, "Chain").expect("parse");
    assert_eq!(
        (
            idl.unusable_types.len(),
            idl.defined_types.is_empty(),
            idl.unusable.keys().map(String::as_str).collect::<Vec<_>>(),
            started.elapsed() < std::time::Duration::from_secs(2),
        ),
        (depth, true, vec!["walk"], true)
    );
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

/// A `Defined` alias that names itself (or a struct that always contains
/// itself) has no Borsh terminator. `decode_field` would recurse until the
/// stack overflows.
#[test]
fn demotes_unbounded_recursive_types() {
    let alias = parse_idl(
        r#"{ "instructions": [{ "name": "go", "discriminator": [1],
             "args": [{ "name": "loop", "type": { "defined": "Loop" } }] }],
             "types": [{ "name": "Loop", "type": { "kind": "type", "alias": { "defined": "Loop" } } }] }"#,
        "Program",
    )
    .expect("parse");
    let nested = parse_idl(
        r#"{ "instructions": [{ "name": "go", "discriminator": [1],
             "args": [{ "name": "box", "type": { "defined": "Box" } }] }],
             "types": [{ "name": "Box", "type": { "kind": "struct", "fields": [
               { "name": "inner", "type": { "defined": "Box" } }] } }] }"#,
        "Program",
    )
    .expect("parse");

    assert_eq!(
        (
            (
                alias
                    .instructions
                    .keys()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
                alias
                    .unusable
                    .keys()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
                alias
                    .unusable_types
                    .get("Loop")
                    .map(|r| r.contains("recursively"))
                    .unwrap_or(false),
            ),
            (
                nested
                    .instructions
                    .keys()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
                nested
                    .unusable
                    .keys()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
                nested
                    .unusable_types
                    .get("Box")
                    .map(|r| r.contains("recursively"))
                    .unwrap_or(false),
            ),
        ),
        (
            (Vec::new(), vec!["go"], true),
            (Vec::new(), vec!["go"], true),
        )
    );
}
