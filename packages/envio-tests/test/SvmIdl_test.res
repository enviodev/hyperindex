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

let programNodeIdl = `{
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
  }]
}`

let optionalAccountsIdl = `{
  "kind": "rootNode",
  "program": {
    "kind": "programNode",
    "name": "accounts",
    "publicKey": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
    "instructions": [{
      "kind": "instructionNode",
      "name": "create",
      "accounts": [
        { "kind": "instructionAccountNode", "name": "metadata" },
        { "kind": "instructionAccountNode", "name": "mint", "isOptional": true },
        { "kind": "instructionAccountNode", "name": "payer" },
        { "kind": "instructionAccountNode", "name": "rent", "isOptional": true }
      ],
      "arguments": [{
        "kind": "instructionArgumentNode",
        "name": "discriminator",
        "type": { "kind": "numberTypeNode", "format": "u8" },
        "defaultValue": { "kind": "numberValueNode", "number": 1 }
      }],
      "discriminators": [{ "kind": "fieldDiscriminatorNode", "name": "discriminator", "offset": 0 }]
    }]
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
  - id: solana
    start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          idl: idls/swapper.json
`

let codamaConfigYaml = `
name: svm-codama-idl
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: SplToken
          program_id: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
          idl: idls/spl-token.codama.json
`

