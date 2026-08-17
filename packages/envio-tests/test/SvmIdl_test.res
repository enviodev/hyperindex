open Vitest

// An Anchor 0.30+ IDL: inline discriminators, `{"defined": {"name": T}}` type
// refs, `writable`/`signer` account flags.
let anchorIdl = `{
  "address": "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
  "metadata": { "name": "swapper", "version": "0.1.0", "spec": "0.1.0" },
  "instructions": [{
    "name": "swap",
    "discriminator": [1, 2, 3, 4, 5, 6, 7, 8],
    "accounts": [
      { "name": "source", "writable": true },
      { "name": "destination", "writable": true },
      { "name": "authority", "signer": true }
    ],
    "args": [
      { "name": "amountIn", "type": "u64" },
      { "name": "slippageBps", "type": "u16" },
      { "name": "route", "type": { "defined": { "name": "Route" } } },
      { "name": "memo", "type": { "option": "string" } }
    ]
  }],
  "types": [{
    "name": "Route",
    "type": {
      "kind": "struct",
      "fields": [
        { "name": "hops", "type": { "vec": "pubkey" } },
        { "name": "percent", "type": "u8" }
      ]
    }
  }]
}`

// A Codama IDL: the discriminator is a regular u8 argument singled out by
// name, which no Anchor IDL can express.
let codamaIdl = `{
  "kind": "rootNode",
  "standard": "codama",
  "program": {
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
          "defaultValue": { "kind": "numberValueNode", "number": 3 },
          "defaultValueStrategy": "omitted"
        },
        { "kind": "instructionArgumentNode", "name": "amount", "type": { "kind": "numberTypeNode", "format": "u64" } }
      ],
      "discriminators": [{ "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }]
    }],
    "definedTypes": []
  }
}`

let clashingCodamaIdl = `{
  "kind": "rootNode",
  "program": {
    "kind": "programNode",
    "name": "splToken",
    "publicKey": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
    "instructions": [{
      "kind": "instructionNode",
      "name": "transfer",
      "arguments": [{
        "kind": "instructionArgumentNode",
        "name": "discriminator",
        "type": { "kind": "numberTypeNode", "format": "u8" },
        "defaultValue": { "kind": "numberValueNode", "number": 3 }
      }],
      "discriminators": [{ "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }]
    }, {
      "kind": "instructionNode",
      "name": "transferAgain",
      "arguments": [{
        "kind": "instructionArgumentNode",
        "name": "discriminator",
        "type": { "kind": "numberTypeNode", "format": "u8" },
        "defaultValue": { "kind": "numberValueNode", "number": 3 }
      }],
      "discriminators": [{ "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }]
    }]
  }
}`

let anchorConfigYaml = `
name: svm-anchor-idl
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          idl: idls/swapper.json
          instructions:
            - name: swap
              discriminator: "0x0102030405060708"
`

let codamaConfigYaml = `
name: svm-codama-idl
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: SplToken
          program_id: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
          idl: idls/spl-token.codama.json
          instructions:
            - name: transfer
              discriminator: "0x03"
`

let checkAnchor = handlers =>
  InternalTestIndexer.fromUserApi(
    ~schema=ApiTypesFixtures.schema,
    ~files=Dict.fromArray([("idls/swapper.json", anchorIdl)]),
    ~handlers,
    ~configYaml=anchorConfigYaml,
  )->ignore

let checkCodama = handlers =>
  InternalTestIndexer.fromUserApi(
    ~schema=ApiTypesFixtures.schema,
    ~files=Dict.fromArray([("idls/spl-token.codama.json", codamaIdl)]),
    ~handlers,
    ~configYaml=codamaConfigYaml,
  )->ignore

describe("SVM instruction types derived from an IDL", () => {
  it("types args and accounts from an Anchor IDL", _ =>
    checkAnchor(`
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

indexer.onInstruction(
  { program: "Swapper", instruction: "swap" },
  async ({ instruction }) => {
    const params = instruction.params;
    if (!params) return;
    expectType<TypeEqual<typeof params.args.amountIn, string>>(true);
    expectType<TypeEqual<typeof params.args.slippageBps, number>>(true);
    expectType<TypeEqual<typeof params.args.route.percent, number>>(true);
    expectType<TypeEqual<typeof params.args.route.hops, string[]>>(true);
    expectType<TypeEqual<typeof params.args.memo, string | null>>(true);
    expectType<TypeEqual<typeof params.accounts.source, string>>(true);
    expectType<TypeEqual<typeof params.accounts.destination, string>>(true);
    expectType<TypeEqual<typeof params.accounts.authority, string>>(true);
  },
);
`)
  )

  it("types args and accounts from a Codama IDL", _ =>
    checkCodama(`
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

indexer.onInstruction(
  { program: "SplToken", instruction: "transfer" },
  async ({ instruction }) => {
    const params = instruction.params;
    if (!params) return;
    expectType<TypeEqual<typeof params.args.amount, string>>(true);
    expectType<TypeEqual<typeof params.accounts.source, string>>(true);
    expectType<TypeEqual<typeof params.accounts.destination, string>>(true);
  },
);
`)
  )

  // Routing dispatches on the discriminator, so two instructions sharing one
  // are undispatchable — a name-keyed IDL can express that, and it has to be
  // rejected rather than silently collapsed to whichever landed last.
  it("rejects two instructions sharing a discriminator", t => {
    let actual = try {
      InternalTestIndexer.fromUserApi(
        ~files=Dict.fromArray([("idls/spl-token.codama.json", clashingCodamaIdl)]),
        ~configYaml=codamaConfigYaml,
      )->ignore
      "the parse to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(actual).toBe(
      "Config parse error: Resolving Borsh schema for program 'SplToken' (TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA): Instructions 'transfer' and 'transferAgain' share discriminator 0x03",
    )
  })

  // The discriminator field is consumed as the instruction's prefix, so it is
  // not an argument the Borsh runtime decodes.
  it("omits the Codama discriminator field from args", t => {
    let actual = try {
      checkCodama(`
import { indexer } from "envio";

indexer.onInstruction(
  { program: "SplToken", instruction: "transfer" },
  async ({ instruction }) => {
    instruction.params?.args.discriminator;
  },
);
`)
      "the type check to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(actual).toBe(
      "Type errors:\n__mock_indexer_handlers.ts(7,30): error TS2339: Property 'discriminator' does not exist on type '{ readonly amount: string; }'.",
    )
  })
})
