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
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

indexer.onInstruction(
  { program: "Swapper", instruction: "swap" },
  async ({ instruction }) => {
    const params = instruction.params;
    if (!params) return;
    expectType<
      TypeEqual<
        typeof params.args,
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
        typeof params.accounts,
        { readonly source: string; readonly destination: string; readonly authority: string }
      >
    >(true);
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
    expectType<TypeEqual<typeof params.args, { readonly amount: string }>>(true);
    expectType<
      TypeEqual<
        typeof params.accounts,
        { readonly source: string; readonly destination: string }
      >
    >(true);
  },
);
`)
  )

  // The whole point of keying the IDL by name: the config names an
  // instruction and the discriminator comes from the IDL, not from a hand-
  // transcribed hex string.
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

  it("rejects an instruction name the IDL does not declare", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([("idls/swapper.json", anchorIdl)]),
        ~configYaml=anchorConfigYaml->String.replace("- name: swap", "- name: swapExactOut"),
      ),
    ).toBe(
      "Config parse error: Layout for instruction 'swapExactOut': Instruction 'swapExactOut' is not in the program's IDL. Available instructions: swap.",
    )
  )

  it("rejects a configured discriminator that contradicts the IDL", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([("idls/swapper.json", anchorIdl)]),
        ~configYaml=anchorConfigYaml->String.replace(
          "- name: swap",
          `- name: swap\n              discriminator: "0xdeadbeefdeadbeef"`,
        ),
      ),
    ).toBe(
      "Config parse error: Layout for instruction 'swap': Instruction 'swap': the config sets `discriminator: 0xdeadbeefdeadbeef` but the IDL derives 0x0102030405060708. Drop the `discriminator` line and let the IDL supply it.",
    )
  )

  // An IDL describes a whole program; a config indexes a few of its
  // instructions. One the runtime cannot decode has to cost only itself, or a
  // single such shape puts every other instruction in the file out of reach —
  // SPL Token declares one, and 26 of its 28 instructions decode fine.
  it("names the reason when an instruction the IDL declares cannot be decoded", t =>
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
      "Config parse error: Layout for instruction 'swap': Instruction 'swap' is declared by the program's IDL, but instruction 'swap' args.amountIn: `coption` is not Borsh-compatible and cannot be decoded.",
    )
  )

  // Dispatch reads a fixed-width prefix off the instruction data, so a width
  // it never probes matches nothing. Caught at codegen rather than at indexer
  // start, where the config line that caused it is long out of sight.
  it("rejects a hand-written discriminator dispatch cannot probe", t =>
    t.expect(
      parseError(
        ~files=Dict.fromArray([]),
        ~configYaml=`
name: svm-inline
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: SplToken
          program_id: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
          instructions:
            - name: transfer
              discriminator: "0xaabbcc"
`,
      ),
    ).toBe(`Config parse error: instruction "transfer" in program "SplToken": discriminator "0xaabbcc" must be 1, 2, 4, or 8 bytes (i.e. 2, 4, 8, or 16 hex digits after stripping a \`0x\` prefix), got 6 digits`)
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
      "Config parse error: Resolving Borsh schema for TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA: Program 'Swapper': the IDL declares address '675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8' but the config sets `program_id: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`.",
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
      "Config parse error: Layout for instruction 'transfer': Instruction 'transfer' is declared by the program's IDL, but it shares discriminator 0x03 with 'transferAgain'.",
    )
  )

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