let parseError = (~files, ~configYaml) =>
  try {
    InternalTestIndexer.fromUserApi(~files, ~configYaml)->ignore
    "the parse to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }

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
import type { Global } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type Programs = Global extends { config: { svm: { programs: infer P } } } ? P : never;
type Swap = Programs["Swapper"]["swap"];

expectType<
  TypeEqual<
    Swap["args"],
    {
      readonly amountIn: string;
      readonly slippageBps: number;
      readonly route: { readonly hops: string[]; readonly percent: number };
      readonly memo: string | null;
    }
  >
>(true);
expectType<
  TypeEqual<
    Swap["accounts"],
    { readonly source: string; readonly destination: string; readonly authority: string }
  >
>(true);
`)
  )

  it("types args and accounts from a Codama IDL", _ =>
    checkCodama(`
import type { Global } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type Programs = Global extends { config: { svm: { programs: infer P } } } ? P : never;
type Transfer = Programs["SplToken"]["transfer"];

expectType<TypeEqual<Transfer["args"], { readonly amount: string }>>(true);
expectType<
  TypeEqual<Transfer["accounts"], { readonly source: string; readonly destination: string }>
>(true);
`)
  )

  it("derives the discriminator from the IDL", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~files=Dict.fromArray([("idls/swapper.json", anchorIdl)]),
      ~configYaml=anchorConfigYaml,
    )
    let ids =
      config.chainMap
      ->ChainMap.values
      ->Array.flatMap(
        chain =>
          chain.contracts->Array.flatMap(
            contract => contract.events->Array.map(event => (contract.name, event.name, event.id)),
          ),
      )
    t.expect(ids).toEqual([("Swapper", "swap", "0x0102030405060708")])
  })

  it("registers every usable IDL instruction", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~files=Dict.fromArray([
        (
          "idls/swapper.json",
          `{
  "address": "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
  "instructions": [
    {"name": "swap", "discriminator": [1]},
    {"name": "ping", "discriminator": [2]}
  ]
}`,
        ),
      ]),
      ~configYaml=anchorConfigYaml,
    )
    let ids =
      config.chainMap
      ->ChainMap.values
      ->Array.flatMap(
        chain =>
          chain.contracts->Array.flatMap(
            contract => contract.events->Array.map(event => (contract.name, event.name, event.id)),
          ),
      )
    t.expect(ids).toEqual([("Swapper", "ping", "0x02"), ("Swapper", "swap", "0x01")])
  })

  it("omits an unusable sibling and keeps the rest", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~files=Dict.fromArray([
        (
          "idls/swapper.json",
          `{
  "address": "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
  "instructions": [
    {"name": "swap", "discriminator": [1], "args": [{"name": "amountIn", "type": {"coption": "u64"}}]},
    {"name": "ping", "discriminator": [2]}
  ]
}`,
        ),
      ]),
      ~configYaml=anchorConfigYaml,
    )
    let ids =
      config.chainMap
      ->ChainMap.values
      ->Array.flatMap(
        chain =>
          chain.contracts->Array.flatMap(
            contract => contract.events->Array.map(event => (contract.name, event.name, event.id)),
          ),
      )
    t.expect(ids).toEqual([("Swapper", "ping", "0x02")])
  })

  it("rejects an IDL with no instructions", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([
          (
            "idls/swapper.json",
            `{"address": "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8", "instructions": []}`,
          ),
        ]),
        ~configYaml=anchorConfigYaml,
      ),
    ).toBe(
      "Config parse error: Resolving Borsh schema for program 'Swapper' (675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8): Program 'Swapper': the IDL declares no instructions this runtime can decode.",
    )
  )

  it("rejects a missing idl", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([]),
        ~configYaml=`
name: svm-no-idl
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
`,
      ),
    ).toBe(
      "Config parse error: Program \"Swapper\" is missing `idl`. Point it at an Anchor or Codama JSON file.",
    )
  )

  it("rejects an instructions list", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([("idls/swapper.json", anchorIdl)]),
        ~configYaml=anchorConfigYaml ++ "          instructions:\n            - name: swap\n",
      ),
    ).toBe(
      "Config parse error: Program \"Swapper\" has an `instructions` list, which is not valid. Configure the program with `name`, `program_id`, and `idl`. Register `indexer.onInstruction` handlers for the instructions to handle.",
    )
  )

  it("names the reason when every IDL instruction is unusable", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([
          (
            "idls/swapper.json",
            anchorIdl->String.replace(
              `{ "name": "amountIn", "type": "u64" }`,
              `{ "name": "amountIn", "type": { "coption": "u64" } }`,
            ),
          ),
        ]),
        ~configYaml=anchorConfigYaml,
      ),
    ).toBe(
      "Config parse error: Resolving Borsh schema for program 'Swapper' (675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8): Program 'Swapper': the IDL declares no instructions this runtime can decode: swap (args.amountIn: `coption` is not Borsh-compatible and cannot be decoded)",
    )
  )

  it("rejects an IDL whose address is not the configured program", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([("idls/swapper.json", anchorIdl)]),
        ~configYaml=anchorConfigYaml->String.replace(
          "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8\n          idl",
          "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA\n          idl",
        ),
      ),
    ).toBe(
      "Config parse error: Resolving Borsh schema for program 'Swapper' (TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA): Program 'Swapper': the IDL declares address '675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8' but the config sets `program_id: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`.",
    )
  )

  // Routing dispatches on the discriminator, so two instructions sharing one
  // are undispatchable — a name-keyed IDL can express that, and it has to be
  // rejected rather than silently collapsed to whichever landed last.
  it("rejects two instructions sharing a discriminator", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([("idls/spl-token.codama.json", clashingCodamaIdl)]),
        ~configYaml=codamaConfigYaml,
      ),
    ).toBe(
      "Config parse error: Resolving Borsh schema for program 'SplToken' (TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA): Program 'SplToken': the IDL declares no instructions this runtime can decode: transfer (it shares discriminator 0x03 with 'transferAgain'); transferAgain (it shares discriminator 0x03 with 'transfer')",
    )
  )

  // The discriminator field is consumed as the instruction's prefix, so it is
  // not an argument the Borsh runtime decodes.
  it("omits the Codama discriminator field from args", t => {
    let actual = try {
      checkCodama(`
import type { Global } from "envio";

type Programs = Global extends { config: { svm: { programs: infer P } } } ? P : never;
type Transfer = Programs["SplToken"]["transfer"];
type _D = Transfer["args"]["discriminator"];
`)
      "the type check to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(actual).toBe(
      "Type errors:\n__mock_indexer_handlers.ts(6,28): error TS2339: Property 'discriminator' does not exist on type '{ readonly amount: string; }'.",
    )
  })

  it("parses a Codama programNode without a root wrapper", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~files=Dict.fromArray([("idls/spl-token.codama.json", programNodeIdl)]),
      ~configYaml=codamaConfigYaml,
    )
    let ids =
      config.chainMap
      ->ChainMap.values
      ->Array.flatMap(
        chain =>
          chain.contracts->Array.flatMap(
            contract => contract.events->Array.map(event => (contract.name, event.name, event.id)),
          ),
      )
    t.expect(ids).toEqual([("SplToken", "transfer", "0x03")])
  })

  it("types only a trailing optional account as optional", _ =>
    InternalTestIndexer.fromUserApi(
      ~schema=ApiTypesFixtures.schema,
      ~files=Dict.fromArray([("idls/accounts.codama.json", optionalAccountsIdl)]),
      ~configYaml=codamaConfigYaml->String.replace(
        "idls/spl-token.codama.json",
        "idls/accounts.codama.json",
      ),
      ~handlers=`
import type { Global } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type Programs = Global extends { config: { svm: { programs: infer P } } } ? P : never;
type Create = Programs["SplToken"]["create"];

expectType<
  TypeEqual<
    Create["accounts"],
    { readonly metadata: string; readonly mint: string; readonly payer: string; readonly rent?: string }
  >
>(true);
`,
    )->ignore
  )

})
